#!/usr/bin/env bash
# Per-component health loop (Dollhouse component-health-verification skill). Read-only; prints a markdown report.
# Usage: scripts/health.sh [--no-sim] > docs/health/$(date +%F).md
# Honesty rules: a cell is ✅ only if that check ran for that component; skipped/unscanned/failed tooling shows as
# ⏭ (skipped), — (not applicable), or ❓ (tool failed), never as ✅.
set -uo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
NO_SIM=0; [[ "${1:-}" == "--no-sim" ]] && NO_SIM=1
date_str=$(date +%F); commit=$(git rev-parse --short HEAD)
tooling="swift $(swift --version 2>&1 | head -1 | sed -E 's/.*Swift version ([0-9.]+).*/\1/'), swiftlint $(swiftlint version), periphery $(periphery version), xcodegen $(xcodegen --version | awk '{print $2}')"
rows=(); findings=(); red=0; yellow=0; green=0
mark() { [[ "$1" -eq 0 ]] && echo "✅" || echo "❌"; }

# Whole-package passes once; per-component attribution by path. Tool failures are recorded, not swallowed.
swift build --build-tests >/tmp/holler-health-build.log 2>&1; build_all=$?
periphery scan --quiet >/tmp/holler-health-periphery.log 2>&1; periphery_status=$?
scripts/check-boundaries.sh >/tmp/holler-health-boundaries.log 2>&1; bounds_all=$?
sim_status=2  # 0 ok, 1 failed, 2 skipped
if [[ $NO_SIM -eq 0 ]]; then scripts/verify.sh sim >/tmp/holler-health-sim.log 2>&1 && sim_status=0 || sim_status=1; fi

layer_of() { grep -E "^ +$1:" docs/module-graph.yml | sed -E 's/.*layer: *([a-z]+).*/\1/'; }

check_component() { # name dir
  local name="$1" dir="$2" status="GREEN"
  local layer; layer=$(layer_of "$name"); layer=${layer:-unknown}
  local bcell tcell lcell dcell bocell szcell rcell dicell
  # --- build / tests: package targets from SwiftPM; app targets from the simulator lane
  if [[ "$layer" == "app" ]]; then
    case $sim_status in 0) bcell="✅"; tcell="✅";; 1) bcell="❌"; tcell="❌"; status="RED";; *) bcell="⏭"; tcell="⏭"; status="YELLOW";; esac
    dcell="—"  # periphery scans only SwiftPM targets; app sources are not analyzed
  else
    local b=0; grep -qE "^$PWD/$dir/.*error:" /tmp/holler-health-build.log && b=1; bcell=$(mark $b); (( b )) && status="RED"
    if [[ -d "Tests/${name}Tests" ]]; then
      swift test --skip-build --filter "${name}Tests" >/tmp/holler-health-test-"$name".log 2>&1 && tcell="✅" || { tcell="❌"; status="RED"; }
    elif [[ "$name" == *TestSupport ]]; then tcell="—"
    else tcell="⚠️ none"; findings+=("**$name** has no test target (Tests/${name}Tests)"); [[ $status == GREEN ]] && status="YELLOW"
    fi
    if (( periphery_status != 0 )); then dcell="❓"; [[ $status == GREEN ]] && status="YELLOW"
    elif grep -q "^$PWD/$dir/" /tmp/holler-health-periphery.log; then dcell="⚠️"; [[ $status == GREEN ]] && status="YELLOW"
      findings+=("**$name** dead code: $(grep "^$PWD/$dir/" /tmp/holler-health-periphery.log | head -3 | sed "s#$PWD/##")")
    else dcell="✅"; fi
  fi
  # --- lint
  swiftlint lint --strict --quiet "$dir" >/tmp/holler-health-lint.log 2>&1 && lcell="✅" || { lcell="❌"; status="RED"; findings+=("**$name** lint: $(head -3 /tmp/holler-health-lint.log)"); }
  # --- boundaries: production dir and the component's own test dir
  if grep -qE "^(${dir}|Tests/${name}Tests)/" /tmp/holler-health-boundaries.log; then bocell="❌"; status="RED"
    findings+=("**$name** boundaries: $(grep -E "^(${dir}|Tests/${name}Tests)/" /tmp/holler-health-boundaries.log | head -3)")
  else bocell="✅"; fi
  # --- size
  local sz=0; while IFS= read -r f; do (( $(wc -l < "$f") > 200 )) && sz=1; done < <(find "$dir" -name '*.swift'); szcell=$([[ $sz -eq 0 ]] && echo ✅ || echo ⚠️); (( sz )) && [[ $status == GREEN ]] && status="YELLOW"
  # --- risk grep (CodeQL/Sonar precursors) in Swift, plus ATS exemptions in plists/entitlements/project.yml
  local rhits; rhits=$( { grep -nE 'try!|as!|@unchecked Sendable|catch\s*\{\s*\}|arc4random|print\(' -r "$dir" --include='*.swift' 2>/dev/null | grep -v 'Tests/'; grep -nE 'NSAllowsArbitraryLoads' -r "$dir" project.yml --include='*.plist' --include='*.entitlements' --include='*.yml' 2>/dev/null; } | head -5)
  if [[ -n "$rhits" ]]; then rcell="❌"; status="RED"; findings+=("**$name** risk grep: $rhits"); else rcell="✅"; fi
  # --- DI posture: .shared / static var outside adapters and apps
  local dhits; dhits=$(grep -nE '\.shared\b|static var ' -r "$dir" --include='*.swift' 2>/dev/null | head -5)
  if [[ -n "$dhits" && "$layer" != "adapter" && "$layer" != "app" ]]; then dicell="❌"; status="RED"; findings+=("**$name** DI: $dhits"); else dicell="✅"; fi
  case "$status" in RED) red=$((red+1));; YELLOW) yellow=$((yellow+1));; *) green=$((green+1));; esac
  rows+=("| $name | $layer | $bcell | $tcell | $lcell | $dcell | $bocell | $szcell | $rcell | $dicell | $status |")
}

for dir in Sources/*/; do name=$(basename "$dir"); check_component "$name" "Sources/$name"; done
for dir in Apps/*/; do name=$(basename "$dir"); check_component "$name" "Apps/$name"; done

case $sim_status in 0) sim_note="✅ all app schemes built and tested";; 1) sim_note="❌ see scripts/verify.sh sim";; *) sim_note="⏭ skipped (--no-sim): app rows unverified";; esac
periphery_note=$([[ $periphery_status -eq 0 ]] && echo "✅" || echo "❓ periphery exited $periphery_status (dead-code column unverified)")
bounds_note=$(mark $bounds_all)

cat <<MD
# Component health — mickdarling/holler — $date_str

Commit: \`$commit\`  Tooling: $tooling
Package build: $(mark $build_all)  Periphery: $periphery_note  Boundaries script: $bounds_note  Simulator lane: $sim_note
Legend: ✅ passed · ❌ failed · ⚠️ warning · ⏭ skipped · — not applicable · ❓ tool failed

| Component | Layer | Build | Tests | Lint | Dead code | Boundaries | Size | Risk grep | DI | Status |
|---|---|---|---|---|---|---|---|---|---|---|
$(printf '%s\n' "${rows[@]}")

## Findings
$( ((${#findings[@]})) && printf -- '- %s\n' "${findings[@]}" || echo "none" )

## Totals
GREEN $green · YELLOW $yellow · RED $red
MD
