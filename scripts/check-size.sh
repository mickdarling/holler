#!/usr/bin/env bash
# Bite-size guard: no Swift source file over 200 lines (tests excluded from the file cap, capped at 300).
set -euo pipefail
cd "$(dirname "$0")/.."
fail=0
while IFS= read -r f; do
  n=$(wc -l < "$f")
  cap=200; [[ "$f" == Tests/* ]] && cap=300
  if (( n > cap )); then echo "$f: $n lines (> $cap)"; fail=1; fi
done < <(find Sources Tests Apps -name '*.swift' 2>/dev/null)
[[ $fail -eq 0 ]] && echo "size OK"
exit $fail
