#!/usr/bin/env bash
# Keeper + watcher end-to-end test on a LOCAL anvil fork of Robinhood Chain mainnet (real USDG, $wif, pools).
#   1. the real mainnet deploy + the Safe's accept batch (as contracts/script/e2e/fair0_sim.sh)
#   2. run.mjs: fills the ledgers, runs the real keeper (live, on the fork) and the real watcher, then plays a thief
#      and an owner on purpose and checks that every detector fires (and nothing else does)
# The keeper key is a fresh throwaway made here for this run. Nothing touches the real chain.
# Live mainnet deploy signs with a Foundry keystore (--account / --sender). This rehearsal impersonates the deployer.
#   bash e2e/keeper_watcher.sh        (FOUNDRY_BIN=/dir to pick Foundry; default: forge on PATH)
set -euo pipefail
BIN=${FOUNDRY_BIN:-$(dirname "$(command -v forge || echo /nonexistent/forge)")}
[ -x "$BIN/forge" ] || { echo "forge not found: put Foundry on PATH or set FOUNDRY_BIN"; exit 1; }
F=$BIN; PORT=${PORT:-8571}; L=http://127.0.0.1:$PORT
ROOT=$(cd "$(dirname "$0")/.." && pwd)
for d in keeper watcher e2e; do [ -d "$ROOT/$d/node_modules/viem" ] || (cd "$ROOT/$d" && npm install --ignore-scripts --no-audit --no-fund >/dev/null); done
WORK=$(mktemp -d); cp -r "$ROOT/contracts" "$WORK/c"; cd "$WORK/c"; rm -rf broadcast out cache deployments/*.json
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
export OWNER_SAFE=$(bash "$ROOT/contracts/script/e2e/make_safe.sh" $L 1)  # a real, used multisig SafeL2; also the Alms Safe
export ALMS_SAFE=$OWNER_SAFE SAFE_OWNERS=$(bash "$ROOT/contracts/script/e2e/make_safe.sh" owners)
PATH="$F:$PATH" bash "$ROOT/contracts/script/e2e/pin_safe.sh" $OWNER_SAFE  # pin the throwaway fork Safe in this temp copy only
export TOLL_RECIPIENT=0x000000000000000000000000000000000000cafE; DEP=0x00000000000000000000000000000000De910000
export DEPLOYER=$DEP  # SafeAcceptVerify: this impersonated EOA must match deployer in the deployment file
export ELIGIBLE_IDS=$("$F/cast" keccak red-cross-campaign),$("$F/cast" keccak blue-ocean-fund),$("$F/cast" keccak green-forest-trust) ELIGIBLE_COUNT=3
for a in $DEP $OWNER_SAFE $KEEPER; do "$F/cast" rpc anvil_setBalance $a 0x56BC75E2D63100000 --rpc-url $L >/dev/null; done
export ANCHOR_SEED=$("$F/forge" script script/Mainnet.s.sol:QuoteAnchor --rpc-url $L 2>&1 | grep "x1e18:" | awk '{print $NF}')
echo "== deploy (keeper $KEEPER, seed $ANCHOR_SEED)"
"$F/forge" script script/Deploy.s.sol:DeployMainnet --rpc-url $L --broadcast --unlocked --sender $DEP 2>&1 | grep -E "ONCHAIN EXECUTION|Error" | head -2
export ANCHOR_SEED_AT=$("$F/cast" block latest --rpc-url $L -f timestamp)
"$F/forge" script script/SafeAccept.s.sol:SafeAcceptBatch --rpc-url $L 2>&1 | grep -E "wrote deployments|UNEXPECTED|Error: script failed" | head -2
python3 -c "import json;[print(t['to'],t['data']) for t in json.load(open('deployments/safe-accept-4663.json'))['transactions']]" \
  | while read to data; do "$F/cast" send $to $data --from $OWNER_SAFE --unlocked --rpc-url $L >/dev/null; done
"$F/forge" script script/SafeAccept.s.sol:SafeAcceptVerify --rpc-url $L 2>&1 | grep -E "^  verified|UNEXPECTED|Error: script failed" | head -2
echo "== keeper + watcher"
E2E_PORT=${E2E_PORT:-8790} E2E_RPC=$L E2E_DEPLOYMENT=$WORK/c/deployments/4663.json E2E_WORK=$WORK node "$ROOT/e2e/run.mjs"
