#!/usr/bin/env bash
# End-to-end rehearsal of the mainnet deploy and the Safe handover checks on a LOCAL anvil fork of Robinhood Chain
# mainnet. The deploy hands all seven contracts to the Safe in the same broadcast (A1-14), so there is no accept batch.
# DeployFeeSplitter then deploys the Safe-owned FeeSplitter (BLK-5), SafeAcceptVerify (read-only) checks all of it and
# ResumeHandover recovers a broadcast that stopped partway.
# Live mainnet signs with a Foundry keystore: forge script ... --account <name> --sender <addr> (RUNBOOK_KEEPER.md).
# No keys here: anvil's --auto-impersonate stands in for the deployer and the Safe. Nothing touches the real chain.
# Default Safe: the real pinned SafeL2 and its real owners (read from the fork). FORK_SAFE=1 uses a throwaway fork Safe
# pinned into the temp copy instead. Runs in a temporary copy of this repo, so no deployments/4663.json is left behind.
#   bash script/e2e/accept_flow.sh            (uses forge/anvil/cast on PATH; FOUNDRY_BIN=/dir to pick a version)
# Each step prints PASS or FAIL. The script exits 1 if any step failed.
set -euo pipefail
BIN=${FOUNDRY_BIN:-$(dirname "$(command -v forge || echo /nonexistent/forge)")}
[ -x "$BIN/forge" ] || { echo "forge not found: put Foundry on PATH or set FOUNDRY_BIN"; exit 1; }
F=$BIN; PORT=${PORT:-8549}; L=http://127.0.0.1:$PORT
SRC=$(cd "$(dirname "$0")/../.." && pwd); E2E=$SRC/script/e2e
WORK=$(mktemp -d); cp -r "$SRC" "$WORK/c"; cd "$WORK/c"; rm -rf broadcast deployments/*.json
"$F/anvil" --fork-url https://rpc.mainnet.chain.robinhood.com --auto-impersonate --port $PORT --silent & APID=$!
trap 'kill $APID 2>/dev/null; rm -rf "$WORK"' EXIT
for i in $(seq 1 90); do "$F/cast" client --rpc-url $L 2>/dev/null | grep -qi anvil && break; sleep 1; done
"$F/cast" client --rpc-url $L 2>/dev/null | grep -qi anvil || { echo "no anvil at $L (refusing to run against anything else)"; exit 1; }
[ "$("$F/cast" chain-id --rpc-url $L)" = 4663 ] || { echo "fork is not chain 4663"; exit 1; }
"$F/forge" --version | head -1
. "$E2E/fork_safe.sh"
C=$OWNER_SAFE
export ELIGIBLE_IDS=$(python3 -c "import json;print(json.load(open('eligible/fair0.json'))['ELIGIBLE_IDS'])")  # mainnet needs the allowlist at deploy
export KEEPER=0x000000000000000000000000000000000000bEEF TOLL_RECIPIENT=0x000000000000000000000000000000000000cafE
SEED=$("$F/forge" script script/Mainnet.s.sol:QuoteAnchor --rpc-url $L 2>&1 | grep "x1e18:" | awk '{print $NF}')
[ -n "$SEED" ] || { echo "QuoteAnchor gave no seed"; exit 1; }
export ANCHOR_SEED=$SEED
FAILS=0
ok() { echo "  PASS $1"; }
bad() { echo "  FAIL $1"; FAILS=$((FAILS + 1)); }
# expect <regex> <label> <command...>: the command's output must match the regex
expect() { local re=$1 label=$2; shift 2; local out; out=$("$@" 2>&1 || true)
  if grep -qE "$re" <<< "$out"; then ok "$label"; else bad "$label"; grep -E "Error:|revert|verified" <<< "$out" | sed -n 1,3p | sed 's/^/    /'; fi; }
deploy() { "$F/forge" script script/Deploy.s.sol:DeployMainnet --rpc-url $L --sender ${SENDER:-$DEP} "$@"; }
SNAP0=$("$F/cast" rpc evm_snapshot --rpc-url $L | tr -d '"')

echo "== 0. deploy refuses an owner that isn't the pinned Safe (here Multicall3)"
expect "GOS_SAFE: not the pinned Safe" "Multicall3 refused" env -u ALMS_SAFE GOS_SAFE=0xcA11bde05977b3631167028862bE2a173976CA11 OWNER_SAFE=0xcA11bde05977b3631167028862bE2a173976CA11 bash -c "$(declare -f deploy); F=$F L=$L DEP=$DEP deploy"
echo "== 0b. deploy refuses the pinned Safe when SAFE_OWNERS is not its three owners (M10-b)"
expect "GOS_SAFE: owners are not the expected 3" "wrong owners refused" env SAFE_OWNERS=0x000000000000000000000000000000000000B001,0x000000000000000000000000000000000000B002,0x000000000000000000000000000000000000B003 bash -c "$(declare -f deploy); F=$F L=$L DEP=$DEP deploy"
echo "== 0d. deploy refuses a DIFFERENT real Safe with the same 3 owners, threshold 2 and nonce 1 (only the address pin stops it)"
TWIN=$(MAKE_SAFE_OWNERS=$SAFE_OWNERS bash "$E2E/make_safe.sh" $L 9)
echo "  twin $TWIN threshold $("$F/cast" call $TWIN 'getThreshold()(uint256)' --rpc-url $L) nonce $("$F/cast" call $TWIN 'nonce()(uint256)' --rpc-url $L)"
expect "GOS_SAFE: not the pinned Safe" "twin Safe refused" env -u ALMS_SAFE GOS_SAFE=$TWIN OWNER_SAFE=$TWIN bash -c "$(declare -f deploy); F=$F L=$L DEP=$DEP deploy"
echo "== 0c. deploy refuses a separate Alms Safe (the Alms Safe is the owner Safe)"
expect "ALMS_SAFE must be the owner Safe" "separate Alms Safe refused" env ALMS_SAFE=$TWIN bash -c "$(declare -f deploy); F=$F L=$L DEP=$DEP deploy"

echo "== deploy (DeployMainnet --broadcast --slow, ownership to the Safe in the same broadcast)"
deploy --broadcast --unlocked --slow 2>&1 | grep -E "ONCHAIN EXECUTION|Error:" | sed -n 1,2p
[ -f deployments/4663.json ] || { echo "deploy failed"; exit 1; }
NOW() { "$F/cast" block latest --rpc-url $L -f timestamp; }
J() { python3 -c "import json;print(json.load(open('deployments/4663.json'))['$1'])"; }
verify() { "$F/forge" script script/SafeAccept.s.sol:SafeAcceptVerify --rpc-url $L; }
VOK="^  verified: Safe owns all seven and FeeSplitter"
VBAD="Error: script failed|UNEXPECTED EVENT COUNT"
. "$E2E/fee_splitter.sh"
fsd() { "$F/forge" script script/DeployFeeSplitter.s.sol:DeployFeeSplitter --rpc-url $L --sender $DEP "$@"; }
"$F/cast" rpc evm_mine --rpc-url $L >/dev/null
echo "== 1a. mainnet Verify refuses a deploy with no FeeSplitter yet (BLK-5)"
expect "no feeSplitter in deployments/4663.json" "Verify needs the FeeSplitter" verify
echo "== 1b. DeployFeeSplitter refuses bad recipients, a split override and a wrong \$wif (DS-1, DS-2, DS-3)"
expect "PURSES must be the Safe on mainnet" "EOA PURSES refused" env PURSES=0x00000000000000000000000000000000Fee14663 bash -c "$(declare -f fsd); F=$F L=$L DEP=$DEP fsd"
expect "OPS must be the Safe on mainnet" "contract OPS refused" env OPS=0xcA11bde05977b3631167028862bE2a173976CA11 bash -c "$(declare -f fsd); F=$F L=$L DEP=$DEP fsd"
expect "REBATE must be the Safe on mainnet" "deployer as REBATE refused" env REBATE=$DEP bash -c "$(declare -f fsd); F=$F L=$L DEP=$DEP fsd"
expect "BURN_BUYER must be the Safe on mainnet" "EOA BURN_BUYER refused" env BURN_BUYER=0x00000000000000000000000000000000Fee34663 bash -c "$(declare -f fsd); F=$F L=$L DEP=$DEP fsd"
expect "FEE_SPLIT_BPS is refused on mainnet" "split override refused (even option b)" env FEE_SPLIT_BPS=0,5000,0,4000,1000 bash -c "$(declare -f fsd); F=$F L=$L DEP=$DEP fsd"
expect "SIMULATION COMPLETE|Script ran successfully" "legs set to the Safe accepted" env PURSES=$C REBATE=$C BURN_BUYER=$C OPS=$C bash -c "$(declare -f fsd); F=$F L=$L DEP=$DEP fsd"
cp deployments/4663.json "$WORK/pre_fs.json"
python3 -c "import json;d=json.load(open('deployments/4663.json'));d['wif']='0x00000000000000000000000000000000000Bad01';json.dump(d,open('deployments/4663.json','w'),indent=2)"
expect "not the mainnet .wif" "file with another wif refused" fsd
cp "$WORK/pre_fs.json" deployments/4663.json
expect "GOS_SAFE: not the pinned Safe" "FeeSplitter owner not the pinned Safe refused" env -u ALMS_SAFE GOS_SAFE=0xcA11bde05977b3631167028862bE2a173976CA11 OWNER_SAFE=0xcA11bde05977b3631167028862bE2a173976CA11 bash -c "$(declare -f fsd); F=$F L=$L DEP=$DEP fsd"
echo "== 1c. DeployFeeSplitter (Safe owner from the constructor, option b 0/5000/0/4000/1000, vault leg = Locksley Vault, other legs the Safe)"
deploy_fee_splitter $DEP
FS=$(J feeSplitter)
[ "${FS,,}" != "" ] && [ "$("$F/cast" code $FS --rpc-url $L)" != 0x ] && ok "feeSplitter $FS in the file" || bad "no feeSplitter in the file"
o=$("$F/cast" call $FS 'owner()(address)' --rpc-url $L); p=$("$F/cast" call $FS 'pendingOwner()(address)' --rpc-url $L)
[ "${o,,}" = "${C,,}" ] && [ "$p" = 0x0000000000000000000000000000000000000000 ] && ok "FeeSplitter owned by the Safe, nothing pending" || bad "FeeSplitter owner $o pending $p"
[ "$("$F/cast" call $FS 'TIMELOCK()(uint256)' --rpc-url $L | awk '{print $1}')" = 604800 ] && ok "FeeSplitter timelock 7 days" || bad "FeeSplitter timelock"
[ "$("$F/cast" call $FS 'vault()(address)' --rpc-url $L)" = "$("$F/cast" to-check-sum-address $(J locksleyVault))" ] && ok "vault leg is the Locksley Vault" || bad "vault leg"
for g in purses rebate burnBuyer ops; do
  [ "$("$F/cast" call $FS "$g()(address)" --rpc-url $L)" = "$("$F/cast" to-check-sum-address $C)" ] && ok "$g leg is the Safe" || bad "$g leg"; done
bps=$(for g in pursesBps vaultBps rebateBps burnBps opsBps; do "$F/cast" call $FS "$g()(uint16)" --rpc-url $L; done | tr '\n' ' ')
[ "$bps" = "0 5000 0 4000 1000 " ] && ok "split is option b ($bps)" || bad "split $bps"
echo "== 1d. DS-4 rerun: already deployed, nothing sent"
N0=$("$F/cast" nonce $DEP --rpc-url $L)
expect "already deployed" "second DeployFeeSplitter is a no-op" fsd --broadcast --unlocked --slow
[ "$("$F/cast" nonce $DEP --rpc-url $L)" = "$N0" ] && ok "no tx sent" || bad "rerun sent a tx"
echo "== 1e. DS-4 recovery: the create landed but the file lost feeSplitter, the rerun adopts it from the broadcast log"
cp deployments/4663.json "$WORK/with_fs.json"
python3 -c "import json;d=json.load(open('deployments/4663.json'));d.pop('feeSplitter');json.dump(d,open('deployments/4663.json','w'),indent=2)"
expect "adopting" "rerun adopts the landed FeeSplitter" fsd --broadcast --unlocked --slow
[ "$("$F/cast" nonce $DEP --rpc-url $L)" = "$N0" ] && ok "no tx sent" || bad "adopt sent a tx"
[ "$(J feeSplitter)" = "$FS" ] && ok "file has the same feeSplitter again" || bad "file feeSplitter $(J feeSplitter)"
echo "== 1f. DS-4: a file naming an address with no code is refused"
python3 -c "import json;d=json.load(open('deployments/4663.json'));d['feeSplitter']='0x00000000000000000000000000000000Fee74663';json.dump(d,open('deployments/4663.json','w'),indent=2)"
expect "has a feeSplitter that is not live or not the expected one" "codeless feeSplitter refused" fsd
cp "$WORK/with_fs.json" deployments/4663.json
snap() { SNAP=$("$F/cast" rpc evm_snapshot --rpc-url $L | tr -d '"'); }
reset() { [ "$("$F/cast" rpc evm_revert $SNAP --rpc-url $L)" = "true" ] || { echo "REVERT FAILED"; exit 1; }; snap; }
# dep: the deployer tries an owner call. It owns nothing now, so the call must revert (cast send exits non-zero).
dep() { local label=$1; shift
  if "$F/cast" send "$@" --from $DEP --unlocked --rpc-url $L >/dev/null 2>&1; then bad "$label went through"; else ok "$label reverted"; fi; }
safe() { "$F/cast" send "$@" --from $C --unlocked --rpc-url $L >/dev/null; }
CORE=$(J fairCore); PASS=$(J fairPass); ALMS=$(J almsVote); CFG=$(J gameConfig); RAT=$(J robinAmongThieves); RB=$(J rakeBuyer); VAULT=$(J locksleyVault)
"$F/cast" rpc evm_mine --rpc-url $L >/dev/null; snap
echo "startBlock in file: $(J startBlock)   L2 head: $("$F/cast" block-number --rpc-url $L)   (must be close)"
for a in $CFG $CORE $PASS $ALMS $VAULT $RAT $RB; do
  o=$("$F/cast" call $a 'owner()(address)' --rpc-url $L); p=$("$F/cast" call $a 'pendingOwner()(address)' --rpc-url $L)
  [ "${o,,}" = "${C,,}" ] && [ "$p" = 0x0000000000000000000000000000000000000000 ] && ok "$a owned by the Safe, nothing pending" || bad "$a owner $o pending $p"
done
echo "== 1. clean: SafeAcceptVerify right after the deploy";     expect "$VOK" "verified" verify
echo "== 2. the obsolete SafeAcceptBatch fails loudly";            expect "SafeAcceptBatch is obsolete" "batch refused" "$F/forge" script script/SafeAccept.s.sol:SafeAcceptBatch --rpc-url $L
echo "== 3. DEPLOYER env not the file's deployer: refused";        expect "$VBAD" "wrong DEPLOYER refused" env DEPLOYER=0x000000000000000000000000000000000000dEaD bash -c "$(declare -f verify); F=$F L=$L verify"
echo "== 4. the deployer has no power left: every owner call reverts, then Verify still passes"
dep "deployer postReceipt on AlmsVote" $ALMS "postReceipt(uint256,uint32,bytes32,string)" 0 1 0x$(printf '%064x' 1) fake
dep "deployer sweepExcess on FairPass" $PASS "sweepExcess(address,address)" 0x5173b8eA6923c2d40267890D45C46a3480954773 $DEP
dep "deployer queueSplit on GameConfig" $CFG "queueSplit((uint16,uint16,uint16,uint16,uint16,uint16,uint16))" "(6000,2000,1750,1750,2500,2500,2500)"
dep "deployer queueTokens on GameConfig" $CFG "queueTokens((address,uint256,address))" "(0x5173b8eA6923c2d40267890D45C46a3480954773,1,0x5173b8eA6923c2d40267890D45C46a3480954773)"
dep "deployer queueBonds on Robin Among Thieves" $RAT "queueBonds(bool,uint128)" true 1000000000000000000000
dep "deployer sweepExcess on FairCore" $CORE "sweepExcess(address,address)" 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 $DEP
dep "deployer pauseSales on FairCore" $CORE "pauseSales(bool)" true
dep "deployer transferOwnership on GameConfig" $CFG "transferOwnership(address)" $DEP
dep "deployer queue on FeeSplitter" $FS "queue(uint8,uint256,address)" 4 0 $DEP
dep "deployer queueRescue on FeeSplitter" $FS "queueRescue(address,address,address,uint256)" 0x5173b8eA6923c2d40267890D45C46a3480954773 $FS $DEP 1
"$F/cast" rpc evm_mine --rpc-url $L >/dev/null
expect "$VOK" "Verify still passes after the refused deployer calls" verify; reset
echo "== 5. the Safe acts before Verify (pauseSales on then off, state looks right, count is wrong): refused"
safe $CORE "pauseSales(bool)" true; safe $CORE "pauseSales(bool)" false
expect "$VBAD" "unplanned Safe action refused" verify; reset
echo "== 6. the Safe un-pauses Robin entries before Verify: refused"
safe $RAT "pauseEntries(bool)" false
expect "$VBAD" "Robin unpause refused" verify; reset
echo "== 6b. the Safe queues a FeeSplitter change before Verify: refused"
safe $FS 'queue(uint8,uint256,address)' 4 0 0x00000000000000000000000000000000Fee54663
expect "$VBAD" "FeeSplitter queue refused" verify; reset
echo "== 6c. Verify with a FEE_SPLIT_BPS override on mainnet: refused (DS-1)"
expect "FEE_SPLIT_BPS is refused on mainnet" "split override in Verify refused" env FEE_SPLIT_BPS=4000,2500,1500,1000,1000 bash -c "$(declare -f verify); F=$F L=$L verify"
echo "== 6d. Verify with a FeeSplitter whose legs are not the Safe (DS-3): refused"
cp deployments/4663.json "$WORK/good_fs.json"
FSX=0x00000000000000000000000000000000Fee64663; "$F/cast" rpc anvil_setBalance $FSX 0x56BC75E2D63100000 --rpc-url $L >/dev/null
BC=$(python3 -c "import json;print(json.load(open('out/FeeSplitter.sol/FeeSplitter.json'))['bytecode']['object'])")
mkfs() { local args; args=$("$F/cast" abi-encode "c(address,address,(address,address,address,address,address),(uint16,uint16,uint16,uint16,uint16),address,address)" \
  $(J wif) $C "($1,$VAULT,$2,$3,$4)" "(0,5000,0,4000,1000)" $CORE $RB)
  "$F/cast" send --from $FSX --unlocked --rpc-url $L --json --create "$BC${args#0x}" | python3 -c "import json,sys;print(json.load(sys.stdin)['contractAddress'])"; }
setfs() { python3 -c "import json;d=json.load(open('deployments/4663.json'));d['feeSplitter']='$1';json.dump(d,open('deployments/4663.json','w'),indent=2)"; }
X=$(mkfs 0x00000000000000000000000000000000Fee14663 $C $C $C); setfs $X
expect "feeSplitter purses or rebate leg" "EOA purses leg refused" verify
X=$(mkfs $C $C $C $DEP); setfs $X
expect "feeSplitter burn or ops leg" "deployer as ops leg refused" verify
X=$(mkfs $C $C 0x00000000000000000000000000000000Fee34663 $C); setfs $X
expect "feeSplitter burn or ops leg" "EOA burn leg refused" verify
cp "$WORK/good_fs.json" deployments/4663.json; reset
echo "== 7. a deploy made with another split (purse 5000, toll 5000; inside the caps): refused"
cp deployments/4663.json "$WORK/good.json"
DEP_OS=0x00000000000000000000000000000000De934663; "$F/cast" rpc anvil_setBalance $DEP_OS 0x56BC75E2D63100000 --rpc-url $L >/dev/null
"$F/forge" script script/e2e/OtherSplitDeploy.s.sol:DeployMainnetOtherSplit --rpc-url $L --broadcast --unlocked --slow --sender $DEP_OS 2>&1 | grep -E "ONCHAIN EXECUTION|Error:" | sed -n 1,2p
deploy_fee_splitter $DEP_OS
expect "$VBAD" "other split refused" env DEPLOYER=$DEP_OS bash -c "$(declare -f verify); F=$F L=$L verify"
cp "$WORK/good.json" deployments/4663.json; reset
echo "== 8. ResumeHandover on a complete deploy is a clean no-op"
export GAME_CONFIG=$CFG FAIR_PASS=$PASS FAIR_CORE=$CORE ALMS_VOTE=$ALMS LOCKSLEY_VAULT=$VAULT ROBIN=$RAT RAKE_BUYER=$RB
N0=$("$F/cast" nonce $DEP --rpc-url $L)
expect "ONCHAIN EXECUTION COMPLETE|SIMULATION COMPLETE|No transactions to broadcast|Script ran successfully" "ResumeHandover exit 0" "$F/forge" script script/Deploy.s.sol:ResumeHandover --rpc-url $L --broadcast --unlocked --slow --sender $DEP
[ "$("$F/cast" nonce $DEP --rpc-url $L)" = "$N0" ] && ok "no tx sent (deployer nonce still $N0)" || bad "ResumeHandover sent a tx on a complete deploy"
"$F/cast" rpc evm_mine --rpc-url $L >/dev/null
expect "$VOK" "Verify still passes after the no-op" verify
unset GAME_CONFIG FAIR_PASS FAIR_CORE ALMS_VOTE LOCKSLEY_VAULT ROBIN RAKE_BUYER

echo "== 9. stop drill: a fresh deployer's broadcast killed partway, ResumeHandover hands the rest to the Safe"
[ "$("$F/cast" rpc evm_revert $SNAP0 --rpc-url $L)" = "true" ] || { echo "REVERT FAILED"; exit 1; }
rm -rf broadcast deployments/4663.json
DEP2=0x00000000000000000000000000000000De944663; "$F/cast" rpc anvil_setBalance $DEP2 0x56BC75E2D63100000 --rpc-url $L >/dev/null
"$F/cast" rpc evm_setAutomine false --rpc-url $L >/dev/null; "$F/cast" rpc evm_setIntervalMining 1 --rpc-url $L >/dev/null
SENDER=$DEP2 deploy --broadcast --unlocked --slow > "$WORK/stopped.log" 2>&1 & FPID=$!
STOP_AT=${STOP_AT:-12}
for i in $(seq 1 600); do n=$("$F/cast" nonce $DEP2 --rpc-url $L); [ "$n" -ge "$STOP_AT" ] && break; kill -0 $FPID 2>/dev/null || break; sleep 0.5; done
kill $FPID 2>/dev/null || true; wait $FPID 2>/dev/null || true
"$F/cast" rpc evm_mine --rpc-url $L >/dev/null; sleep 2
"$F/cast" rpc evm_setIntervalMining 0 --rpc-url $L >/dev/null; "$F/cast" rpc evm_setAutomine true --rpc-url $L >/dev/null
echo "  killed the broadcast at deployer nonce $("$F/cast" nonce $DEP2 --rpc-url $L)"
eval "$(python3 - <<'PY'
import json
names={"GameConfig":"GAME_CONFIG","FairPass":"FAIR_PASS","FairCore":"FAIR_CORE","AlmsVote":"ALMS_VOTE","LocksleyVault":"LOCKSLEY_VAULT","RobinAmongThieves":"ROBIN","RakeBuyer":"RAKE_BUYER"}
try: j=json.load(open("broadcast/Deploy.s.sol/4663/run-latest.json"))
except Exception: j={"transactions":[]}
for t in j["transactions"]:
    if t.get("transactionType")=="CREATE" and t.get("contractName") in names:
        print(f'export {names[t["contractName"]]}={t["contractAddress"]}')
PY
)"
LISTED=""
for v in GAME_CONFIG FAIR_PASS FAIR_CORE ALMS_VOTE LOCKSLEY_VAULT ROBIN RAKE_BUYER; do
  a=${!v:-}; [ -z "$a" ] && continue
  if [ "$("$F/cast" code $a --rpc-url $L)" = "0x" ]; then unset $v; continue; fi
  LISTED="$LISTED $v"; echo "  $v $a owner $("$F/cast" call $a 'owner()(address)' --rpc-url $L)"
done
[ -n "$LISTED" ] || bad "nothing deployed before the kill (raise STOP_AT)"
expect "ONCHAIN EXECUTION COMPLETE|Script ran successfully" "ResumeHandover after the stop" "$F/forge" script script/Deploy.s.sol:ResumeHandover --rpc-url $L --broadcast --unlocked --slow --sender $DEP2
for v in $LISTED; do o=$("$F/cast" call ${!v} 'owner()(address)' --rpc-url $L); p=$("$F/cast" call ${!v} 'pendingOwner()(address)' --rpc-url $L)
  { [ "${o,,}" = "${C,,}" ] || [ "${p,,}" = "${C,,}" ]; } && ok "$v now with the Safe (owner $o pending $p)" || bad "$v owner $o pending $p"; done
N1=$("$F/cast" nonce $DEP2 --rpc-url $L)
expect "ONCHAIN EXECUTION COMPLETE|SIMULATION COMPLETE|No transactions to broadcast|Script ran successfully" "second ResumeHandover exit 0" "$F/forge" script script/Deploy.s.sol:ResumeHandover --rpc-url $L --broadcast --unlocked --slow --sender $DEP2
[ "$("$F/cast" nonce $DEP2 --rpc-url $L)" = "$N1" ] && ok "second ResumeHandover sent nothing" || bad "second ResumeHandover sent a tx"
echo
[ $FAILS = 0 ] && echo "ACCEPT FLOW: ALL PASS" || { echo "ACCEPT FLOW: $FAILS FAILED"; exit 1; }
