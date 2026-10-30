#!/usr/bin/env bash
# End-to-end rehearsal of the mainnet deploy + Safe accept flow on a LOCAL anvil fork of Robinhood Chain mainnet.
# Live mainnet signs with a Foundry keystore: forge script ... --account <name> --sender <addr> (see RUNBOOK_KEEPER.md).
# No keys here: anvil's --auto-impersonate stands in for that deployer and the Safe. Nothing touches the real chain.
# Runs in a temporary copy of this repo, so it can never leave a real-looking deployments/4663.json behind.
#   bash script/e2e/accept_flow.sh            (uses forge/anvil/cast on PATH; FOUNDRY_BIN=/dir to pick a version)
set -euo pipefail
BIN=${FOUNDRY_BIN:-$(dirname "$(command -v forge || echo /nonexistent/forge)")}
[ -x "$BIN/forge" ] || { echo "forge not found: put Foundry on PATH or set FOUNDRY_BIN"; exit 1; }
F=$BIN; PORT=${PORT:-8549}; L=http://127.0.0.1:$PORT
SRC=$(cd "$(dirname "$0")/../.." && pwd)
WORK=$(mktemp -d); cp -r "$SRC" "$WORK/c"; cd "$WORK/c"; rm -rf broadcast out cache deployments/*.json
"$F/anvil" --fork-url https://rpc.mainnet.chain.robinhood.com --auto-impersonate --port $PORT --silent & APID=$!
trap 'kill $APID 2>/dev/null; rm -rf "$WORK"' EXIT
for i in $(seq 1 90); do "$F/cast" client --rpc-url $L 2>/dev/null | grep -qi anvil && break; sleep 1; done
"$F/cast" client --rpc-url $L 2>/dev/null | grep -qi anvil || { echo "no anvil at $L (refusing to run against anything else)"; exit 1; }
"$F/forge" --version | head -1
export C=$(bash "$SRC/script/e2e/make_safe.sh" $L 1) DEP=0x00000000000000000000000000000000De910000  # a real multisig SafeL2 (M10)
export DEPLOYER=$DEP  # SafeAcceptVerify: this impersonated EOA must match deployer in the deployment file
export SAFE_OWNERS=$(bash "$SRC/script/e2e/make_safe.sh" owners)  # its 3 owners, pinned by the deploy (M10-b)
export ELIGIBLE_IDS=$(python3 -c "import json;print(json.load(open('eligible/fair0.json'))['ELIGIBLE_IDS'])")  # mainnet needs the allowlist at deploy
export OWNER_SAFE=$C ALMS_SAFE=$C KEEPER=0x000000000000000000000000000000000000bEEF TOLL_RECIPIENT=0x000000000000000000000000000000000000cafE
PATH="$F:$PATH" bash "$SRC/script/e2e/pin_safe.sh" $C  # pin the throwaway fork Safe in this temp copy only
SEED=$("$F/forge" script script/Mainnet.s.sol:QuoteAnchor --rpc-url $L 2>&1 | grep "x1e18:" | awk '{print $NF}')
"$F/cast" rpc anvil_setBalance $DEP 0x56BC75E2D63100000 --rpc-url $L >/dev/null
"$F/cast" rpc anvil_setBalance $C 0x56BC75E2D63100000 --rpc-url $L >/dev/null
echo "== 0. deploy refuses an owner that isn't the pinned Safe (here Multicall3)"
env -u ALMS_SAFE OWNER_SAFE=0xcA11bde05977b3631167028862bE2a173976CA11 ANCHOR_SEED=$SEED $F/forge script script/Deploy.s.sol:DeployMainnet --rpc-url $L --sender $DEP 2>&1 | grep -oE "OWNER_SAFE: [a-zA-Z0-9/.: ]+" | head -1 || true
echo "== 0b. deploy refuses a real multisig SafeL2 whose owners aren't the pinned three (M10-b)"
ANCHOR_SEED=$SEED SAFE_OWNERS=0x000000000000000000000000000000000000B001,0x000000000000000000000000000000000000B002,0x000000000000000000000000000000000000B003 "$F/forge" script script/Deploy.s.sol:DeployMainnet --rpc-url $L --sender $DEP 2>&1 | grep -oE "OWNER_SAFE: [a-zA-Z0-9/.: ]+" | head -1 || true
echo "== 0d. deploy refuses a DIFFERENT real Safe with our 3 owners, threshold 2 and nonce 1 (only the address pin stops it)"
TWIN=$(bash "$SRC/script/e2e/make_safe.sh" $L 9)
env -u ALMS_SAFE OWNER_SAFE=$TWIN ANCHOR_SEED=$SEED $F/forge script script/Deploy.s.sol:DeployMainnet --rpc-url $L --sender $DEP 2>&1 | grep -oE "OWNER_SAFE: [a-zA-Z0-9/.: ]+" | head -1 || true
echo "== 0c. deploy refuses a separate Alms Safe (the Alms Safe is the owner Safe)"
ANCHOR_SEED=$SEED ALMS_SAFE=$TWIN "$F/forge" script script/Deploy.s.sol:DeployMainnet --rpc-url $L --sender $DEP 2>&1 | grep -oE "ALMS_SAFE must be the owner Safe" | head -1 || true
ANCHOR_SEED=$SEED "$F/forge" script script/Deploy.s.sol:DeployMainnet --rpc-url $L --broadcast --unlocked --sender $DEP 2>&1 | grep -E "ONCHAIN EXECUTION|Error" | head -2
NOW() { "$F/cast" block latest --rpc-url $L -f timestamp; }
J() { python3 -c "import json;print(json.load(open('deployments/4663.json'))['$1'])"; }
batch() { ANCHOR_SEED=$SEED ANCHOR_SEED_AT=${1:-$(NOW)} "$F/forge" script script/SafeAccept.s.sol:SafeAcceptBatch --rpc-url $L 2>&1 | grep -E "wrote deployments|UNEXPECTED EVENT COUNT: |Error: script failed" | head -2 || true; }
verify() { ANCHOR_SEED=$SEED "$F/forge" script script/SafeAccept.s.sol:SafeAcceptVerify --rpc-url $L 2>&1 | grep -E "^  verified|UNEXPECTED EVENT COUNT: |Error: script failed" | head -2 || true; }
execbatch() { python3 -c "import json;[print(t['to'],t['data']) for t in json.load(open('deployments/safe-accept-4663.json'))['transactions']]" | while read to data; do "$F/cast" send $to $data --from $C --unlocked --rpc-url $L >/dev/null; done; }
snap() { SNAP=$("$F/cast" rpc evm_snapshot --rpc-url $L | tr -d '"'); }
reset() { [ "$("$F/cast" rpc evm_revert $SNAP --rpc-url $L)" = "true" ] || { echo "REVERT FAILED"; exit 1; }; rm -f deployments/safe-accept-4663.json; snap; }
dep() { "$F/cast" send "$@" --from $DEP --unlocked --rpc-url $L >/dev/null; }
CORE=$(J fairCore); PASS=$(J fairPass); ALMS=$(J almsVote); CFG=$(J gameConfig); RAT=$(J robinAmongThieves); RB=$(J rakeBuyer); snap
echo "startBlock in file: $(J startBlock)   L2 head: $("$F/cast" block-number --rpc-url $L)   (must be close)"
echo "== 1. clean: batch builds";                         batch; reset
echo "== 2. seed 31 min old: refused";                     batch $(( $(NOW) - 1860 )); reset
echo "== 3. deployer posts a fake receipt: refused";       dep $ALMS "postReceipt(uint256,uint32,bytes32,string)" 0 1 0x$(printf '%064x' 1) fake; batch; reset
echo "== 4. deployer sweeps FairPass: refused";            dep $PASS "sweepExcess(address,address)" 0x5173b8eA6923c2d40267890D45C46a3480954773 $DEP; batch; reset
echo "== 4b. deployer queues a GameConfig split: refused";  dep $CFG "queueSplit((uint16,uint16,uint16,uint16,uint16,uint16,uint16))" "(6000,2000,1750,1750,2500,2500,2500)"; batch; reset
echo "== 4c. deployer queues GameConfig tokens: refused";   dep $CFG "queueTokens((address,uint256,address))" "(0x5173b8eA6923c2d40267890D45C46a3480954773,1,0x5173b8eA6923c2d40267890D45C46a3480954773)"; batch; reset
echo "== 4d. a deploy made with another split (purse 5000, toll 5000; inside the caps): refused"
cp deployments/4663.json "$WORK/good.json"
ANCHOR_SEED=$SEED "$F/forge" script script/e2e/OtherSplitDeploy.s.sol:DeployMainnetOtherSplit --rpc-url $L --broadcast --unlocked --sender $DEP 2>&1 | grep -E "ONCHAIN EXECUTION|Error" | head -2
batch; cp "$WORK/good.json" deployments/4663.json; reset
echo "== 4e. deployer queues bonds on Robin Among Thieves: refused"; dep $RAT "queueBonds(bool,uint128)" true 1000000000000000000000; batch; reset
echo "== 5. deployer sweeps FairCore: refused";            dep $CORE "sweepExcess(address,address)" 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 $DEP; batch; reset
echo "== 6. deployer acts after the build: verify fails";  batch; dep $CORE "pauseSales(bool)" true; dep $CORE "pauseSales(bool)" false; execbatch; verify; reset
echo "== 7. clean: batch, Safe executes, verify passes";   batch; execbatch; verify
python3 -c "import json;print('batch description:', json.load(open('deployments/safe-accept-4663.json'))['meta']['description'])"
for a in $CFG $CORE $PASS $ALMS $(J locksleyVault) $RAT $RB; do echo "owner $("$F/cast" call $a 'owner()(address)' --rpc-url $L)"; done
