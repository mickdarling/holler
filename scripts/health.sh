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
date_str=$(date +%F); commit=$(git rev-parse --short HEAD); tree=$(git rev-parse --short "HEAD^{tree}")  # tree survives rebase/squash
tooling="swift $(swift --version 2>&1 | head -1 | sed -E 's/.*Swift version ([0-9.]+).*/\1/'), swiftlint $(swiftlint version), periphery $(periphery version), xcodegen $(xcodegen --version | awk '{print $2}')"
rows=(); findings=(); red=0; yellow=0; green=0
mark() { [[ "$1" -eq 0 ]] && echo "✅" || echo "❌"; }

# Whole-package passes once; per-component attribution by path. Tool failures are recorded, not swallowed.
swift build --build-tests ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} >"$LOG/build.log" 2>&1; build_all=$?
# Declared SwiftPM targets: a Sources/<name> directory that is not a target is never compiled, so its row is unverified.
# One row per declared target: name, path, type, c99name, deps — fields separated by the ASCII unit separator (US, 0x1f)
# and dependencies by the record separator (RS, 0x1e), neither of which can collide with a target name or path (unlike
# `|` or `,`). path is relative to the package root; c99name is the Swift module identifier SwiftPM uses for the test
# filter (Foo+BarTests → Foo_BarTests); deps associate a test target with the component it tests.
US=$'\x1f'; RS=$'\x1e'
pkg_target_rows=$(swift package describe --type json 2>/dev/null | python3 -c 'import json,sys
for t in sorted(json.load(sys.stdin)["targets"], key=lambda t: t["name"]):
    deps = "\x1e".join(t.get("target_dependencies", []))
    print("\x1f".join([t["name"], t.get("path", ""), t.get("type", ""), t.get("c99name", t["name"]), deps]))' 2>/dev/null)
pkg_targets=$(cut -d"$US" -f1 <<<"$pkg_target_rows")
is_pkg_target() { grep -qx -- "$1" <<<"$pkg_targets"; }
target_row() { awk -F"$US" -v n="$1" '$1 == n { print; exit }' <<<"$pkg_target_rows"; }  # literal name match
# Is <dir> the declared source path of target <name>? (A stray Sources/<Name> next to a target declared at another path
# is not the target: nothing in it is compiled or scanned.)
is_pkg_target_at() { local row path; row=$(target_row "$1"); [[ -n "$row" ]] || return 1
  path=$(cut -d"$US" -f2 <<<"$row"); [[ "${path:-Sources/$1}" == "${2%/}" ]]; }
# Every test target of component <name>, one row per line (empty when it has none). Each must depend on <name> (a
# suite that cannot import the component does not test it): <name>Tests; any test target named <name>…
# (FooIntegrationTests, FooSpecs); and any test target not claimed by another dependency's name (IntegrationSpecs
# depending on Foo) — such a target counts for each of its unclaimed production dependencies. A name claim goes to the
# most specific dependency (FooBarTests depending on FooBar and Foo belongs to FooBar only). A *TestSupport library is
# attached only by name (<Name>Tests, <Name>Specs, …): every test target depends on it, so dependency alone would attach
# every suite.
test_target_rows_for() { awk -F"$US" -v n="$1" -v rs="$RS" '$3 == "test" {
    if (index(rs $5 rs, rs n rs) == 0) next
    if ($1 == n "Tests") { print; next }
    split($5, d, rs); best = ""
    for (i in d) if (d[i] != "" && index($1, d[i]) == 1 && length(d[i]) > length(best)) best = d[i]
    if (best == n) { print; next }                  # ours by the most specific name claim (FooTestSupportSpecs too)
    if (best == "" && n !~ /TestSupport$/) print    # unclaimed: each production dependency, never a support library
  }' <<<"$pkg_target_rows"; }
# Directories of those test targets (declared path, or Tests/<target>); Tests/<name>Tests when none is declared.
test_dirs_for() { local rows; rows=$(test_target_rows_for "$1"); [[ -n "$rows" ]] || { echo "Tests/$1Tests"; return; }
  awk -F"$US" '{ print ($2 != "" ? $2 : "Tests/" $1) }' <<<"$rows"; }
# ERE for `swift test --filter` of one test target: anchored on its c99name with every regex metacharacter escaped.
filter_for_test_row() { local c99; c99=$(cut -d"$US" -f4 <<<"$1")
  printf '^%s\\.' "$(printf '%s' "$c99" | sed 's/[][\\.^$*+?(){}|]/\\&/g')"; }
# Literal path-prefix match on a log (no regex: target paths may contain metacharacters).
has_line_under() { awk -v a="$1/" -v b="${2:-}/" 'index($0, a) == 1 || (b != "/" && index($0, b) == 1) { f = 1; exit } END { exit !f }' "$3"; }
lines_under() { awk -v a="$1/" -v b="${2:-}/" 'index($0, a) == 1 || (b != "/" && index($0, b) == 1)' "$3"; }
pkg_targets_known() { [[ -n "$pkg_targets" ]]; }  # empty = `swift package describe` failed: say so, do not blame Package.swift
periphery scan --quiet >"$LOG/periphery.log" 2>&1; periphery_status=$?
# Periphery coverage: it indexes every package target except `exclude_targets` (Periphery 3.x has no include list; an
# invalid key such as `targets` is ignored with a warning, surfaced in the header). An excluded component is unscanned.
periphery_excluded=$(python3 - <<'PYX'
import re, pathlib
text = pathlib.Path(".periphery.yml").read_text() if pathlib.Path(".periphery.yml").exists() else ""
def tokenize(s, sep=None, stop=None):
    # Walk s with YAML quoting rules: inside "…" a backslash escapes the next character; inside '…' a doubled ''
    # is a literal quote. Outside quotes: '#' starts a comment that runs to the end of that physical line, `sep`
    # splits, `stop` ends the walk. Returns (parts, index_of_stop or -1); parts keep their quotes for unquote().
    parts, cur, q, i = [], [], None, 0
    while i < len(s):
        ch = s[i]
        if q == '"':
            cur.append(ch)
            if ch == "\\" and i + 1 < len(s): cur.append(s[i + 1]); i += 2; continue
            if ch == '"': q = None
        elif q == "'":
            cur.append(ch)
            if ch == "'":
                if i + 1 < len(s) and s[i + 1] == "'": cur.append("'"); i += 2; continue
                q = None
        elif ch in "'\"": q = ch; cur.append(ch)
        elif ch == "#":
            nl = s.find("\n", i)
            if nl < 0: break
            i = nl; continue                        # the newline itself is kept as whitespace
        elif stop and ch == stop: parts.append("".join(cur)); return parts, i
        elif sep and ch == sep: parts.append("".join(cur)); cur = []
        else: cur.append(ch)
        i += 1
    parts.append("".join(cur)); return parts, -1
YAML_ESC = {"0": "\0", "a": "\a", "b": "\b", "t": "\t", "\t": "\t", "n": "\n", "v": "\v", "f": "\f", "r": "\r",
            "e": "\x1b", " ": " ", '"': '"', "/": "/", "\\": "\\", "N": "\u0085", "_": "\u00a0", "L": "\u2028", "P": "\u2029"}
def decode_double_quoted(inner):  # YAML 1.2 double-quoted escapes (\xXX, \uXXXX, \UXXXXXXXX included)
    out, i = [], 0
    while i < len(inner):
        ch = inner[i]
        if ch != "\\" or i + 1 >= len(inner): out.append(ch); i += 1; continue
        nxt = inner[i + 1]
        width = {"x": 2, "u": 4, "U": 8}.get(nxt)
        if width and i + 2 + width <= len(inner):
            try: out.append(chr(int(inner[i + 2:i + 2 + width], 16))); i += 2 + width; continue
            except ValueError: pass
        if nxt in YAML_ESC: out.append(YAML_ESC[nxt]); i += 2; continue
        out.append(ch); i += 1            # not an escape YAML defines: kept as written
    return "".join(out)
def unquote(x):  # a quoted scalar decoded with its escape semantics; a plain scalar as written
    x = x.strip()
    if len(x) >= 2 and x[0] == x[-1] == "'": return x[1:-1].replace("''", "'")
    if len(x) >= 2 and x[0] == x[-1] == '"': return decode_double_quoted(x[1:-1])
    return x
def uncomment(s): return tokenize(s)[0][0]
def split_items(s): return [unquote(x) for x in tokenize(s, sep=",")[0] if x.strip()]
names, lines = [], text.splitlines()
for i, line in enumerate(lines):
    m = re.match(r"^\s*(?:exclude_targets|\"exclude_targets\"|'exclude_targets')\s*:(.*)$", line)   # indented/quoted key
    if not m: continue
    rest = uncomment(m.group(1)).strip()
    if rest.startswith("["):                       # flow form: [A, "B#C", 'it''s'] — possibly spanning lines
        buf, j = rest[1:], i + 1
        parts, close = tokenize(buf, sep=",", stop="]")
        while close < 0 and j < len(lines):
            buf += "\n" + lines[j]; j += 1         # physical lines kept apart: a comment ends at its own line
            parts, close = tokenize(buf, sep=",", stop="]")
        names += [unquote(x) for x in parts if x.strip()]
    elif rest:                                     # a single scalar: exclude_targets: Foo
        names.append(unquote(rest))
    else:                                          # block form: "- A" / "- 'B'" lines that follow
        for follower in lines[i + 1:]:
            body = uncomment(follower)
            if not body.strip(): continue          # blank or comment-only lines are part of the sequence
            b = re.match(r"^\s*-\s*(.*)$", body)   # indented or indentless sequence entry
            if not b: break
            names.append(unquote(b.group(1)))
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
  elif [[ -n "${2:-}" ]] && awk -v p="${2%/}/" 'index($0, p) == 1 { f = 1; exit } END { exit !f }' <<<"$rel"; then echo app  # literal
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
    text = f.read_text()
    for m in re.finditer(r"catch\b[^{]*\{\s*\}", text):
        print(f"{f}:{text.count(chr(10), 0, m.start()) + 1}: empty catch block")
PYX
}

# A filesystem-safe form of a target name for evidence-log filenames (a name may contain `/` or other special characters).
safe_name() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }
# The component's layer from the module graph: the key is matched literally (a name may contain regex metacharacters).
layer_of() { awk -v n="$1" '/^ +[^ ]/ { l = $0; sub(/^ +/, "", l); if (index(l, n ":") == 1) { print; exit } }' docs/module-graph.yml | sed -E 's/.*layer: *([a-z]+).*/\1/'; }

check_component() { # name dir
  local name="$1" dir="$2" status="GREEN"
  local layer; layer=$(layer_of "$name"); layer=${layer:-unknown}
  local bcell tcell lcell dcell bocell szcell rcell dicell
  local tdirs; tdirs=$(test_dirs_for "$name")  # one per line
  local tdir; tdir=$(head -1 <<<"$tdirs")        # first (or the conventional default) — used for messages
  local test_rows; test_rows=$(test_target_rows_for "$name")
  # --- build / tests: package targets from SwiftPM; app targets (Apps/*) from the simulator lane. A declared package
  # target that lives under Apps/ is a package target, not an app.
  local is_app=0; [[ "$dir" == Apps/* ]] && ! is_pkg_target_at "$name" "$dir" && is_app=1
  if (( is_app )); then
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
  elif ! is_pkg_target_at "$name" "$dir"; then
    bcell="❓"; tcell="❓"; dcell="❓"; status="YELLOW"
    findings+=("**$name** unverified: $dir is not a declared target path in Package.swift (nothing here is compiled or tested)")
  else
    if has_error_under "$ROOT/$dir/" "$LOG/build.log"; then bcell="❌"; status="RED"
      findings+=("**$name** build errors: $(grep -F -- "$ROOT/$dir/" "$LOG/build.log" | grep "error:" | head -3 | strip_root | tr '\n' ' ')")
    elif (( build_all != 0 )); then bcell="❓"; status="YELLOW"; findings+=("**$name** build unverified: package build failed without a diagnostic attributable to this component")
    else bcell="✅"; fi
    if [[ -n "$test_rows" ]]; then
      local trow tname_ tdir_ tc
      tcell="✅"
      while IFS= read -r trow; do
        tname_=$(cut -d"$US" -f1 <<<"$trow"); tdir_=$(cut -d"$US" -f2 <<<"$trow"); tdir_=${tdir_:-Tests/$tname_}
        local tlog; tlog="$LOG/test-$(safe_name "$tname_").log"
        if has_error_under "$ROOT/$tdir_/" "$LOG/build.log"; then tc="❌"; status="RED"
          findings+=("**$name** test target $tname_ failed to compile: $(grep -F -- "$ROOT/$tdir_/" "$LOG/build.log" | grep "error:" | head -2 | strip_root | tr '\n' ' ')")
        elif (( build_all != 0 )); then tc="❓"; [[ $status == GREEN ]] && status="YELLOW"
        elif swift test --skip-build --filter "$(filter_for_test_row "$trow")" ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} >"$tlog" 2>&1; then
          # Exit 0 with zero executed tests (filter mismatch) is not a pass. Swift Testing: "Test run with N tests";
          # XCTest: "Executed N tests".
          if grep -qE "Test run with [1-9][0-9]* tests?|Executed [1-9][0-9]* tests?" "$tlog"; then tc="✅"
          else tc="❓"; [[ $status == GREEN ]] && status="YELLOW"; findings+=("**$name** tests unverified: $tname_ exited 0 but executed no tests"); fi
        else tc="❌"; status="RED"
          findings+=("**$name** tests failed ($tname_): $(grep -E '✘|error:' "$tlog" | head -3 | tr '\n' ' ')")
        fi
        # worst of all the component's test targets: ❌ > ❓ > ✅
        if [[ "$tc" == "❌" || "$tcell" == "❌" ]]; then tcell="❌"; elif [[ "$tc" == "❓" ]]; then tcell="❓"; fi
      done <<<"$test_rows"
    elif [[ "$name" == *TestSupport ]]; then tcell="—"
    else tcell="⚠️ none"; findings+=("**$name** has no test target ($tdir)"); [[ $status == GREEN ]] && status="YELLOW"
    fi
    if (( periphery_status != 0 )); then dcell="❓"; [[ $status == GREEN ]] && status="YELLOW"
    elif ! is_periphery_scanned "$name"; then dcell="❓"; [[ $status == GREEN ]] && status="YELLOW"
      findings+=("**$name** dead code unverified: target is in .periphery.yml exclude_targets")
    elif grep -qF -- "$ROOT/$dir/" "$LOG/periphery.log"; then dcell="⚠️"; [[ $status == GREEN ]] && status="YELLOW"
      findings+=("**$name** dead code: $(grep -F -- "$ROOT/$dir/" "$LOG/periphery.log" | head -3 | strip_root | tr '\n' ' ')")
    else dcell="✅"; fi
  fi
  # --- lint
  local lint_paths=("$dir") td; while IFS= read -r td; do [[ -d "$td" ]] && lint_paths+=("$td"); done <<<"$tdirs"
  local lint_log lint_status lint_diag_re=':[0-9]+:[0-9]+: (error|warning):'
  lint_log="$LOG/lint-$(safe_name "$name").log"
  swiftlint lint --strict --quiet "${lint_paths[@]}" >"$lint_log" 2>&1; lint_status=$?
  if (( lint_status == 0 )); then lcell="✅"
  elif grep -qE "$lint_diag_re" "$lint_log"; then lcell="❌"; status="RED"
    findings+=("**$name** lint: $(grep -E "$lint_diag_re" "$lint_log" | head -3 | strip_root | tr '\n' ' ')")
  else lcell="❓"; [[ $status == GREEN ]] && status="YELLOW"  # tool missing/crashed/config error: nothing was checked
    findings+=("**$name** lint unverified: swiftlint exited $lint_status without diagnostics: $(head -1 "$lint_log")")
  fi
  # --- boundaries: production dir and the component's own test dir
  if (( bounds_checker_ok == 0 )); then bocell="❓"; [[ $status == GREEN ]] && status="YELLOW"
  elif [[ "$dir" != "Sources/$name" && "$dir" != "Apps/$name" ]] || { [[ -d "$tdir" && "$tdir" != "Tests/${name}Tests" ]]; } || (( $(wc -l <<<"$tdirs") > 1 )); then
    # check-boundaries.sh keys modules by the first directory below Sources/, Tests/, Apps/ — only that layout is checked.
    bocell="❓"; [[ $status == GREEN ]] && status="YELLOW"
    findings+=("**$name** boundaries unverified: scripts/check-boundaries.sh only understands Sources/<Name>, Tests/<Name>Tests, Apps/<Name> (got $dir / $tdir)")
  elif [[ "$layer" == "unknown" ]]; then bocell="❓"; [[ $status == GREEN ]] && status="YELLOW"  # checker skips modules missing from the graph
    findings+=("**$name** boundaries unverified: not declared in docs/module-graph.yml (imports are not checked)")
  elif has_line_under "$dir" "$tdir" "$LOG/boundaries.log"; then bocell="❌"; status="RED"
    findings+=("**$name** boundaries: $(lines_under "$dir" "$tdir" "$LOG/boundaries.log" | head -3 | tr '\n' ' ')")
  else bocell="✅"; fi
  # --- size
  local sz=0 n
  if [[ ! -d "$dir" ]]; then szcell="❓"; [[ $status == GREEN ]] && status="YELLOW"; findings+=("**$name** size unverified: $dir is not a directory")
  else
    while IFS= read -r f; do n=$(wc -l < "$f" | tr -d ' '); (( n > 200 )) && { sz=1; findings+=("**$name** oversized: $f ($n lines > 200)"); }; done < <(find "$dir" -name '*.swift')
    while IFS= read -r td; do [[ -d "$td" ]] || continue
      while IFS= read -r f; do n=$(wc -l < "$f" | tr -d ' '); (( n > 300 )) && { sz=1; findings+=("**$name** oversized test: $f ($n lines > 300)"); }; done < <(find "$td" -name '*.swift')
    done <<<"$tdirs"
    szcell=$([[ $sz -eq 0 ]] && echo ✅ || echo ⚠️); (( sz )) && [[ $status == GREEN ]] && status="YELLOW"
  fi
  # --- risk grep (CodeQL/Sonar precursors) in Swift, plus ATS exemptions in plists/entitlements/project.yml
  local rhits ats_out ats_status catch_out catch_status
  ats_out=$(ats_enabled "$name" "$dir" 2>/dev/null); ats_status=$?
  catch_out=$(empty_catches "$dir" 2>/dev/null); catch_status=$?
  # The scan covers the declared production directory as a whole (a production target may live under any path).
  rhits=$( { grep -nE 'try!|as!|@unchecked Sendable|arc4random|print\(' -r "$dir" --include='*.swift' 2>/dev/null; printf '%s\n' "$ats_out" "$catch_out" | sed '/^$/d'; } | head -5)
  if [[ -n "$rhits" ]]; then rcell="❌"; status="RED"; findings+=("**$name** risk grep: $(tr '\n' ' ' <<<"$rhits")")
  elif (( ats_status != 0 || catch_status != 0 )); then rcell="❓"; [[ $status == GREEN ]] && status="YELLOW"; findings+=("**$name** risk grep unverified: helper exited (ats=$ats_status, catch=$catch_status)")
  else rcell="✅"; fi
  # --- DI posture: .shared / static var outside adapters and apps
  local dhits; dhits=$(grep -nE '\.shared\b|static var ' -r "$dir" --include='*.swift' 2>/dev/null | head -5)
  if [[ "$layer" == "adapter" || "$layer" == "app" ]] || (( is_app )); then dicell="—"  # adapters wrap Apple singletons; app-layer targets (Xcode apps and package targets in the app layer) are composition roots
  elif [[ -n "$dhits" ]]; then dicell="❌"; status="RED"; findings+=("**$name** DI: $(tr '\n' ' ' <<<"$dhits")")
  else dicell="✅"; fi
  case "$status" in RED) red=$((red+1));; YELLOW) yellow=$((yellow+1));; *) green=$((green+1));; esac
  local mdname=${name//|/\\|}  # a pipe in a target name must not split the table cell
  rows+=("| $mdname | $layer | $bcell | $tcell | $lcell | $dcell | $bocell | $szcell | $rcell | $dicell | $status |")
}

# Package rows come from the declared targets (any path), so a target outside Sources/ is not silently omitted;
# Sources/* directories that are not targets get a row too (rendered unverified) so stray code is visible.
seen_dirs=""
while IFS="$US" read -r tname tpath ttype _; do  # name, path, type, c99name, deps
  [[ -z "$tname" || "$ttype" == "test" ]] && continue
  [[ -z "$tpath" ]] && tpath="Sources/$tname"
  check_component "$tname" "${tpath%/}"; seen_dirs+="${tpath%/}"$'\n'
done <<<"$pkg_target_rows"
for dir in Sources/*/; do dir=${dir%/}; [[ -d "$dir" ]] || continue; grep -qx -- "$dir" <<<"$seen_dirs" || check_component "$(basename "$dir")" "$dir"; done  # -d: unmatched glob
for dir in Apps/*/; do [[ -d "$dir" ]] || continue; name=$(basename "$dir"); grep -qx -- "Apps/$name" <<<"$seen_dirs" || check_component "$name" "Apps/$name"; done  # declared targets under Apps/ already have a row

# Scheme-level test failures (app built, package suites failed on the simulator) are reported on the lane, not a row.
lane_test_failures=0; for i in "${!sim_results[@]}"; do [[ "${sim_results[$i]}" -eq 1 ]] && ! sim_build_failed "$(raw_log "${sim_schemes[$i]}")" && lane_test_failures=$((lane_test_failures+1)); done
sim_note=""; for i in "${!sim_schemes[@]}"; do case "${sim_results[$i]}" in 0) sim_note+="${sim_schemes[$i]} ✅ ";; 1) sim_note+="${sim_schemes[$i]} ❌ ";; 3) sim_note+="${sim_schemes[$i]} ❓(env) ";; *) sim_note+="${sim_schemes[$i]} ❓ ";; esac; done
[[ $NO_SIM -eq 1 ]] && sim_note="⏭ skipped (--no-sim): app rows unverified"
periphery_note=$([[ $periphery_status -eq 0 ]] && echo "✅${periphery_config_warning:+ (⚠️ $periphery_config_warning)}" || echo "❓ periphery exited $periphery_status (dead-code column unverified)")
bounds_note=$( (( bounds_checker_ok == 0 )) && echo "❓ checker did not complete" || mark $bounds_all )

cat <<MD
# Component health — mickdarling/holler — $date_str

Commit: \`$commit\` (tree \`$tree\` — reproducible against any commit with this tree)  Tooling: $tooling
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
