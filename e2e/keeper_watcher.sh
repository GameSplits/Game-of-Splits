#!/usr/bin/env bash
# Keeper + watcher end-to-end test on a LOCAL anvil fork of Robinhood Chain mainnet (real USDG, $wif, pools).
#   1. the real mainnet deploy (ownership to the Safe in the same broadcast, A1-14), then SafeAcceptVerify must pass
#      (as contracts/script/e2e/fair0_sim.sh; there is no accept batch any more), with DeployFeeSplitter in between
#   2. run.mjs: fills the ledgers, runs the real keeper (live, on the fork) and the real watcher, then plays a thief
#      and an owner on purpose and checks that every detector fires (and nothing else does)
# The keeper key is a fresh throwaway made here for this run. Nothing touches the real chain.
# Live mainnet deploy signs with a Foundry keystore (--account / --sender). This rehearsal impersonates the deployer.
# Default Safe: the real pinned SafeL2 and its real owners. FORK_SAFE=1 pins a throwaway fork Safe instead.
#   bash e2e/keeper_watcher.sh        (FOUNDRY_BIN=/dir to pick Foundry; default: forge on PATH)
set -euo pipefail
BIN=${FOUNDRY_BIN:-$(dirname "$(command -v forge || echo /nonexistent/forge)")}
[ -x "$BIN/forge" ] || { echo "forge not found: put Foundry on PATH or set FOUNDRY_BIN"; exit 1; }
F=$BIN; PORT=${PORT:-8571}; L=http://127.0.0.1:$PORT
ROOT=$(cd "$(dirname "$0")/.." && pwd)
for d in keeper watcher e2e; do [ -d "$ROOT/$d/node_modules/viem" ] || (cd "$ROOT/$d" && npm install --ignore-scripts --no-audit --no-fund >/dev/null); done
WORK=$(mktemp -d); cp -r "$ROOT/contracts" "$WORK/c"; cd "$WORK/c"; rm -rf broadcast deployments/*.json
"$F/anvil" --fork-url https://rpc.mainnet.chain.robinhood.com --auto-impersonate --port $PORT --silent & APID=$!
trap 'kill $APID 2>/dev/null; rm -rf "$WORK"' EXIT
for i in $(seq 1 90); do "$F/cast" client --rpc-url $L 2>/dev/null | grep -qi anvil && break; sleep 1; done
"$F/cast" client --rpc-url $L 2>/dev/null | grep -qi anvil || { echo "no anvil at $L (refusing to run against anything else)"; exit 1; }
# fresh throwaway key; cast's JSON shape differs by version ([{..}] in 1.5, {data:[{..}]} in 1.8): handle both (L9)
W=$("$F/cast" wallet new --json)
pick() { echo "$W" | python3 -c "import json,sys;j=json.load(sys.stdin);j=j['data'] if isinstance(j,dict) else j;print(j[0]['$1'])"; }
E2E_KEEPER_KEY=$(pick private_key); KEEPER=$(pick address)
[[ $E2E_KEEPER_KEY =~ ^0x[0-9a-fA-F]{64}$ && $KEEPER =~ ^0x[0-9a-fA-F]{40}$ ]] || { echo "couldn't make a throwaway key"; exit 1; }
export E2E_KEEPER_KEY KEEPER
[ "$("$F/cast" chain-id --rpc-url $L)" = 4663 ] || { echo "fork is not chain 4663"; exit 1; }
E2E=$ROOT/contracts/script/e2e; . "$E2E/fork_safe.sh"  # the Safe (real pinned one by default), its owners, a fresh deployer DEP
export TOLL_RECIPIENT=0x000000000000000000000000000000000000cafE
export ELIGIBLE_IDS=$("$F/cast" keccak red-cross-campaign),$("$F/cast" keccak blue-ocean-fund),$("$F/cast" keccak green-forest-trust) ELIGIBLE_COUNT=3
for a in $KEEPER; do "$F/cast" rpc anvil_setBalance $a 0x56BC75E2D63100000 --rpc-url $L >/dev/null; done
export ANCHOR_SEED=$("$F/forge" script script/Mainnet.s.sol:QuoteAnchor --rpc-url $L 2>&1 | grep "x1e18:" | awk '{print $NF}')
echo "== deploy (keeper $KEEPER, seed $ANCHOR_SEED)"
"$F/forge" script script/Deploy.s.sol:DeployMainnet --rpc-url $L --broadcast --unlocked --slow --sender $DEP 2>&1 | grep -E "ONCHAIN EXECUTION|Error:" | sed -n 1,2p
[ -f deployments/4663.json ] || { echo "FAIL: deploy did not write deployments/4663.json"; exit 1; }
. "$E2E/fee_splitter.sh"; deploy_fee_splitter $DEP  # BLK-5: FeeSplitter is live at launch
"$F/cast" rpc evm_mine --rpc-url $L >/dev/null
V=$("$F/forge" script script/SafeAccept.s.sol:SafeAcceptVerify --rpc-url $L 2>&1 || true)
grep -E "^  verified|UNEXPECTED|Error: script failed" <<< "$V" | sed -n 1,2p
grep -q "^  verified: Safe owns all seven and FeeSplitter" <<< "$V" || { echo "FAIL: Verify did not pass, not starting the keeper"; exit 1; }
echo "== keeper + watcher"
E2E_PORT=${E2E_PORT:-8795} E2E_RPC=$L E2E_DEPLOYMENT=$WORK/c/deployments/4663.json E2E_WORK=$WORK node "$ROOT/e2e/run.mjs"
