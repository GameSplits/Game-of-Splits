#!/usr/bin/env bash
# Chapter 0 end-to-end simulation on a LOCAL anvil fork of Robinhood Chain mainnet (real USDG, $wif, pools, hooks).
#   1. the real mainnet deploy: forge script DeployMainnet --broadcast (seed from QuoteAnchor)
#   1b. DeployFeeSplitter (BLK-5), Safe-owned from the constructor
#   2. the handover check: the deploy already gave all seven to the Safe (A1-14), so SafeAcceptVerify (read-only) must
#      pass right away. There is no accept batch (SafeAcceptBatch is obsolete and reverts).
#   3. test/sim/Fair0Sim.fork.t.sol plays 2-4 Nov (timeline A1) on that node and checks every USDG and $wif
# Live mainnet signs with a Foundry keystore (--account <name> --sender <addr>). This rehearsal does not:
# anvil --auto-impersonate stands in for the deployer and the Safe. Runs in a temporary copy of the repo.
# Default Safe: the real pinned SafeL2 and its real owners. FORK_SAFE=1 pins a throwaway fork Safe instead.
#   bash script/e2e/fair0_sim.sh            (FOUNDRY_BIN=/dir to pick a forge version)
# Needs forge 1.5.x for step 3: forge 1.8.x emulates Arbitrum's ArbSys natively on Robinhood forks (frozen block
# number, can't be stubbed), so the one-play-per-L2-block rule would refuse every play after the first. Steps 1-2
# (deploy and Verify) work on either version; script/e2e/accept_flow.sh is the 1.8.x-compatible rehearsal.
set -euo pipefail
BIN=${FOUNDRY_BIN:-$(dirname "$(command -v forge || echo /nonexistent/forge)")}
[ -x "$BIN/forge" ] || { echo "forge not found: put Foundry on PATH or set FOUNDRY_BIN"; exit 1; }
F=$BIN; PORT=${PORT:-8551}; L=http://127.0.0.1:$PORT
SRC=$(cd "$(dirname "$0")/../.." && pwd); E2E=$SRC/script/e2e
WORK=$(mktemp -d); cp -r "$SRC" "$WORK/c"; cd "$WORK/c"; rm -rf broadcast deployments/*.json
"$F/anvil" --fork-url https://rpc.mainnet.chain.robinhood.com --auto-impersonate --port $PORT --silent & APID=$!
trap 'kill $APID 2>/dev/null; rm -rf "$WORK"' EXIT
for i in $(seq 1 90); do "$F/cast" client --rpc-url $L 2>/dev/null | grep -qi anvil && break; sleep 1; done
"$F/cast" client --rpc-url $L 2>/dev/null | grep -qi anvil || { echo "no anvil at $L (refusing to run against anything else)"; exit 1; }
[ "$("$F/cast" chain-id --rpc-url $L)" = 4663 ] || { echo "fork is not chain 4663"; exit 1; }
. "$E2E/fork_safe.sh"  # the Safe (real pinned one by default), its owners, a fresh deployer DEP
export KEEPER=0x000000000000000000000000000000000000bEEF TOLL_RECIPIENT=0x000000000000000000000000000000000000cafE
export ELIGIBLE_IDS=$("$F/cast" keccak red-cross-campaign),$("$F/cast" keccak blue-ocean-fund),$("$F/cast" keccak green-forest-trust)
export ELIGIBLE_COUNT=3
export ANCHOR_SEED=$("$F/forge" script script/Mainnet.s.sol:QuoteAnchor --rpc-url $L 2>&1 | grep "x1e18:" | awk '{print $NF}')
echo "== 1. deploy (seed $ANCHOR_SEED)"
"$F/forge" script script/Deploy.s.sol:DeployMainnet --rpc-url $L --broadcast --unlocked --slow --sender $DEP 2>&1 | grep -E "ONCHAIN EXECUTION|Error:" | sed -n 1,2p
[ -f deployments/4663.json ] || { echo "FAIL: deploy did not write deployments/4663.json"; exit 1; }
echo "== 1b. DeployFeeSplitter (BLK-5, Safe-owned, throwaway holders)"
. "$E2E/fee_splitter.sh"; deploy_fee_splitter $DEP
echo "== 2. handover check: SafeAcceptVerify right after the deploy (no accept batch since A1-14)"
"$F/cast" rpc evm_mine --rpc-url $L >/dev/null
V=$("$F/forge" script script/SafeAccept.s.sol:SafeAcceptVerify --rpc-url $L 2>&1 || true)
grep -E "^  verified|UNEXPECTED|Error: script failed" <<< "$V" | sed -n 1,2p
grep -q "^  verified: Safe owns all seven and FeeSplitter" <<< "$V" || { echo "FAIL: Verify did not pass, not playing Chapter 0"; exit 1; }
echo "== 3. Chapter 0"
SIM_RPC=$L SIM_DEPLOYMENT=deployments/4663.json "$F/forge" test --match-path test/sim/Fair0Sim.fork.t.sol -vv 2>&1 \
  | grep -vE "^Warning|^ *\||^ *-->|^$|Compiling|Solc|Compiler run"
