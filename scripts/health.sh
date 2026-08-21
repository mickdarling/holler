#!/usr/bin/env bash
# Per-component health loop (Dollhouse component-health-verification skill). Read-only; prints a markdown report.
# Usage: scripts/health.sh [--no-sim] > docs/health/$(date +%F).md
# Honesty rules: a cell is ✅ only if that check ran for that component; skipped/unscanned/failed tooling shows as
# ⏭ (skipped), — (not applicable), or ❓ (tool failed), never as ✅.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
LOG=$(mktemp -d "${TMPDIR:-/tmp}/holler-health.XXXXXX")  # per-run evidence; concurrent runs never share logs
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
swift build --build-tests >"$LOG/build.log" 2>&1; build_all=$?
# Declared SwiftPM targets: a Sources/<name> directory that is not a target is never compiled, so its row is unverified.
pkg_targets=$(swift package describe --type json 2>/dev/null | python3 -c 'import json,sys; print("\n".join(t["name"] for t in json.load(sys.stdin)["targets"]))' 2>/dev/null)
is_pkg_target() { grep -qx -- "$1" <<<"$pkg_targets"; }
periphery scan --quiet >"$LOG/periphery.log" 2>&1; periphery_status=$?
# Periphery coverage: it indexes every package target except `exclude_targets` (Periphery 3.x has no include list; an
# invalid key such as `targets` is ignored with a warning, surfaced in the header). An excluded component is unscanned.
periphery_excluded=$(python3 - <<'PYX'
import re, pathlib
text = pathlib.Path(".periphery.yml").read_text() if pathlib.Path(".periphery.yml").exists() else ""
m = re.search(r"^exclude_targets:\s*\n((?:\s+-\s*.+\n?)+)", text, re.M)
print("\n".join(re.findall(r"-\s*(\S+)", m.group(1))) if m else "")
PYX
)
periphery_config_warning=$(grep -E "^warning: \.periphery\.yml" "$LOG/periphery.log" | head -1)
is_periphery_scanned() { ! grep -qx -- "$1" <<<"$periphery_excluded"; }
scripts/check-boundaries.sh >"$LOG/boundaries.log" 2>&1; bounds_all=$?
# Simulator lane per scheme so an early failure leaves later schemes "not run" (❓) rather than "failed".
declare -a sim_schemes=() sim_results=()   # parallel arrays: scheme -> 0 ok / 1 failed / 2 not run / 3 environment failure
SIM_ENV_RE='no available [A-Za-z]+ simulator matching|command not found|xcrun: error|Unable to find a destination|xcode-select: error'
sim_env_failure() { grep -qE "$SIM_ENV_RE" "$1"; }
# Environment excerpt for an app row: its own scheme log; for Shared, the first scheme that hit an environment failure.
sim_env_excerpt() { local i log="$LOG/sim-$1.log"; if [[ "$1" == "Shared" ]]; then for i in "${!sim_results[@]}"; do [[ "${sim_results[$i]}" -eq 3 ]] && { log="$LOG/sim-${sim_schemes[$i]}.log"; break; }; done; fi; grep -hE "$SIM_ENV_RE" "$log" 2>/dev/null | head -1; }
while IFS='|' read -r scheme _ _; do
  [[ -z "$scheme" || "$scheme" == \#* ]] && continue
  sim_schemes+=("$scheme")
  if [[ $NO_SIM -eq 1 ]]; then sim_results+=(2)
  elif scripts/verify.sh sim "$scheme" >"$LOG/sim-$scheme.log" 2>&1; then sim_results+=(0)
  elif sim_env_failure "$LOG/sim-$scheme.log"; then sim_results+=(3)
  else sim_results+=(1); fi
done < scripts/app-schemes.txt
sim_result_for() { local i; for i in "${!sim_schemes[@]}"; do [[ "${sim_schemes[$i]}" == "$1" ]] && { echo "${sim_results[$i]}"; return; }; done; echo 2; }
# Shared app code compiles into every scheme: worst result wins (1 > 3 > 2 > 0).
sim_result_shared() { local r=0 i; for i in "${!sim_results[@]}"; do case "${sim_results[$i]}" in 1) echo 1; return;; 3) r=3;; 2) [[ $r -eq 0 ]] && r=2;; esac; done; echo $r; }
# A failed scheme either did not build or built and then failed its (package) test suites: two different cells.
sim_build_failed() { grep -qE "Testing cancelled because the build failed|BUILD FAILED|The following build commands failed" "$1"; }
# App schemes own no test bundle yet: the lane runs the package suites on the simulator, which is not an app test.
app_has_tests() { [[ -d "Tests/$1Tests" ]]; }
# Log for a failed app row: the named scheme's own log, or for Shared the first scheme that actually failed.
failed_sim_log() { local i; if [[ "$1" != "Shared" ]]; then echo "$LOG/sim-$1.log"; return; fi; for i in "${!sim_results[@]}"; do [[ "${sim_results[$i]}" -eq 1 ]] && { echo "$LOG/sim-${sim_schemes[$i]}.log"; return; }; done; }
bounds_checker_ok=1; grep -qE "boundaries OK|^(Sources|Tests|Apps)/" "$LOG/boundaries.log" || bounds_checker_ok=0

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
    for m in re.finditer(r"catch\b[^{]*\{\s*\}", text):
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
    local app_tests="—"; app_has_tests "$name" && app_tests="✅"  # no app-owned tests: the cell is not applicable
    case $sr in
      0) bcell="✅"; tcell="$app_tests";;
      1) status="RED"
         local simlog; simlog=$(failed_sim_log "$name")
         if sim_build_failed "$simlog"; then bcell="❌"; tcell="—"
           findings+=("**$name** simulator lane: build failed: $(grep -E '❌|error:' "$simlog" 2>/dev/null | head -3 | tr '\n' ' ')")
         else bcell="✅"; tcell=$(app_has_tests "$name" && echo "❌" || echo "—")
           findings+=("**$name** simulator lane: tests failed under this scheme (package suites on the simulator): $(grep -E '✘|error:|\*\* TEST' "$simlog" 2>/dev/null | head -3 | tr '\n' ' ')")
         fi;;
      3) bcell="❓"; tcell="❓"; status="YELLOW"; findings+=("**$name** simulator lane unverified (environment failure): $(sim_env_excerpt "$name")");;
      *) bcell="❓"; tcell="❓"; status="YELLOW";;
    esac
    dcell="—"  # periphery scans only SwiftPM targets; app sources are not analyzed
  elif ! is_pkg_target "$name"; then
    bcell="❓"; tcell="❓"; dcell="❓"; status="YELLOW"
    findings+=("**$name** unverified: Sources/$name is not a target in Package.swift (nothing here is compiled or tested)")
  else
    if grep -qE "^$PWD/$dir/.*error:" "$LOG/build.log"; then bcell="❌"; status="RED"
      findings+=("**$name** build errors: $(grep -E "^$PWD/$dir/.*error:" "$LOG/build.log" | head -3 | sed "s#$PWD/##" | tr '\n' ' ')")
    elif (( build_all != 0 )); then bcell="❓"; status="YELLOW"; findings+=("**$name** build unverified: package build failed without a diagnostic attributable to this component")
    else bcell="✅"; fi
    if [[ -d "Tests/${name}Tests" ]]; then
      if grep -qE "^$PWD/Tests/${name}Tests/.*error:" "$LOG/build.log"; then tcell="❌"; status="RED"
        findings+=("**$name** test target failed to compile: $(grep -E "^$PWD/Tests/${name}Tests/.*error:" "$LOG/build.log" | head -2 | sed "s#$PWD/##")")
      elif (( build_all != 0 )); then tcell="❓"; [[ $status == GREEN ]] && status="YELLOW"
      elif swift test --skip-build --filter "${name}Tests" >"$LOG/test-$name.log" 2>&1; then
        # Exit 0 with zero executed tests (target missing from Package.swift, filter mismatch) is not a pass.
        if grep -qE "Test run with [1-9][0-9]* tests?" "$LOG/test-$name.log"; then tcell="✅"
        else tcell="❓"; [[ $status == GREEN ]] && status="YELLOW"; findings+=("**$name** tests unverified: swift test exited 0 but executed no tests (filter ${name}Tests)"); fi
      else tcell="❌"; status="RED"
        findings+=("**$name** tests failed: $(grep -E '✘|error:' "$LOG/test-$name.log" | head -3 | tr '\n' ' ')")
      fi
    elif [[ "$name" == *TestSupport ]]; then tcell="—"
    else tcell="⚠️ none"; findings+=("**$name** has no test target (Tests/${name}Tests)"); [[ $status == GREEN ]] && status="YELLOW"
    fi
    if (( periphery_status != 0 )); then dcell="❓"; [[ $status == GREEN ]] && status="YELLOW"
    elif ! is_periphery_scanned "$name"; then dcell="❓"; [[ $status == GREEN ]] && status="YELLOW"
      findings+=("**$name** dead code unverified: target is in .periphery.yml exclude_targets")
    elif grep -q "^$PWD/$dir/" "$LOG/periphery.log"; then dcell="⚠️"; [[ $status == GREEN ]] && status="YELLOW"
      findings+=("**$name** dead code: $(grep "^$PWD/$dir/" "$LOG/periphery.log" | head -3 | sed "s#$PWD/##")")
    else dcell="✅"; fi
  fi
  # --- lint
  local lint_paths=("$dir"); [[ -d "Tests/${name}Tests" ]] && lint_paths+=("Tests/${name}Tests")
  local lint_log="$LOG/lint-$name.log" lint_status lint_diag_re=':[0-9]+:[0-9]+: (error|warning):'
  swiftlint lint --strict --quiet "${lint_paths[@]}" >"$lint_log" 2>&1; lint_status=$?
  if (( lint_status == 0 )); then lcell="✅"
  elif grep -qE "$lint_diag_re" "$lint_log"; then lcell="❌"; status="RED"
    findings+=("**$name** lint: $(grep -E "$lint_diag_re" "$lint_log" | head -3 | sed "s#$PWD/##" | tr '\n' ' ')")
  else lcell="❓"; [[ $status == GREEN ]] && status="YELLOW"  # tool missing/crashed/config error: nothing was checked
    findings+=("**$name** lint unverified: swiftlint exited $lint_status without diagnostics: $(head -1 "$lint_log")")
  fi
  # --- boundaries: production dir and the component's own test dir
  if (( bounds_checker_ok == 0 )); then bocell="❓"; [[ $status == GREEN ]] && status="YELLOW"
  elif [[ "$layer" == "unknown" ]]; then bocell="❓"; [[ $status == GREEN ]] && status="YELLOW"  # checker skips modules missing from the graph
    findings+=("**$name** boundaries unverified: not declared in docs/module-graph.yml (imports are not checked)")
  elif grep -qE "^(${dir}|Tests/${name}Tests)/" "$LOG/boundaries.log"; then bocell="❌"; status="RED"
    findings+=("**$name** boundaries: $(grep -E "^(${dir}|Tests/${name}Tests)/" "$LOG/boundaries.log" | head -3)")
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

sim_note=""; for i in "${!sim_schemes[@]}"; do case "${sim_results[$i]}" in 0) sim_note+="${sim_schemes[$i]} ✅ ";; 1) sim_note+="${sim_schemes[$i]} ❌ ";; 3) sim_note+="${sim_schemes[$i]} ❓(env) ";; *) sim_note+="${sim_schemes[$i]} ❓ ";; esac; done
[[ $NO_SIM -eq 1 ]] && sim_note="⏭ skipped (--no-sim): app rows unverified"
periphery_note=$([[ $periphery_status -eq 0 ]] && echo "✅${periphery_config_warning:+ (⚠️ $periphery_config_warning)}" || echo "❓ periphery exited $periphery_status (dead-code column unverified)")
bounds_note=$( (( bounds_checker_ok == 0 )) && echo "❓ checker did not complete" || mark $bounds_all )

cat <<MD
# Component health — mickdarling/holler — $date_str

Commit: \`$commit\`  Tooling: $tooling
Package build: $(mark $build_all)  Periphery: $periphery_note  Boundaries script: $bounds_note  Simulator lane: $sim_note
Legend: ✅ passed · ❌ failed · ⚠️ warning · ⏭ skipped · — not applicable · ❓ not run / tool or environment failed (unverified)

| Component | Layer | Build | Tests | Lint | Dead code | Boundaries | Size | Risk grep | DI | Status |
|---|---|---|---|---|---|---|---|---|---|---|
$(printf '%s\n' "${rows[@]}")

## Findings
$( ((${#findings[@]})) && printf -- '- %s\n' "${findings[@]}" || echo "none" )

## Totals
GREEN $green · YELLOW $yellow · RED $red
MD
