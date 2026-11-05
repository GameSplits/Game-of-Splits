#!/usr/bin/env bash
# Sourced by the fork rehearsals after the main deploy wrote deployments/<chainId>.json (needs F and L).
# BLK-5: FeeSplitter is live at launch. On a 4663 fork the four holding legs are the Safe by code (LaunchSplit
# _feeLegs, DS-3), so they are left unset. On 46630 they come from env, and throwaway code-less holders stand in
# unless the caller exported its own (testnet_rehearsal exports the testnet Safe).
if [ "$("$F/cast" chain-id --rpc-url $L)" = 4663 ]; then
  unset PURSES REBATE BURN_BUYER OPS FEE_SPLIT_BPS
else
  export PURSES=${PURSES:-0x00000000000000000000000000000000Fee14663}
  export REBATE=${REBATE:-0x00000000000000000000000000000000Fee24663}
  export BURN_BUYER=${BURN_BUYER:-0x00000000000000000000000000000000Fee34663}
  export OPS=${OPS:-0x00000000000000000000000000000000Fee44663}
fi
# deploy_fee_splitter <sender> [extra forge args]: broadcast DeployFeeSplitter, prints the address line
deploy_fee_splitter() { local s=$1; shift
  "$F/forge" script script/DeployFeeSplitter.s.sol:DeployFeeSplitter --rpc-url $L --broadcast --unlocked --slow --sender $s "$@" 2>&1 \
    | grep -E "^  FeeSplitter|ONCHAIN EXECUTION|Error:" | sed -n 1,3p; }
