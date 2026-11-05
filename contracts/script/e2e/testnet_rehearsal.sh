#!/usr/bin/env bash
# Dry run of the TESTNET deploy + DeployFeeSplitter + SafeAcceptVerify on a LOCAL anvil fork of Robinhood Chain testnet (46630).
# Uses the real pinned testnet Safe and its real owners (read from the fork), the real keeper address, and the
# shipped Deploy.s.sol pin (no pin rewrite). anvil's --auto-impersonate stands in for the deployer keystore, so no
# key is used and nothing is sent to the real chain. Runs in a temp copy so no deployments/46630.json is left behind.
#   bash script/e2e/testnet_rehearsal.sh       (FOUNDRY_BIN=/dir to pick a Foundry; DEP=0x... to rehearse a given deployer)
set -euo pipefail
BIN=${FOUNDRY_BIN:-$(dirname "$(command -v forge || echo /nonexistent/forge)")}
[ -x "$BIN/forge" ] || { echo "forge not found: put Foundry on PATH or set FOUNDRY_BIN"; exit 1; }
F=$BIN; PORT=${PORT:-8551}; L=http://127.0.0.1:$PORT
SRC=$(cd "$(dirname "$0")/../.." && pwd); E2E=$SRC/script/e2e
WORK=$(mktemp -d); cp -r "$SRC" "$WORK/c"; cd "$WORK/c"; rm -rf broadcast deployments/*.json
"$F/anvil" --fork-url https://rpc.testnet.chain.robinhood.com --auto-impersonate --port $PORT --silent & APID=$!
trap 'kill $APID 2>/dev/null; rm -rf "$WORK"' EXIT
for i in $(seq 1 90); do "$F/cast" client --rpc-url $L 2>/dev/null | grep -qi anvil && break; sleep 1; done
"$F/cast" client --rpc-url $L 2>/dev/null | grep -qi anvil || { echo "no anvil at $L (refusing to run against anything else)"; exit 1; }
[ "$("$F/cast" chain-id --rpc-url $L)" = "46630" ] || { echo "fork is not chain 46630"; exit 1; }
SAFE=0xDF3d35A99af7A1A3fdE128b8FDFa0D60aE9A1F00
DEP=${DEP:-0x00000000000000000000000000000000De946630}  # stand-in for the gos-testnet keystore address
export TESTNET_OWNER=$SAFE OWNER_SAFE=$SAFE ALMS_SAFE=$SAFE TOLL_RECIPIENT=$SAFE
export KEEPER=0xf79640C55805A3dc50F4d07AaA8Dfb52bbAa35E1 DEPLOYER=$DEP
export SAFE_OWNERS=$("$F/cast" call $SAFE "getOwners()(address[])" --rpc-url $L | tr -d '[] ')
# Verify re-derives Chapter 0 from FAIR_START/FAIR_END, so set both explicitly (the deploy's defaults are clock-relative)
NOWTS=$("$F/cast" block latest -f timestamp --rpc-url $L)
export ELIGIBLE_IDS=${ELIGIBLE_IDS:-$(cast keccak charity-a),$(cast keccak charity-b)}
export FAIR_START=${FAIR_START:-$((NOWTS + 900))} FAIR_END=${FAIR_END:-$((NOWTS + 900 + 7 * 86400))}
export ANCHOR_SEED=781250000000000000000000000000000000  # TestRoute(781_250e12).RATE() * 1e18
echo "safe owners: $SAFE_OWNERS   threshold: $("$F/cast" call $SAFE 'getThreshold()(uint256)' --rpc-url $L)   nonce: $("$F/cast" call $SAFE 'nonce()(uint256)' --rpc-url $L)"
"$F/cast" rpc anvil_setBalance $DEP 0x2386F26FC10000 --rpc-url $L >/dev/null  # 0.01 ETH, like the real deployer
"$F/cast" rpc anvil_setBalance $SAFE 0x2386F26FC10000 --rpc-url $L >/dev/null
echo "== 1. deploy (DeployTestnet, ownership to the Safe in the same broadcast)"
"$F/forge" script script/Deploy.s.sol:DeployTestnet --rpc-url $L --broadcast --unlocked --sender $DEP --slow 2>&1 \
  | grep -E "ONCHAIN EXECUTION|wrote deployments|Error:|revert" | sed -n 1,4p
[ -f deployments/46630.json ] || { echo "deploy failed"; exit 1; }
J() { python3 -c "import json;print(json.load(open('deployments/46630.json'))['$1'])"; }
echo "== 1b. DeployFeeSplitter (testnet: every non-vault leg is the testnet Safe)"
export PURSES=$SAFE REBATE=$SAFE BURN_BUYER=$SAFE OPS=$SAFE
. "$E2E/fee_splitter.sh"
deploy_fee_splitter $DEP
echo "feeSplitter $(J feeSplitter) owner $("$F/cast" call $(J feeSplitter) 'owner()(address)' --rpc-url $L)"
echo "deployer gas spent so far: $("$F/cast" from-wei $((0x2386F26FC10000 - $("$F/cast" balance $DEP --rpc-url $L)))) ETH (the real deployer must hold more)"
verify() { "$F/forge" script script/SafeAccept.s.sol:SafeAcceptVerify --rpc-url $L 2>&1 | grep -E "^  verified|UNEXPECTED EVENT COUNT: |expected|Error: script failed|revert" | sed -n 1,3p || true; }
SNAP=$("$F/cast" rpc evm_snapshot --rpc-url $L | tr -d '"')
echo "startBlock in file: $(J startBlock)   L2 head: $("$F/cast" block-number --rpc-url $L)"
echo "== 2. SafeAcceptVerify right after the deploy: must print verified"
verify
for a in $(J gameConfig) $(J fairCore) $(J fairPass) $(J almsVote) $(J locksleyVault) $(J robinAmongThieves) $(J rakeBuyer) $(J feeSplitter); do
  echo "owner $("$F/cast" call $a 'owner()(address)' --rpc-url $L)"; done
echo "robin entriesPaused: $("$F/cast" call $(J robinAmongThieves) 'entriesPaused()(bool)' --rpc-url $L)   rakeBuyer forwardTo: $("$F/cast" call $(J rakeBuyer) 'forwardTo()(address)' --rpc-url $L)"
echo "== 3. the Safe un-pauses Robin entries before Verify: must be refused"
"$F/cast" send $(J robinAmongThieves) "pauseEntries(bool)" false --from $SAFE --unlocked --rpc-url $L >/dev/null
verify
"$F/cast" rpc evm_revert $SNAP --rpc-url $L >/dev/null
echo "== 4. the Safe toggles the pause (state looks right, count is wrong): must be refused"
"$F/cast" send $(J robinAmongThieves) "pauseEntries(bool)" false --from $SAFE --unlocked --rpc-url $L >/dev/null
"$F/cast" send $(J robinAmongThieves) "pauseEntries(bool)" true --from $SAFE --unlocked --rpc-url $L >/dev/null
verify
