#!/usr/bin/env bash
# Throwaway anvil (chain 31337) e2e for keeper/src/ratrunner.mjs. Nothing touches testnet or mainnet.
# The keeper key is a fresh random key made here and never printed.
#   bash script/e2e/anvil_rat_runner.sh
set -euo pipefail
BIN=${FOUNDRY_BIN:-$(dirname "$(command -v forge || echo /nonexistent/forge)")}
[ -x "$BIN/forge" ] || { echo "forge not found"; exit 1; }
F=$BIN
PORT=${PORT:-8548}
HOOK_PORT=${HOOK_PORT:-8549}
L=http://127.0.0.1:$PORT
cd "$(dirname "$0")/../.."
KEEPER_DIR=$(cd ../keeper && pwd)
DEP=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
TMP=$(mktemp -d)
"$F/anvil" --chain-id 31337 --auto-impersonate --block-time 1 --port "$PORT" --silent &
APID=$!
HOOK_FILE="$TMP/hook.jsonl" node -e '
  const fs=require("fs");require("http").createServer((q,s)=>{let b="";q.on("data",d=>b+=d);q.on("end",()=>{fs.appendFileSync(process.env.HOOK_FILE,b+"\n");s.end("ok")})}).listen(+process.argv[1]);
' "$HOOK_PORT" &
HPID=$!
trap 'kill $APID $HPID 2>/dev/null || true; rm -rf "$TMP"' EXIT
for i in $(seq 1 60); do "$F/cast" client --rpc-url "$L" 2>/dev/null | grep -qi anvil && break; sleep 1; done

# fresh keeper key, kept in env only
KEEPER_KEY=0x$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
KEEPER=$("$F/cast" wallet address "$KEEPER_KEY")
"$F/cast" rpc anvil_setBalance "$KEEPER" 0x56BC75E2D63100000 --rpc-url "$L" >/dev/null
SEED_SECRET=0x$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
export KEEPER_KEY SEED_SECRET

NOW=$("$F/cast" block latest --field timestamp --rpc-url "$L")
GEN=$(( NOW / 1800 * 1800 ))
OUT=$(DEP=$DEP "$F/forge" script script/e2e/AnvilRat.s.sol:AnvilRatDeploy --sig "run(address,uint256)" "$KEEPER" "$GEN" \
  --rpc-url "$L" --broadcast --unlocked --sender "$DEP" -j 1 2>&1)
get() { echo "$OUT" | grep -oE "$1 0x[0-9a-fA-F]{40}" | awk '{print $2}' | tail -1; }
RAT=$(get RAT); USDG=$(get USDG); WIF=$(get WIF); PASS=$(get PASS); IMPL=$(get ARBSYS_IMPL)
[ -n "$RAT" ] || { echo "$OUT" | tail -20; echo "deploy failed"; exit 1; }
"$F/cast" rpc anvil_setCode 0x0000000000000000000000000000000000000064 "$("$F/cast" code "$IMPL" --rpc-url "$L")" --rpc-url "$L" >/dev/null
echo "deployed RAT $RAT, genesis $GEN"

run() {
  ( cd "$KEEPER_DIR" && RPC_URL=$L CHAIN_ID=31337 ALLOW_LOCAL_CHAIN=1 RAT=$RAT ONCE=1 NO_SENDLOG=1 \
    CHAIN_LEN=64 ROTATE_AT=63 ALERT_WEBHOOK_URL=http://127.0.0.1:$HOOK_PORT/hook env "$@" node src/ratrunner.mjs ) 2>&1 | tee -a "$TMP/run.log"
}
warp() { "$F/cast" rpc evm_setNextBlockTimestamp "$1" --rpc-url "$L" >/dev/null; "$F/cast" rpc evm_mine --rpc-url "$L" >/dev/null; }
rd() { "$F/cast" call "$RAT" "$@" --rpc-url "$L"; }
status() { rd "rounds(uint256)(bytes32,bytes32,uint32,uint32,uint32,uint32,uint32,uint32,uint32,uint32,uint8,bool,bool,uint64,uint256,uint128,uint128,bool)" "$1" | sed -n "${2}p"; }
fail() { echo "FAIL: $*"; exit 1; }
players() { local a=(); for i in "$@"; do a+=("$("$F/cast" wallet address --mnemonic 'test test test test test test test test test test test junk' --mnemonic-index "$i")"); done; local IFS=,; echo "[${a[*]}]"; }
enter() {
  "$F/forge" script script/e2e/AnvilRat.s.sol:AnvilRatEnter --sig "run(address,address,address,address,uint256,address[])" \
    "$RAT" "$USDG" "$WIF" "$PASS" "$1" "$2" --rpc-url "$L" --broadcast --unlocked --sender "$DEP" -j 1 >/dev/null 2>&1 || fail "enter round $1"
}

echo "== 1. dry run sends nothing"
run DRY_RUN=1 SEED_SECRET=$SEED_SECRET | grep -q "would call commitSeedChain" || fail "dry run plan"
[ "$(rd 'seedTip()(bytes32)')" = 0x0000000000000000000000000000000000000000000000000000000000000000 ] || fail "dry run sent"
[ "$(rd 'nextSeedTip()(bytes32)')" = 0x0000000000000000000000000000000000000000000000000000000000000000 ] || fail "dry run sent"

echo "== 2. live boot commits generation 0 two rounds ahead"
run DRY_RUN=0 >/dev/null
[ "$(rd 'nextSeedFrom()(uint64)')" = 3 ] || fail "nextSeedFrom"

echo "== 3. round 3: five outlaws enter; at close the runner reveals, locks and pairs in one tick"
warp $(( GEN + 2*1800 + 10 ))
enter 3 "$(players 1 2 3 4 5)"
[ "$(status 3 3)" = 5 ] || fail "entrants"
warp $(( GEN + 3*1800 ))
run DRY_RUN=0 | grep -E "sent (revealSeed|lockPairing|pair)" || true
[ "$(status 3 18)" = true ] || fail "not locked"
[ "$(status 3 11)" = 1 ] || fail "round 3 not Paired (status $(status 3 11))"
echo "round 3 Paired, matches $(status 3 7)"

echo "== 4. rotation: under ROTATE_AT links left, the next tick commits generation 1"
run DRY_RUN=0 >/dev/null
[ "$(rd 'nextSeedTip()(bytes32)')" != 0x0000000000000000000000000000000000000000000000000000000000000000 ] || fail "no rotation"
echo "nextSeedFrom $(rd 'nextSeedFrom()(uint64)')"

echo "== 5. retry path: an RPC that is down for every try alerts (webhook) and exits clean"
( cd "$KEEPER_DIR" && RPC_URL=http://127.0.0.1:1 CHAIN_ID=31337 ALLOW_LOCAL_CHAIN=1 RAT=$RAT ONCE=1 node src/ratrunner.mjs ) 2>&1 | grep -q "tick failed" || fail "rpc down not reported"

echo "== 6. keeper misses round 4's T+3m window: the runner alerts instead of sending"
warp $(( GEN + 3*1800 + 60 ))
enter 4 "$(players 6 7)"
warp $(( GEN + 4*1800 + 181 ))
run DRY_RUN=0 >/dev/null
grep -q "keeper reveal window" "$TMP/hook.jsonl" || fail "no lapsed alert on webhook"

echo "== 7. no secret in any output"
for s in "$KEEPER_KEY" "${KEEPER_KEY#0x}" "$SEED_SECRET" "${SEED_SECRET#0x}"; do
  if grep -qi -- "$s" "$TMP/run.log" "$TMP/hook.jsonl"; then fail "secret leaked"; fi
done
echo "webhook alerts: $(wc -l < "$TMP/hook.jsonl")"
echo "OK"
