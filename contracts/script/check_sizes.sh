#!/usr/bin/env bash
# EIP-170 guard: fail if any deployable contract under src/ has runtime bytecode over 24,576 bytes.
# Tests, mocks and scripts are excluded (their sources are not under src/). Reads the forge artifacts in out/.
#   bash script/check_sizes.sh          (builds first unless NO_BUILD=1)
set -euo pipefail
cd "$(dirname "$0")/.."
LIMIT=${SIZE_LIMIT:-24576}
[ "${NO_BUILD:-}" = 1 ] || forge build >/dev/null
python3 - "$LIMIT" <<'PY'
import json, pathlib, sys
limit = int(sys.argv[1])
rows = []
for f in pathlib.Path("out").rglob("*.json"):
    if f.parent.name.startswith("build-info"):
        continue
    try:
        a = json.loads(f.read_text())
    except Exception:
        continue
    target = (a.get("metadata") or {}).get("settings", {}).get("compilationTarget") or {}
    for src, name in target.items():
        if not src.startswith("src/"):
            continue
        code = ((a.get("deployedBytecode") or {}).get("object") or "").removeprefix("0x")
        size = len(code) // 2
        if size:
            rows.append((size, name, src))
rows = sorted(set(rows), reverse=True)
if not rows:
    sys.exit("no src artifacts found in out/ (build first)")
bad = [r for r in rows if r[0] > limit]
for size, name, src in rows[:10]:
    print(f"{size:>7}  {limit - size:>7}  {name} ({src})")
if bad:
    for size, name, src in bad:
        print(f"OVER EIP-170: {name} is {size} bytes (limit {limit})")
    sys.exit(1)
print(f"ok: {len(rows)} src contracts, all at or under {limit} bytes")
PY
