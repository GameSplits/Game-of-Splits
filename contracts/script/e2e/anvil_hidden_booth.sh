#!/usr/bin/env bash
# Throwaway anvil (chain 46630, no keys). Proves SafeAccept's FairCore setup scan really calls eth_getLogs
# and walks its 500_000-block chunks. vm.recordLogs tests share the expected counts, not this path.
#   bash script/e2e/anvil_hidden_booth.sh
# A clean deploy prints SCAN PASSED. An extra BoothAdded reverts with expected 2 found 3.
set -euo pipefail
BIN=${FOUNDRY_BIN:-$(dirname "$(command -v forge || echo /nonexistent/forge)")}
[ -x "$BIN/forge" ] || { echo "forge not found: put Foundry on PATH or set FOUNDRY_BIN"; exit 1; }
F=$BIN
PORT=${PORT:-8547}
L=http://127.0.0.1:$PORT
cd "$(dirname "$0")/../.."
DEP=${DEP:-0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266}
"$F/anvil" --chain-id 46630 --auto-impersonate --port "$PORT" --silent &
APID=$!
trap 'kill $APID 2>/dev/null || true' EXIT
for i in $(seq 1 60); do "$F/cast" client --rpc-url "$L" 2>/dev/null | grep -qi anvil && break; sleep 1; done
"$F/cast" client --rpc-url "$L" 2>/dev/null | grep -qi anvil || { echo "no anvil at $L"; exit 1; }

deploy() {
  DEP="$DEP" "$F/forge" script script/e2e/AnvilHiddenBooth.s.sol:AnvilDeploy \
    --sig "run(bool)" "$1" --rpc-url "$L" --broadcast --unlocked --sender "$DEP" -vv
}

scan() {
  DEP="$DEP" "$F/forge" script script/e2e/AnvilHiddenBooth.s.sol:AnvilScan \
    --sig "run(address)" "$1" --rpc-url "$L" -vv
}

core_of() { echo "$1" | grep -oE 'CORE 0x[0-9a-fA-F]{40}' | awk '{print $2}' | tail -1; }

echo "== clean deploy, then mine past one log chunk so _count runs twice"
CLEAN=$(deploy false)
CORE=$(core_of "$CLEAN")
[ -n "$CORE" ] || { echo "no CORE in clean deploy"; echo "$CLEAN"; exit 1; }
# LOG_CHUNK is 500_000. One extra block puts the head in the second chunk. Events stay in the first.
"$F/cast" rpc anvil_mine 500001 --rpc-url "$L" >/dev/null
CLEAN_SCAN=$(scan "$CORE")
echo "$CLEAN_SCAN" | grep -q "SCAN PASSED" || { echo "$CLEAN_SCAN"; echo "clean scan did not pass"; exit 1; }
echo "$CLEAN_SCAN" | grep "SCAN PASSED"

echo "== extra booth: BoothAdded expected 2 found 3"
EXTRA=$(deploy true)
CORE2=$(core_of "$EXTRA")
[ -n "$CORE2" ] || { echo "no CORE in extra deploy"; echo "$EXTRA"; exit 1; }
set +e
EXTRA_SCAN=$(scan "$CORE2" 2>&1)
set -e
echo "$EXTRA_SCAN" | grep -q "BoothAdded" || { echo "$EXTRA_SCAN"; echo "missing BoothAdded"; exit 1; }
echo "$EXTRA_SCAN" | grep -q "expected 2 found 3" || { echo "$EXTRA_SCAN"; echo "missing expected 2 found 3"; exit 1; }
echo "extra booth refused"
echo "OK"
