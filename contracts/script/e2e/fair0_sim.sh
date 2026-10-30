#!/usr/bin/env bash
# Fair 0 end-to-end simulation on a LOCAL anvil fork of Robinhood Chain mainnet (real USDG, $wif, pools, hooks).
#   1. the real mainnet deploy: forge script DeployMainnet --broadcast (seed from QuoteAnchor)
#   2. the Safe's accept: SafeAcceptBatch -> the Safe executes the batch -> SafeAcceptVerify
#   3. test/sim/Fair0Sim.fork.t.sol plays 2-4 Nov (timeline A1) on that node and checks every USDG and $wif
# Live mainnet signs with a Foundry keystore (--account <name> --sender <addr>). This rehearsal does not:
# anvil --auto-impersonate stands in for the deployer and the Safe. Runs in a temporary copy of the repo.
#   bash script/e2e/fair0_sim.sh            (FOUNDRY_BIN=/dir to pick a forge version)
# Needs forge 1.5.x for step 3: forge 1.8.x emulates Arbitrum's ArbSys natively on Robinhood forks (frozen block
# number, can't be stubbed), so the one-play-per-L2-block rule would refuse every play after the first. Steps 1-2
# (deploy and Safe accept) work on either version; script/e2e/accept_flow.sh is the 1.8.x-compatible rehearsal.
set -euo pipefail
BIN=${FOUNDRY_BIN:-$(dirname "$(command -v forge || echo /nonexistent/forge)")}
[ -x "$BIN/forge" ] || { echo "forge not found: put Foundry on PATH or set FOUNDRY_BIN"; exit 1; }
F=$BIN; PORT=${PORT:-8551}; L=http://127.0.0.1:$PORT
SRC=$(cd "$(dirname "$0")/../.." && pwd)
WORK=$(mktemp -d); cp -r "$SRC" "$WORK/c"; cd "$WORK/c"; rm -rf broadcast out cache deployments/*.json
"$F/anvil" --fork-url https://rpc.mainnet.chain.robinhood.com --auto-impersonate --port $PORT --silent & APID=$!
trap 'kill $APID 2>/dev/null; rm -rf "$WORK"' EXIT
for i in $(seq 1 90); do "$F/cast" client --rpc-url $L 2>/dev/null | grep -qi anvil && break; sleep 1; done
"$F/cast" client --rpc-url $L 2>/dev/null | grep -qi anvil || { echo "no anvil at $L (refusing to run against anything else)"; exit 1; }
export OWNER_SAFE=$(bash "$SRC/script/e2e/make_safe.sh" $L 1)   # real multisig SafeL2 proxies (review M10)
export ALMS_SAFE=$OWNER_SAFE SAFE_OWNERS=$(bash "$SRC/script/e2e/make_safe.sh" owners)  # Alms Safe = owner Safe (decided 26 Oct)
PATH="$F:$PATH" bash "$SRC/script/e2e/pin_safe.sh" $OWNER_SAFE  # pin the throwaway fork Safe in this temp copy only
export KEEPER=0x000000000000000000000000000000000000bEEF TOLL_RECIPIENT=0x000000000000000000000000000000000000cafE
DEP=0x00000000000000000000000000000000De910000
export DEPLOYER=$DEP  # SafeAcceptVerify: this impersonated EOA must match deployer in the deployment file
export ELIGIBLE_IDS=$("$F/cast" keccak red-cross-campaign),$("$F/cast" keccak blue-ocean-fund),$("$F/cast" keccak green-forest-trust)
export ELIGIBLE_COUNT=3
for a in $DEP $OWNER_SAFE; do "$F/cast" rpc anvil_setBalance $a 0x56BC75E2D63100000 --rpc-url $L >/dev/null; done
export ANCHOR_SEED=$("$F/forge" script script/Mainnet.s.sol:QuoteAnchor --rpc-url $L 2>&1 | grep "x1e18:" | awk '{print $NF}')
echo "== 1. deploy (seed $ANCHOR_SEED)"
"$F/forge" script script/Deploy.s.sol:DeployMainnet --rpc-url $L --broadcast --unlocked --sender $DEP 2>&1 | grep -E "ONCHAIN EXECUTION|Error" | head -2
echo "== 2. Safe accept"
export ANCHOR_SEED_AT=$("$F/cast" block latest --rpc-url $L -f timestamp)
"$F/forge" script script/SafeAccept.s.sol:SafeAcceptBatch --rpc-url $L 2>&1 | grep -E "wrote deployments|UNEXPECTED|Error: script failed" | head -2
python3 -c "import json;[print(t['to'],t['data']) for t in json.load(open('deployments/safe-accept-4663.json'))['transactions']]" \
  | while read to data; do "$F/cast" send $to $data --from $OWNER_SAFE --unlocked --rpc-url $L >/dev/null; done
"$F/forge" script script/SafeAccept.s.sol:SafeAcceptVerify --rpc-url $L 2>&1 | grep -E "^  verified|UNEXPECTED|Error: script failed" | head -2
echo "== 3. Fair 0"
SIM_RPC=$L SIM_DEPLOYMENT=deployments/4663.json "$F/forge" test --match-path test/sim/Fair0Sim.fork.t.sol -vv 2>&1 \
  | grep -vE "^Warning|^ *\||^ *-->|^$|Compiling|Solc|Compiler run"
