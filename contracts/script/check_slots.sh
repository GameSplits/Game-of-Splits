#!/usr/bin/env bash
# L-2: the watcher's fill check zeroes FairCore's lastSwapAt / swappedOnDay slots in a stateOverride. Fail if the
# slots in keeper/src/abi.mjs and watcher/lib/abi.mjs drift from forge's storage layout, or the two files differ.
set -euo pipefail
cd "$(dirname "$0")/.."
cmp -s ../keeper/src/abi.mjs ../watcher/lib/abi.mjs || { echo "keeper/src/abi.mjs and watcher/lib/abi.mjs differ"; exit 1; }
LAYOUT=$(forge inspect FairCore storageLayout --json)
for name in lastSwapAt swappedOnDay; do
  want=$(printf '%s' "$LAYOUT" | python3 -c "import json,sys;print(next(s['slot'] for s in json.load(sys.stdin)['storage'] if s['label']=='$name'))")
  have=$(grep -oE "$name: [0-9]+n" ../watcher/lib/abi.mjs | grep -oE '[0-9]+')
  [ "$want" = "$have" ] || { echo "FAIRCORE_SLOTS.$name is $have in abi.mjs, forge says $want"; exit 1; }
  echo "FairCore $name slot $want ok"
done
