#!/usr/bin/env bash
# Mainnet deploy in a CLEAN environment (P1). Re-executes itself under `env -i`, so nothing from the calling shell
# (a sourced testnet env, an old KEEPER or ELIGIBLE_IDS) can reach the deploy. Every value is set here from reviewed
# sources: the Safe and owners as pinned in script/Deploy.s.sol, the keeper from script/MainnetPins.sol, the toll
# recipient = the Safe, the allowlist from eligible/fair0.json. The deploy script checks the same pins on 4663.
#   bash script/deploy_mainnet_clean.sh <ANCHOR_SEED> <deployer address>              simulate only (default)
#   bash script/deploy_mainnet_clean.sh <ANCHOR_SEED> <deployer address> --broadcast  real broadcast (owner's yes)
# The keystore is the Foundry account gos-mainnet; its password is typed at forge's prompt, never passed here.
set -euo pipefail
if [ -z "${GOS_CLEAN_ENV:-}" ]; then
  exec env -i GOS_CLEAN_ENV=1 HOME="$HOME" PATH="$PATH" TERM="${TERM:-dumb}" bash "$0" "$@"
fi
SEED=${1:?usage: deploy_mainnet_clean.sh <ANCHOR_SEED> <deployer address> [--broadcast]}
SENDER=${2:?deployer address required}
MODE=${3:-}
cd "$(dirname "$0")/.."
[ -z "$(git status --porcelain -- src script eligible foundry.toml 2>/dev/null)" ] || { echo "refusing: uncommitted changes in src/script/eligible"; exit 1; }
RPC=https://rpc.mainnet.chain.robinhood.com
[ "$(cast chain-id --rpc-url $RPC)" = 4663 ] || { echo "RPC is not chain 4663"; exit 1; }

export GOS_SAFE=0x7c0fc9869f2D41D88CCA675A9A270214d59DA36a
export SAFE_OWNERS=0xCA652b365Fa1052d43297907B1eAe5676182Eb5c,0x8AAb7f969f7e6AE1098e4158EA4547F07A3204e2,0x36E54F5366b7d01529BA1abF233314184B876D89
export KEEPER=0x4696ebA115691d7AA5A3bb810F172cdb7DCF21E5
export TOLL_RECIPIENT=$GOS_SAFE
export ELIGIBLE_IDS=$(python3 -c "import json;print(json.load(open('eligible/fair0.json'))['ELIGIBLE_IDS'])")
export ANCHOR_SEED=$SEED DEPLOYER=$SENDER

grep -q "PINNED_MAINNET_SAFE = $GOS_SAFE;" script/Deploy.s.sol || { echo "GOS_SAFE differs from the pin in Deploy.s.sol"; exit 1; }
grep -q "KEEPER = $KEEPER;" script/MainnetPins.sol || { echo "KEEPER differs from script/MainnetPins.sol"; exit 1; }
echo "commit     $(git rev-parse --short HEAD)"
echo "GOS_SAFE   $GOS_SAFE (= TOLL_RECIPIENT)"
echo "KEEPER     $KEEPER"
echo "ELIGIBLE   $ELIGIBLE_IDS"
echo "SEED       $ANCHOR_SEED"
echo "DEPLOYER   $DEPLOYER nonce $(cast nonce $DEPLOYER --rpc-url $RPC), balance $(cast balance $DEPLOYER --ether --rpc-url $RPC) ETH"
echo "env        $(env | cut -d= -f1 | sort | tr '\n' ' ')"

ARGS=(script/Deploy.s.sol:DeployMainnet --rpc-url $RPC --sender "$DEPLOYER" --slow)
if [ "$MODE" = "--broadcast" ]; then
  read -r -p "Type DEPLOY MAINNET to broadcast: " ok
  [ "$ok" = "DEPLOY MAINNET" ] || { echo "not confirmed"; exit 1; }
  forge script "${ARGS[@]}" --account gos-mainnet --broadcast
else
  echo "== simulation only (no --broadcast, no key)"
  forge script "${ARGS[@]}"
fi
