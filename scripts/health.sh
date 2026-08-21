#!/usr/bin/env bash
# Per-component health loop (Dollhouse component-health-verification skill). Read-only; prints a markdown report.
# Usage: scripts/health.sh [--no-sim] > docs/health/$(date +%F).md
# Honesty rules: a cell is ✅ only if that check ran for that component; skipped/unscanned/failed tooling shows as
# ⏭ (skipped), — (not applicable), or ❓ (tool failed), never as ✅.
set -uo pipefail
cd "$(dirname "$0")/.."
# Respect an existing xcode-select / DEVELOPER_DIR; only fall back to /Applications/Xcode.app when xcodebuild is unusable.
if ! xcodebuild -version >/dev/null 2>&1 && [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
NO_SIM=0; [[ "${1:-}" == "--no-sim" ]] && NO_SIM=1
date_str=$(date +%F); commit=$(git rev-parse --short HEAD)
tooling="swift $(swift --version 2>&1 | head -1 | sed -E 's/.*Swift version ([0-9.]+).*/\1/'), swiftlint $(swiftlint version), periphery $(periphery version), xcodegen $(xcodegen --version | awk '{print $2}')"
rows=(); findings=(); red=0; yellow=0; green=0
mark() { [[ "$1" -eq 0 ]] && echo "✅" || echo "❌"; }

# Whole-package passes once; per-component attribution by path. Tool failures are recorded, not swallowed.
swift build --build-tests >/tmp/holler-health-build.log 2>&1; build_all=$?
periphery scan --quiet >/tmp/holler-health-periphery.log 2>&1; periphery_status=$?
scripts/check-boundaries.sh >/tmp/holler-health-boundaries.log 2>&1; bounds_all=$?
# Simulator lane per scheme so an early failure leaves later schemes "not run" (❓) rather than "failed".
declare -a sim_schemes=() sim_results=()   # parallel arrays: scheme -> 0 ok / 1 failed / 2 not run
while IFS='|' read -r scheme platform prefix; do
  [[ -z "$scheme" || "$scheme" == \#* ]] && continue
  sim_schemes+=("$scheme")
  if [[ $NO_SIM -eq 1 ]]; then sim_results+=(2)
  elif scripts/verify.sh sim "$scheme" >"/tmp/holler-health-sim-$scheme.log" 2>&1; then sim_results+=(0)
  else sim_results+=(1); fi
done < scripts/app-schemes.txt
sim_result_for() { local i; for i in "${!sim_schemes[@]}"; do [[ "${sim_schemes[$i]}" == "$1" ]] && { echo "${sim_results[$i]}"; return; }; done; echo 2; }
# Shared app code compiles into every scheme: worst result wins (1 > 2 > 0).
sim_result_shared() { local r=0 i; for i in "${!sim_results[@]}"; do [[ "${sim_results[$i]}" -eq 1 ]] && { echo 1; return; }; [[ "${sim_results[$i]}" -eq 2 ]] && r=2; done; echo $r; }
bounds_checker_ok=1; grep -qE "boundaries OK|^(Sources|Tests|Apps)/" /tmp/holler-health-boundaries.log || bounds_checker_ok=0

# Prints a finding if an ATS exemption is actually ENABLED for this component: Info.plist/entitlements under its dir
# with <true/>, or (apps only) its own target block in project.yml setting NSAllowsArbitraryLoads: true.
ats_enabled() { # name dir
  python3 - "$1" "$2" <<'PYX'
import re, sys, pathlib
name, d = sys.argv[1], sys.argv[2]
for f in list(pathlib.Path(d).rglob("*.plist")) + list(pathlib.Path(d).rglob("*.entitlements")):
    if re.search(r"<key>NSAllowsArbitraryLoads</key>\s*<true\s*/>", f.read_text(), re.S):
        print(f"{f}: NSAllowsArbitraryLoads enabled")
proj = pathlib.Path("project.yml")
if proj.exists():
    text = proj.read_text()
    m = re.search(rf"^  {re.escape(name)}:\n(.*?)(?=^  \S|\Z)", text, re.S | re.M)
    if m and re.search(r"NSAllowsArbitraryLoads:\s*(true|YES|yes)\b", m.group(1)):
        print(f"project.yml target {name}: NSAllowsArbitraryLoads enabled")
PYX
}

# Multiline-aware scan for swallowed errors: `catch {` ... `}` with only whitespace between (any line layout).
empty_catches() { # dir
  python3 - "$1" <<'PYX'
import re, sys, pathlib
for f in pathlib.Path(sys.argv[1]).rglob("*.swift"):
    if "Tests/" in str(f):
        continue
    text = f.read_text()
    for m in re.finditer(r"catch\b[^{\n]*\{\s*\}", text):
        print(f"{f}:{text.count(chr(10), 0, m.start()) + 1}: empty catch block")
PYX
}

layer_of() { grep -E "^ +$1:" docs/module-graph.yml | sed -E 's/.*layer: *([a-z]+).*/\1/'; }

check_component() { # name dir
  local name="$1" dir="$2" status="GREEN"
  local layer; layer=$(layer_of "$name"); layer=${layer:-unknown}
  local bcell tcell lcell dcell bocell szcell rcell dicell
  # --- build / tests: package targets from SwiftPM; app targets from the simulator lane
  if [[ "$layer" == "app" ]]; then
    local sr; if [[ "$name" == "Shared" ]]; then sr=$(sim_result_shared); else sr=$(sim_result_for "$name"); fi
    case $sr in 0) bcell="✅"; tcell="✅";; 1) bcell="❌"; tcell="❌"; status="RED";; *) bcell="❓"; tcell="❓"; status="YELLOW";; esac
    dcell="—"  # periphery scans only SwiftPM targets; app sources are not analyzed
  else
    if grep -qE "^$PWD/$dir/.*error:" /tmp/holler-health-build.log; then bcell="❌"; status="RED"
    elif (( build_all != 0 )); then bcell="❓"; status="YELLOW"; findings+=("**$name** build unverified: package build failed without a diagnostic attributable to this component")
    else bcell="✅"; fi
    if [[ -d "Tests/${name}Tests" ]]; then
      if grep -qE "^$PWD/Tests/${name}Tests/.*error:" /tmp/holler-health-build.log; then tcell="❌"; status="RED"
        findings+=("**$name** test target failed to compile: $(grep -E "^$PWD/Tests/${name}Tests/.*error:" /tmp/holler-health-build.log | head -2 | sed "s#$PWD/##")")
      elif (( build_all != 0 )); then tcell="❓"; [[ $status == GREEN ]] && status="YELLOW"
      elif swift test --skip-build --filter "${name}Tests" >/tmp/holler-health-test-"$name".log 2>&1; then tcell="✅"
      else tcell="❌"; status="RED"
        findings+=("**$name** tests failed: $(grep -E '✘|error:' /tmp/holler-health-test-"$name".log | head -3 | tr '\n' ' ')")
      fi
    elif [[ "$name" == *TestSupport ]]; then tcell="—"
    else tcell="⚠️ none"; findings+=("**$name** has no test target (Tests/${name}Tests)"); [[ $status == GREEN ]] && status="YELLOW"
    fi
    if (( periphery_status != 0 )); then dcell="❓"; [[ $status == GREEN ]] && status="YELLOW"
    elif grep -q "^$PWD/$dir/" /tmp/holler-health-periphery.log; then dcell="⚠️"; [[ $status == GREEN ]] && status="YELLOW"
      findings+=("**$name** dead code: $(grep "^$PWD/$dir/" /tmp/holler-health-periphery.log | head -3 | sed "s#$PWD/##")")
    else dcell="✅"; fi
  fi
  # --- lint
  local lint_paths=("$dir"); [[ -d "Tests/${name}Tests" ]] && lint_paths+=("Tests/${name}Tests")
  swiftlint lint --strict --quiet "${lint_paths[@]}" >/tmp/holler-health-lint.log 2>&1 && lcell="✅" || { lcell="❌"; status="RED"; findings+=("**$name** lint: $(head -3 /tmp/holler-health-lint.log)"); }
  # --- boundaries: production dir and the component's own test dir
  if (( bounds_checker_ok == 0 )); then bocell="❓"; [[ $status == GREEN ]] && status="YELLOW"
  elif grep -qE "^(${dir}|Tests/${name}Tests)/" /tmp/holler-health-boundaries.log; then bocell="❌"; status="RED"
    findings+=("**$name** boundaries: $(grep -E "^(${dir}|Tests/${name}Tests)/" /tmp/holler-health-boundaries.log | head -3)")
  else bocell="✅"; fi
  # --- size
  local sz=0 n
  while IFS= read -r f; do n=$(wc -l < "$f"); (( n > 200 )) && { sz=1; findings+=("**$name** oversized: $f ($n lines > 200)"); }; done < <(find "$dir" -name '*.swift')
  if [[ -d "Tests/${name}Tests" ]]; then while IFS= read -r f; do n=$(wc -l < "$f"); (( n > 300 )) && { sz=1; findings+=("**$name** oversized test: $f ($n lines > 300)"); }; done < <(find "Tests/${name}Tests" -name '*.swift'); fi
  szcell=$([[ $sz -eq 0 ]] && echo ✅ || echo ⚠️); (( sz )) && [[ $status == GREEN ]] && status="YELLOW"
  # --- risk grep (CodeQL/Sonar precursors) in Swift, plus ATS exemptions in plists/entitlements/project.yml
  local rhits ats_out ats_status catch_out catch_status
  ats_out=$(ats_enabled "$name" "$dir" 2>/dev/null); ats_status=$?
  catch_out=$(empty_catches "$dir" 2>/dev/null); catch_status=$?
  rhits=$( { grep -nE 'try!|as!|@unchecked Sendable|arc4random|print\(' -r "$dir" --include='*.swift' 2>/dev/null | grep -v 'Tests/'; printf '%s\n' "$ats_out" "$catch_out" | sed '/^$/d'; } | head -5)
  if [[ -n "$rhits" ]]; then rcell="❌"; status="RED"; findings+=("**$name** risk grep: $rhits")
  elif (( ats_status != 0 || catch_status != 0 )); then rcell="❓"; [[ $status == GREEN ]] && status="YELLOW"; findings+=("**$name** risk grep unverified: helper exited (ats=$ats_status, catch=$catch_status)")
  else rcell="✅"; fi
  # --- DI posture: .shared / static var outside adapters and apps
  local dhits; dhits=$(grep -nE '\.shared\b|static var ' -r "$dir" --include='*.swift' 2>/dev/null | head -5)
  if [[ -n "$dhits" && "$layer" != "adapter" && "$layer" != "app" ]]; then dicell="❌"; status="RED"; findings+=("**$name** DI: $dhits"); else dicell="✅"; fi
  case "$status" in RED) red=$((red+1));; YELLOW) yellow=$((yellow+1));; *) green=$((green+1));; esac
  rows+=("| $name | $layer | $bcell | $tcell | $lcell | $dcell | $bocell | $szcell | $rcell | $dicell | $status |")
}

for dir in Sources/*/; do name=$(basename "$dir"); check_component "$name" "Sources/$name"; done
for dir in Apps/*/; do name=$(basename "$dir"); check_component "$name" "Apps/$name"; done

sim_note=""; for i in "${!sim_schemes[@]}"; do case "${sim_results[$i]}" in 0) sim_note+="${sim_schemes[$i]} ✅ ";; 1) sim_note+="${sim_schemes[$i]} ❌ ";; *) sim_note+="${sim_schemes[$i]} ❓ ";; esac; done
[[ $NO_SIM -eq 1 ]] && sim_note="⏭ skipped (--no-sim): app rows unverified"
periphery_note=$([[ $periphery_status -eq 0 ]] && echo "✅" || echo "❓ periphery exited $periphery_status (dead-code column unverified)")
bounds_note=$( (( bounds_checker_ok == 0 )) && echo "❓ checker did not complete" || mark $bounds_all )

cat <<MD
# Component health — mickdarling/holler — $date_str

Commit: \`$commit\`  Tooling: $tooling
Package build: $(mark $build_all)  Periphery: $periphery_note  Boundaries script: $bounds_note  Simulator lane: $sim_note
Legend: ✅ passed · ❌ failed · ⚠️ warning · ⏭ skipped · — not applicable · ❓ not run / tool failed (unverified)

| Component | Layer | Build | Tests | Lint | Dead code | Boundaries | Size | Risk grep | DI | Status |
|---|---|---|---|---|---|---|---|---|---|---|
$(printf '%s\n' "${rows[@]}")

## Findings
$( ((${#findings[@]})) && printf -- '- %s\n' "${findings[@]}" || echo "none" )

## Totals
GREEN $green · YELLOW $yellow · RED $red
MD
