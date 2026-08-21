#!/usr/bin/env bash
# Prints an xcodebuild -destination for a platform, resolving a concrete simulator UDID so device-name/runtime
# ambiguity on CI images (same name under several runtimes) cannot break the lane.
# Usage: scripts/resolve-destination.sh <iOS|watchOS|macOS> [name-prefix]
set -euo pipefail
platform="$1"; prefix="${2:-}"
if [[ "$platform" == "macOS" ]]; then echo "platform=macOS"; exit 0; fi
python3 - "$platform" "$prefix" <<'PY'
import json, re, subprocess, sys
platform, prefix = sys.argv[1], sys.argv[2]
raw = subprocess.run(["xcrun", "simctl", "list", "devices", "available", "-j"], check=True, capture_output=True, text=True).stdout
data = json.loads(raw)["devices"]
best = None  # (runtime version tuple, name, udid)
for runtime, devices in data.items():
    if f".{platform}-" not in runtime:
        continue
    ver = tuple(int(x) for x in re.findall(r"\d+", runtime.split(f"{platform}-", 1)[1]))
    for d in devices:
        if not d.get("isAvailable", False) or not d["name"].startswith(prefix):
            continue
        cand = (ver, d["name"], d["udid"])
        if best is None or cand[0] > best[0] or (cand[0] == best[0] and cand[1] > best[1]):
            best = cand
if best is None:
    sys.exit(f"no available {platform} simulator matching prefix '{prefix}'")
print(f"platform={platform} Simulator,id={best[2]}")
PY
