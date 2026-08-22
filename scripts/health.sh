#!/usr/bin/env bash
# Per-component health loop (Dollhouse component-health-verification skill). Prints a markdown report. Does not modify
# tracked sources (it does build into .build/ and regenerate Holler.xcodeproj through scripts/verify.sh).
# Usage: scripts/health.sh [--no-sim] > docs/health/$(date +%F).md     (HOLLER_HEALTH_KEEP_LOGS=1 keeps the evidence dir)
# Honesty rules: a cell is ✅ only if that check ran for that component; skipped/unscanned/failed tooling shows as
# ⏭ (skipped), — (not applicable), or ❓ (tool failed), never as ✅.
set -uo pipefail
cd -P "$(dirname "$0")/.." || exit 1   # -P: tools print physical paths; ROOT must match them (symlinked checkouts)
ROOT=$PWD
LOG=$(mktemp -d "${TMPDIR:-/tmp}/holler-health.XXXXXX") || exit 1  # per-run evidence; concurrent runs never share logs
if [[ "${HOLLER_HEALTH_KEEP_LOGS:-0}" == "1" ]]; then echo "evidence logs: $LOG" >&2; else trap 'rm -rf "$LOG"' EXIT; fi
strip_ansi() { sed $'s/\033\[[0-9;]*m//g'; }
strip_root() { awk -v r="$ROOT/" '{ i = index($0, r); if (i) $0 = substr($0, 1, i - 1) substr($0, i + length(r)); print }'; }  # literal
# Same local fallback as scripts/verify.sh: when xcode-select points at CommandLineTools, the Swift Testing frameworks
# live in Xcode, so select it and pass the framework search paths to swift build/test. CI selects Xcode explicitly.
SWIFT_FLAGS=()
if ! xcodebuild -version >/dev/null 2>&1 && [[ -d /Applications/Xcode.app ]]; then
  XCODE_FW=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks
  SWIFT_FLAGS=(-Xswiftc "-F$XCODE_FW" -Xlinker "-F$XCODE_FW" -Xlinker -rpath -Xlinker "$XCODE_FW")
  export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
fi
NO_SIM=0; [[ "${1:-}" == "--no-sim" ]] && NO_SIM=1
date_str=$(date +%F); commit=$(git rev-parse --short HEAD)
tooling="swift $(swift --version 2>&1 | head -1 | sed -E 's/.*Swift version ([0-9.]+).*/\1/'), swiftlint $(swiftlint version), periphery $(periphery version), xcodegen $(xcodegen --version | awk '{print $2}')"
rows=(); findings=(); red=0; yellow=0; green=0
mark() { [[ "$1" -eq 0 ]] && echo "✅" || echo "❌"; }

# Whole-package passes once; per-component attribution by path. Tool failures are recorded, not swallowed.
swift build --build-tests ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} >"$LOG/build.log" 2>&1; build_all=$?
# Declared SwiftPM targets: a Sources/<name> directory that is not a target is never compiled, so its row is unverified.
# name|path|type per declared target (path is relative to the package root; custom paths are honoured).
pkg_target_rows=$(swift package describe --type json 2>/dev/null | python3 -c 'import json,sys
for t in sorted(json.load(sys.stdin)["targets"], key=lambda t: t["name"]): print("%s|%s|%s" % (t["name"], t.get("path", ""), t.get("type", "")))' 2>/dev/null)
pkg_targets=$(cut -d'|' -f1 <<<"$pkg_target_rows")
is_pkg_target() { grep -qx -- "$1" <<<"$pkg_targets"; }
pkg_targets_known() { [[ -n "$pkg_targets" ]]; }  # empty = `swift package describe` failed: say so, do not blame Package.swift
periphery scan --quiet >"$LOG/periphery.log" 2>&1; periphery_status=$?
# Periphery coverage: it indexes every package target except `exclude_targets` (Periphery 3.x has no include list; an
# invalid key such as `targets` is ignored with a warning, surfaced in the header). An excluded component is unscanned.
periphery_excluded=$(python3 - <<'PYX'
import re, pathlib
text = pathlib.Path(".periphery.yml").read_text() if pathlib.Path(".periphery.yml").exists() else ""
names = []
for i, line in enumerate(text.splitlines()):
    m = re.match(r"^exclude_targets:\s*(.*?)\s*(#.*)?$", line)
    if not m: continue
    rest = m.group(1)
    if rest.startswith("["):                       # flow form: exclude_targets: [A, "B"]
        names += [x.strip().strip("'\"") for x in rest.strip("[]").split(",") if x.strip()]
    else:                                          # block form: "- A" / "- 'B'" lines that follow
        for follower in text.splitlines()[i + 1:]:
            b = re.match(r"^\s+-\s*(.+?)\s*(#.*)?$", follower)
            if not b: break
            names.append(b.group(1).strip().strip("'\""))
    break
print("\n".join(n for n in names if n))
PYX
)
periphery_config_warning=$(grep -E "^warning: \.periphery\.yml" "$LOG/periphery.log" | head -1)
is_periphery_scanned() { ! grep -qx -- "$1" <<<"$periphery_excluded"; }
scripts/check-boundaries.sh >"$LOG/boundaries.log" 2>&1; bounds_all=$?
# Simulator lane per scheme so an early failure leaves later schemes "not run" (❓) rather than "failed".
declare -a sim_schemes=() sim_results=()   # parallel arrays: scheme -> 0 ok / 1 failed / 2 not run / 3 environment failure
SIM_ENV_RE='no available [A-Za-z]+ simulator matching|command not found|xcrun: error|Unable to find a destination|xcode-select: error'
# Environment failures: xcbeautify rewrites "xcrun: error:" etc., so look in the raw stream first, then the wrapper log.
sim_env_failure() { grep -qE "$SIM_ENV_RE" "$(raw_log "$1")" 2>/dev/null || grep -qE "$SIM_ENV_RE" "$LOG/sim-$1.log" 2>/dev/null; }
# Classification reads the RAW xcodebuild stream ($LOG/sim-<scheme>.raw.log, via HOLLER_SIM_RAW_LOG); the beautified log
# ($LOG/sim-<scheme>.log) keeps only diagnostics and strips every outcome marker.
raw_log() { echo "$LOG/sim-$1.raw.log"; }
# Environment excerpt for an app row: its own scheme log; for Shared, the first scheme that hit an environment failure.
sim_env_excerpt() { local i scheme="$1" e; if [[ "$1" == "Shared" ]]; then for i in "${!sim_results[@]}"; do [[ "${sim_results[$i]}" -eq 3 ]] && { scheme="${sim_schemes[$i]}"; break; }; done; fi
  e=$(grep -hE "$SIM_ENV_RE" "$(raw_log "$scheme")" "$LOG/sim-$scheme.log" 2>/dev/null | strip_ansi | head -1)
  if [[ -n "$e" ]]; then echo "$e"; else echo -n "lane aborted before xcodebuild: "; tail -1 "$LOG/sim-$scheme.log" 2>/dev/null | strip_ansi; fi; }
# A failed scheme either did not build or built and then failed its (package) test suites: two different cells.
# All three predicates take the RAW xcodebuild log.
# Markers, or — if the stream was cut before them — compiler diagnostics with no test session having started.
sim_build_failed() { [[ -f "$1" ]] || return 1
  grep -qE "Testing cancelled because the build failed|The following build commands failed|\*\* BUILD FAILED \*\*" "$1" \
  || { grep -qE "^[^:]*\.swift:[0-9]+:[0-9]+: error:" "$1" && ! grep -qE "Test run started|Test Suite '(All tests|Selected tests)' started" "$1"; }; }
# Did the lane reach xcodebuild at all? Only xcodebuild's own output counts (the wrapper prints "-- <scheme> on
# <destination>" before calling it; a failure before xcodebuild — xcodegen, destination resolution — is not a build result).
sim_ran_xcodebuild() { [[ -f "$1" ]] || return 1
  grep -qE "Test session results|Testing started|Testing cancelled|\*\* TEST (FAILED|SUCCEEDED) \*\*|\*\* BUILD (FAILED|SUCCEEDED) \*\*|The following build commands failed" "$1"; }
# Does the package build log carry an error under a path prefix? One awk, not `grep | grep -q` (which can SIGPIPE the
# upstream grep under pipefail and turn a real failure into "no match").
has_error_under() { awk -v p="$1" 'index($0, p) && /error:/ { f = 1; exit } END { exit !f }' "$2"; }
# Where did a build failure come from? Paths are matched relative to $ROOT so neither regex metacharacters nor spaces
# in the checkout path matter. app = Sources/ or Apps/Shared (a dependency of every app) or the component's own dir ;
# tests = a package test target ; other-app = another app target (this one is unproven, not failed) ; unknown = no file diagnostic.
sim_build_failure_scope() { # raw-log [component-dir]
  local rel; rel=$(strip_root < "$1" | grep -E "^[^:]*\.swift:[0-9]+:[0-9]+: error:" || true)  # errors only; paths may contain spaces
  [[ -z "$rel" ]] && { echo unknown; return; }
  if grep -qE "^(Sources|Apps/Shared)/" <<<"$rel"; then echo app
  elif [[ -n "${2:-}" ]] && grep -qE "^${2}/" <<<"$rel"; then echo app
  elif grep -qE "^Tests/" <<<"$rel"; then echo tests
  elif grep -qE "^Apps/" <<<"$rel"; then echo other-app
  else echo unknown; fi; }
while IFS='|' read -r scheme _ _; do
  [[ -z "$scheme" || "$scheme" == \#* ]] && continue
  sim_schemes+=("$scheme")
  if [[ $NO_SIM -eq 1 ]]; then sim_results+=(2)
  elif HOLLER_SIM_RAW_LOG="$(raw_log "$scheme")" scripts/verify.sh sim "$scheme" >"$LOG/sim-$scheme.log" 2>&1; then sim_results+=(0)
  elif sim_env_failure "$scheme"; then sim_results+=(3)
  elif sim_build_failed "$(raw_log "$scheme")"; then sim_results+=(1)       # diagnostics present, even if the stream was cut
  elif ! sim_ran_xcodebuild "$(raw_log "$scheme")"; then sim_results+=(3)  # never reached xcodebuild
  else sim_results+=(1); fi
done < scripts/app-schemes.txt
(( ${#sim_schemes[@]} == 0 )) && echo "warning: no schemes read from scripts/app-schemes.txt; app rows are unverified" >&2
sim_result_for() { local i; for i in "${!sim_schemes[@]}"; do [[ "${sim_schemes[$i]}" == "$1" ]] && { echo "${sim_results[$i]}"; return; }; done; echo 2; }
# Shared app code compiles into every scheme, so its Build cell aggregates every scheme's BUILD outcome (not the
# scheme's test outcome): any app/dependency build failure → ❌; any lane that did not prove a build (environment
# failure, not run, test-target compile failure, unknown) → ❓; otherwise ✅.
shared_build_cell() { local i r log unverified=0
  (( ${#sim_results[@]} == 0 )) && { echo "❓"; return; }  # no scheme ran at all
  for i in "${!sim_results[@]}"; do r="${sim_results[$i]}"; log=$(raw_log "${sim_schemes[$i]}")
    case "$r" in 0) ;; 1) if sim_build_failed "$log"; then [[ "$(sim_build_failure_scope "$log")" == "app" ]] && { echo "❌"; return; }; unverified=1; fi;; *) unverified=1;; esac; done
  (( unverified )) && echo "❓" || echo "✅"; }
shared_unverified_note() { local i r; for i in "${!sim_results[@]}"; do r="${sim_results[$i]}"; case "$r" in 3) echo "${sim_schemes[$i]} (environment failure)"; return;; 2) echo "${sim_schemes[$i]} (not run)"; return;; esac; done; echo "a scheme with an unattributable build failure"; }
# Log for a failed app row: the named scheme's own log, or for Shared the first scheme that actually failed.
# Shared: the log that justifies the aggregate — an app/dependency build failure first (that is what makes the cell ❌),
# then any other build failure, then a scheme whose package suites failed.
failed_sim_log() { local i log; if [[ "$1" != "Shared" ]]; then raw_log "$1"; return; fi
  for i in "${!sim_results[@]}"; do log=$(raw_log "${sim_schemes[$i]}"); [[ "${sim_results[$i]}" -eq 1 ]] && sim_build_failed "$log" && [[ "$(sim_build_failure_scope "$log")" == "app" ]] && { echo "$log"; return; }; done
  for i in "${!sim_results[@]}"; do log=$(raw_log "${sim_schemes[$i]}"); [[ "${sim_results[$i]}" -eq 1 ]] && sim_build_failed "$log" && { echo "$log"; return; }; done
  for i in "${!sim_results[@]}"; do [[ "${sim_results[$i]}" -eq 1 ]] && { raw_log "${sim_schemes[$i]}"; return; }; done; }
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
  # --- build / tests: package targets from SwiftPM; app targets (Apps/*) from the simulator lane
  if [[ "$dir" == Apps/* ]]; then
    local sr; if [[ "$name" == "Shared" ]]; then
      # Shared: build outcome aggregated across schemes; package-suite failures stay on the lane (see Totals).
      case "$(shared_build_cell)" in
        "✅") sr=0;;
        "❌") sr=1;;
        *) sr=2; findings+=("**Shared** build $( (( NO_SIM )) && echo skipped || echo unverified): not proven on $(shared_unverified_note)");;
      esac
    else sr=$(sim_result_for "$name"); fi
    # App targets own no test bundle (project.yml schemes list package suites only), so Tests is not applicable; when
    # an app test bundle exists this must be derived from its executed-test evidence in the scheme log, not a directory.
    case $sr in
      0) bcell="✅"; tcell="—";;
      1) local simlog scheme_name; simlog=$(failed_sim_log "$name"); scheme_name=$(basename "$simlog" .raw.log | sed 's/^sim-//')
         tcell="—"
         if sim_build_failed "$simlog"; then
           case "$(sim_build_failure_scope "$simlog" "$dir")" in
             app) bcell="❌"; status="RED"
               findings+=("**$name** simulator lane ($scheme_name): build failed: $(grep -E 'error:' "$simlog" 2>/dev/null | strip_root | head -3 | tr '\n' ' ')");;
             tests) bcell="❓"; [[ $status == GREEN ]] && status="YELLOW"  # a package test target failed to compile: lane failed, app build unproven
               findings+=("Simulator lane ($scheme_name): a package test target failed to compile (app build unverified): $(grep -E 'error:' "$simlog" 2>/dev/null | strip_root | head -3 | tr '\n' ' ')");;
             other-app) bcell="❓"; [[ $status == GREEN ]] && status="YELLOW"  # another app target broke the scheme; this one is unproven
               findings+=("**$name** build unverified: scheme $scheme_name failed in another app target: $(grep -E 'error:' "$simlog" 2>/dev/null | strip_root | head -2 | tr '\n' ' ')");;
             *) bcell="❓"; [[ $status == GREEN ]] && status="YELLOW"
               findings+=("**$name** simulator lane ($scheme_name): build failed without file diagnostics (unverified): $(grep -E ': error:|^[a-z-]+: error:' "$simlog" 2>/dev/null | head -2 | cut -c1-200 | tr '\n' ' ')");;
           esac
         else bcell="✅"  # the app built; the failing suites are package tests run under this scheme — a lane failure
           # (counted in Totals), not this app target's status
           findings+=("Simulator lane ($scheme_name): package test suites failed on the simulator (not an app cell): $(grep -E '✘|: error:|\*\* TEST FAILED \*\*|^Testing failed:' "$simlog" 2>/dev/null | head -3 | cut -c1-200 | tr '\n' ' ')")
         fi;;
      3) bcell="❓"; tcell="—"; status="YELLOW"; findings+=("**$name** simulator lane unverified (environment failure): $(sim_env_excerpt "$name")");;
      *) tcell="—"; status="YELLOW"  # (Shared's own finding already names the scheme)
         if (( NO_SIM )); then bcell="⏭"; [[ "$name" != "Shared" ]] && findings+=("**$name** build skipped (--no-sim)")
         else bcell="❓"; [[ "$name" != "Shared" ]] && findings+=("**$name** build unverified: simulator lane did not run for its scheme"); fi;;
    esac
    dcell="—"  # periphery scans only SwiftPM targets; app sources are not analyzed
  elif ! pkg_targets_known; then
    bcell="❓"; tcell="❓"; dcell="❓"; status="YELLOW"
    findings+=("**$name** unverified: the SwiftPM target list is unavailable (swift package describe failed)")
  elif ! is_pkg_target "$name"; then
    bcell="❓"; tcell="❓"; dcell="❓"; status="YELLOW"
    findings+=("**$name** unverified: Sources/$name is not a target in Package.swift (nothing here is compiled or tested)")
  else
    if has_error_under "$ROOT/$dir/" "$LOG/build.log"; then bcell="❌"; status="RED"
      findings+=("**$name** build errors: $(grep -F -- "$ROOT/$dir/" "$LOG/build.log" | grep "error:" | head -3 | strip_root | tr '\n' ' ')")
    elif (( build_all != 0 )); then bcell="❓"; status="YELLOW"; findings+=("**$name** build unverified: package build failed without a diagnostic attributable to this component")
    else bcell="✅"; fi
    if [[ -d "Tests/${name}Tests" ]]; then
      if has_error_under "$ROOT/Tests/${name}Tests/" "$LOG/build.log"; then tcell="❌"; status="RED"
        findings+=("**$name** test target failed to compile: $(grep -F -- "$ROOT/Tests/${name}Tests/" "$LOG/build.log" | grep "error:" | head -2 | strip_root | tr '\n' ' ')")
      elif (( build_all != 0 )); then tcell="❓"; [[ $status == GREEN ]] && status="YELLOW"
      elif swift test --skip-build --filter "^${name}Tests\." ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} >"$LOG/test-$name.log" 2>&1; then
        # Exit 0 with zero executed tests (target missing from Package.swift, filter mismatch) is not a pass.
        # Swift Testing prints "Test run with N tests"; XCTest prints "Executed N tests".
        if grep -qE "Test run with [1-9][0-9]* tests?|Executed [1-9][0-9]* tests?" "$LOG/test-$name.log"; then tcell="✅"
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
    elif grep -qF -- "$ROOT/$dir/" "$LOG/periphery.log"; then dcell="⚠️"; [[ $status == GREEN ]] && status="YELLOW"
      findings+=("**$name** dead code: $(grep -F -- "$ROOT/$dir/" "$LOG/periphery.log" | head -3 | strip_root | tr '\n' ' ')")
    else dcell="✅"; fi
  fi
  # --- lint
  local lint_paths=("$dir"); [[ -d "Tests/${name}Tests" ]] && lint_paths+=("Tests/${name}Tests")
  local lint_log="$LOG/lint-$name.log" lint_status lint_diag_re=':[0-9]+:[0-9]+: (error|warning):'
  swiftlint lint --strict --quiet "${lint_paths[@]}" >"$lint_log" 2>&1; lint_status=$?
  if (( lint_status == 0 )); then lcell="✅"
  elif grep -qE "$lint_diag_re" "$lint_log"; then lcell="❌"; status="RED"
    findings+=("**$name** lint: $(grep -E "$lint_diag_re" "$lint_log" | head -3 | strip_root | tr '\n' ' ')")
  else lcell="❓"; [[ $status == GREEN ]] && status="YELLOW"  # tool missing/crashed/config error: nothing was checked
    findings+=("**$name** lint unverified: swiftlint exited $lint_status without diagnostics: $(head -1 "$lint_log")")
  fi
  # --- boundaries: production dir and the component's own test dir
  if (( bounds_checker_ok == 0 )); then bocell="❓"; [[ $status == GREEN ]] && status="YELLOW"
  elif [[ "$layer" == "unknown" ]]; then bocell="❓"; [[ $status == GREEN ]] && status="YELLOW"  # checker skips modules missing from the graph
    findings+=("**$name** boundaries unverified: not declared in docs/module-graph.yml (imports are not checked)")
  elif grep -qE "^(${dir}|Tests/${name}Tests)/" "$LOG/boundaries.log"; then bocell="❌"; status="RED"
    findings+=("**$name** boundaries: $(grep -E "^(${dir}|Tests/${name}Tests)/" "$LOG/boundaries.log" | head -3 | tr '\n' ' ')")
  else bocell="✅"; fi
  # --- size
  local sz=0 n
  if [[ ! -d "$dir" ]]; then szcell="❓"; [[ $status == GREEN ]] && status="YELLOW"; findings+=("**$name** size unverified: $dir is not a directory")
  else
    while IFS= read -r f; do n=$(wc -l < "$f" | tr -d ' '); (( n > 200 )) && { sz=1; findings+=("**$name** oversized: $f ($n lines > 200)"); }; done < <(find "$dir" -name '*.swift')
    if [[ -d "Tests/${name}Tests" ]]; then while IFS= read -r f; do n=$(wc -l < "$f" | tr -d ' '); (( n > 300 )) && { sz=1; findings+=("**$name** oversized test: $f ($n lines > 300)"); }; done < <(find "Tests/${name}Tests" -name '*.swift'); fi
    szcell=$([[ $sz -eq 0 ]] && echo ✅ || echo ⚠️); (( sz )) && [[ $status == GREEN ]] && status="YELLOW"
  fi
  # --- risk grep (CodeQL/Sonar precursors) in Swift, plus ATS exemptions in plists/entitlements/project.yml
  local rhits ats_out ats_status catch_out catch_status
  ats_out=$(ats_enabled "$name" "$dir" 2>/dev/null); ats_status=$?
  catch_out=$(empty_catches "$dir" 2>/dev/null); catch_status=$?
  rhits=$( { grep -nE 'try!|as!|@unchecked Sendable|arc4random|print\(' -r "$dir" --include='*.swift' 2>/dev/null | grep -v 'Tests/'; printf '%s\n' "$ats_out" "$catch_out" | sed '/^$/d'; } | head -5)
  if [[ -n "$rhits" ]]; then rcell="❌"; status="RED"; findings+=("**$name** risk grep: $(tr '\n' ' ' <<<"$rhits")")
  elif (( ats_status != 0 || catch_status != 0 )); then rcell="❓"; [[ $status == GREEN ]] && status="YELLOW"; findings+=("**$name** risk grep unverified: helper exited (ats=$ats_status, catch=$catch_status)")
  else rcell="✅"; fi
  # --- DI posture: .shared / static var outside adapters and apps
  local dhits; dhits=$(grep -nE '\.shared\b|static var ' -r "$dir" --include='*.swift' 2>/dev/null | head -5)
  if [[ "$layer" == "adapter" || "$dir" == Apps/* ]]; then dicell="—"  # adapters wrap Apple singletons; apps are composition roots
  elif [[ -n "$dhits" ]]; then dicell="❌"; status="RED"; findings+=("**$name** DI: $(tr '\n' ' ' <<<"$dhits")")
  else dicell="✅"; fi
  case "$status" in RED) red=$((red+1));; YELLOW) yellow=$((yellow+1));; *) green=$((green+1));; esac
  rows+=("| $name | $layer | $bcell | $tcell | $lcell | $dcell | $bocell | $szcell | $rcell | $dicell | $status |")
}

# Package rows come from the declared targets (any path), so a target outside Sources/ is not silently omitted;
# Sources/* directories that are not targets get a row too (rendered unverified) so stray code is visible.
seen_dirs=""
while IFS='|' read -r tname tpath ttype; do
  [[ -z "$tname" || "$ttype" == "test" ]] && continue
  [[ -z "$tpath" ]] && tpath="Sources/$tname"
  check_component "$tname" "${tpath%/}"; seen_dirs+="${tpath%/}"$'\n'
done <<<"$pkg_target_rows"
for dir in Sources/*/; do dir=${dir%/}; grep -qx -- "$dir" <<<"$seen_dirs" || check_component "$(basename "$dir")" "$dir"; done
for dir in Apps/*/; do name=$(basename "$dir"); check_component "$name" "Apps/$name"; done

# Scheme-level test failures (app built, package suites failed on the simulator) are reported on the lane, not a row.
lane_test_failures=0; for i in "${!sim_results[@]}"; do [[ "${sim_results[$i]}" -eq 1 ]] && ! sim_build_failed "$(raw_log "${sim_schemes[$i]}")" && lane_test_failures=$((lane_test_failures+1)); done
sim_note=""; for i in "${!sim_schemes[@]}"; do case "${sim_results[$i]}" in 0) sim_note+="${sim_schemes[$i]} ✅ ";; 1) sim_note+="${sim_schemes[$i]} ❌ ";; 3) sim_note+="${sim_schemes[$i]} ❓(env) ";; *) sim_note+="${sim_schemes[$i]} ❓ ";; esac; done
[[ $NO_SIM -eq 1 ]] && sim_note="⏭ skipped (--no-sim): app rows unverified"
periphery_note=$([[ $periphery_status -eq 0 ]] && echo "✅${periphery_config_warning:+ (⚠️ $periphery_config_warning)}" || echo "❓ periphery exited $periphery_status (dead-code column unverified)")
bounds_note=$( (( bounds_checker_ok == 0 )) && echo "❓ checker did not complete" || mark $bounds_all )

cat <<MD
# Component health — mickdarling/holler — $date_str

Commit: \`$commit\`  Tooling: $tooling
Package build: $( (( build_all == 0 )) && echo "✅" || { grep -q "command not found" "$LOG/build.log" && echo "❓ (toolchain missing)" || echo "❌"; } )  Periphery: $periphery_note  Boundaries script: $bounds_note  Simulator lane: $sim_note
Legend: ✅ passed · ❌ failed · ⚠️ warning · ⏭ skipped · — not applicable · ❓ not run / tool or environment failed (unverified)

| Component | Layer | Build | Tests | Lint | Dead code | Boundaries | Size | Risk grep | DI | Status |
|---|---|---|---|---|---|---|---|---|---|---|
$(printf '%s\n' "${rows[@]}")

## Findings
$( ((${#findings[@]})) && printf -- '- %s\n' "${findings[@]}" | awk '!seen[$0]++' || echo "none" )

## Totals
GREEN $green · YELLOW $yellow · RED $red$( (( lane_test_failures > 0 )) && echo " · simulator lane test failures: $lane_test_failures (see Findings)" )
MD
