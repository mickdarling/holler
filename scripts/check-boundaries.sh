#!/usr/bin/env bash
# Fails if any module imports something not in its allow-list in docs/module-graph.yml.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import re, sys, pathlib
graph = pathlib.Path("docs/module-graph.yml").read_text()
allow = {}
for m in re.finditer(r"^\s+([\w-]+):\s*\{\s*layer:\s*(\w+),\s*imports:\s*\[([^\]]*)\]", graph, re.M):
    name, layer, imports = m.group(1), m.group(2), m.group(3)
    allow[name] = {i.strip() for i in imports.split(",") if i.strip()}
roots = {"Sources": "Sources", "Tests": "Tests", "Apps": "Apps"}
failures = []
for root in roots.values():
    for src in pathlib.Path(root).rglob("*.swift"):
        module = src.relative_to(root).parts[0]
        key = module[:-5] if module.endswith("Tests") and module[:-5] in allow else module
        allowed = set(allow.get(key, set()))
        if module.endswith("Tests"):
            allowed |= {"Testing", "XCTest", "HollerCoreTestSupport", key}
        for line in src.read_text().splitlines():
            m = re.match(r"^\s*(?:@testable\s+)?(?:public\s+|internal\s+|private\s+)?import\s+(?:struct\s+|class\s+|enum\s+|func\s+)?([\w.]+)", line)
            if not m:
                continue
            imp = m.group(1).split(".")[0]
            if key in allow and imp not in allowed:
                failures.append(f"{src}: import {imp} not allowed for {key} (allowed: {sorted(allowed)})")
if failures:
    print("\n".join(failures)); sys.exit(1)
print(f"boundaries OK ({len(allow)} modules declared)")
PY
