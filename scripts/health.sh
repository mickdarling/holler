#!/usr/bin/env bash
# Per-component health loop (Dollhouse component-health-verification skill). Read-only; prints a markdown report.
# Usage: scripts/health.sh [--no-sim] > docs/health/$(date +%F).md
set -uo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
NO_SIM=0; [[ "${1:-}" == "--no-sim" ]] && NO_SIM=1
date_str=$(date +%F); commit=$(git rev-parse --short HEAD)
tooling="swift $(swift --version 2>&1 | head -1 | sed -E 's/.*Swift version ([0-9.]+).*/\1/'), swiftlint $(swiftlint version), periphery $(periphery version), xcodegen $(xcodegen --version | awk '{print $2}')"
rows=(); findings=(); red=0; yellow=0; green=0
mark() { [[ "$1" -eq 0 ]] && echo "✅" || echo "❌"; }

# One package build/test/periphery pass; per-component attribution by path (cheaper and identical in outcome).
swift build --build-tests >/tmp/holler-health-build.log 2>&1; build_all=$?
swift test --parallel >/tmp/holler-health-test.log 2>&1; test_all=$?
periphery scan --quiet >/tmp/holler-health-periphery.log 2>&1 || true
scripts/check-boundaries.sh >/tmp/holler-health-boundaries.log 2>&1; bounds_all=$?

layer_of() { grep -E "^ +$1:" docs/module-graph.yml | sed -E 's/.*layer: *([a-z]+).*/\1/'; }

check_component() { # name dir
  local name="$1" dir="$2" status="GREEN" notes=()
  local layer; layer=$(layer_of "$name"); layer=${layer:-unknown}
  # build: any compile error mentioning this dir
  local b=0; grep -E "^$PWD/$dir/.*error:" /tmp/holler-health-build.log -q && b=1
  # tests: does a test target exist and did its suites pass
  local t=0 tt="Tests/${name}Tests"
  if [[ -d "$tt" ]]; then grep -E "✘" /tmp/holler-health-test.log | grep -q "${name}Tests" && t=1; [[ $test_all -ne 0 ]] && grep -q "${name}Tests" /tmp/holler-health-test.log && t=1
  elif [[ "$name" == *TestSupport ]]; then t=0
  else
    case "$layer" in core|adapter|feature) t=2 ;; *) t=0 ;; esac
  fi
  # lint
  local l=0; swiftlint lint --strict --quiet "$dir" >/tmp/holler-health-lint.log 2>&1 || l=1
  # deadcode attributed by path
  local d=0; grep -q "^$PWD/$dir/" /tmp/holler-health-periphery.log && d=1
  # boundaries attributed by path
  local bo=0; grep -q "^$dir/" /tmp/holler-health-boundaries.log && bo=1
  # size
  local sz=0; while IFS= read -r f; do n=$(wc -l < "$f"); (( n > 200 )) && sz=1; done < <(find "$dir" -name '*.swift')
  # risk grep (CodeQL/Sonar precursors)
  local r=0 rhits
  rhits=$(grep -nE 'try!|as!|@unchecked Sendable|catch\s*\{\s*\}|arc4random|NSAllowsArbitraryLoads|print\(' -r "$dir" --include='*.swift' 2>/dev/null | grep -v 'Tests/' | head -5)
  [[ -n "$rhits" ]] && r=1
  # DI posture: .shared / static var outside adapters
  local di=0 dhits
  dhits=$(grep -nE '\.shared\b|static var ' -r "$dir" --include='*.swift' 2>/dev/null | head -5)
  [[ -n "$dhits" && "$layer" != "adapter" && "$layer" != "app" ]] && di=1
  # status
  (( b || l || bo || r || di || t == 1 )) && status="RED"
  if [[ "$status" == "GREEN" ]] && (( d == 1 || sz == 1 || t == 2 )); then status="YELLOW"; fi
  case "$status" in RED) red=$((red+1));; YELLOW) yellow=$((yellow+1));; *) green=$((green+1));; esac
  local tcell; case $t in 0) tcell="✅";; 1) tcell="❌";; 2) tcell="⚠️ none";; esac
  rows+=("| $name | $layer | $(mark $b) | $tcell | $(mark $l) | $([[ $d -eq 0 ]] && echo ✅ || echo ⚠️) | $(mark $bo) | $([[ $sz -eq 0 ]] && echo ✅ || echo ⚠️) | $(mark $r) | $(mark $di) | $status |")
  (( l )) && findings+=("**$name** lint: $(head -3 /tmp/holler-health-lint.log | sed 's/^/    /')")
  (( d )) && findings+=("**$name** dead code: $(grep "^$PWD/$dir/" /tmp/holler-health-periphery.log | head -3 | sed "s#$PWD/##")")
  [[ -n "$rhits" ]] && findings+=("**$name** risk grep: $rhits")
  (( di )) && findings+=("**$name** DI: $dhits")
  (( t == 2 )) && findings+=("**$name** has no test target (Tests/${name}Tests)")
  (( bo )) && findings+=("**$name** boundaries: $(grep "^$dir/" /tmp/holler-health-boundaries.log | head -3)")
}

for dir in Sources/*/; do name=$(basename "$dir"); check_component "$name" "Sources/$name"; done
for dir in Apps/*/; do name=$(basename "$dir"); check_component "$name" "Apps/$name"; done

sim_note="skipped (--no-sim)"
if [[ $NO_SIM -eq 0 ]]; then
  if scripts/verify.sh sim >/tmp/holler-health-sim.log 2>&1; then sim_note="✅ all app schemes built and tested"; else sim_note="❌ see scripts/verify.sh sim"; red=$((red+1)); fi
fi

cat <<MD
# Component health — mickdarling/holler — $date_str

Commit: \`$commit\`  Tooling: $tooling
Package build: $(mark $build_all)  Package tests: $(mark $test_all)  Simulator lane: $sim_note

| Component | Layer | Build | Tests | Lint | Dead code | Boundaries | Size | Risk grep | DI | Status |
|---|---|---|---|---|---|---|---|---|---|---|
$(printf '%s\n' "${rows[@]}")

## Findings
$( ((${#findings[@]})) && printf -- '- %s\n' "${findings[@]}" || echo "none" )

## Totals
GREEN $green · YELLOW $yellow · RED $red
MD
