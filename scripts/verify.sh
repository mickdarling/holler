#!/usr/bin/env bash
# Single source of truth for verification. Local pre-push and GitHub Actions run this same script.
set -euo pipefail
cd "$(dirname "$0")/.."

cmd="${1:-all}"

# Local fallback: when xcode-select points at CommandLineTools, the Swift Testing frameworks live in Xcode.
# CI selects Xcode explicitly, so this block is a no-op there.
SWIFT_FLAGS=()
if ! xcodebuild -version >/dev/null 2>&1 && [[ -d /Applications/Xcode.app ]]; then
  XCODE_FW=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks
  SWIFT_FLAGS=(-Xswiftc "-F$XCODE_FW" -Xlinker "-F$XCODE_FW" -Xlinker -rpath -Xlinker "$XCODE_FW")
  export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
fi

tools() {
  echo "== tools"
  swift --version 2>&1 | head -1
  xcodebuild -version 2>/dev/null | tr '\n' ' ' || echo "xcodebuild: unavailable (set DEVELOPER_DIR)"
  echo
  swiftlint version | sed 's/^/swiftlint /'
  periphery version | sed 's/^/periphery /'
  xcodegen --version
}

build()      { echo "== build";      swift build ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"}; }
test_()      { echo "== test";       swift test --parallel ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"}; }
lint()       { echo "== lint";       swiftlint lint --strict --quiet; }
deadcode()   { echo "== deadcode";   periphery scan --quiet --skip-build --index-store-path .build/debug/index/store 2>/dev/null || periphery scan --quiet; }
boundaries() { echo "== boundaries"; scripts/check-boundaries.sh; }
size()       { echo "== size";       scripts/check-size.sh; }

sim() { # [scheme] — run one scheme only when given
  local only="${1:-}"
  echo "== simulators${only:+ ($only)}"
  if [[ -n "$only" ]] && ! awk -F'|' -v want="$only" '$1 == want { found = 1 } END { exit found ? 0 : 1 }' scripts/app-schemes.txt; then
    echo "unknown scheme '$only' (see scripts/app-schemes.txt)" >&2; return 2
  fi
  xcodegen generate --quiet
  while IFS='|' read -r scheme platform prefix; do
    [[ -z "$scheme" || "$scheme" == \#* ]] && continue
    [[ -n "$only" && "$scheme" != "$only" ]] && continue
    destination=$(scripts/resolve-destination.sh "$platform" "$prefix")
    echo "-- $scheme on $destination"
    # HOLLER_SIM_RAW_LOG: when set, the raw xcodebuild stream is also written there (scripts/health.sh classifies from it;
    # xcbeautify --quiet drops the build/test outcome markers).
    # xcodebuild prints the outcome markers (Testing cancelled…, ** TEST FAILED **) on stderr: merge it into the stream.
    xcodebuild test -project Holler.xcodeproj -scheme "$scheme" -destination "$destination" CODE_SIGNING_ALLOWED=NO 2>&1 \
      | { if [[ -n "${HOLLER_SIM_RAW_LOG:-}" ]]; then tee "$HOLLER_SIM_RAW_LOG"; else cat; fi; } \
      | (command -v xcbeautify >/dev/null && xcbeautify --quiet || cat)
  done < scripts/app-schemes.txt
}

all() { tools; build; test_; lint; deadcode; boundaries; size; echo "== verify: OK"; }

case "$cmd" in
  tools) tools ;;
  build) build ;;
  test) test_ ;;
  lint) lint ;;
  deadcode) deadcode ;;
  boundaries) boundaries ;;
  size) size ;;
  sim) sim "${2:-}" ;;
  all) all ;;
  *) echo "usage: scripts/verify.sh {tools|build|test|lint|deadcode|boundaries|size|sim [scheme]|all}"; exit 2 ;;
esac
