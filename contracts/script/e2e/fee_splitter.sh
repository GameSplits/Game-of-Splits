#!/usr/bin/env bash
# Sourced by the fork rehearsals after the main deploy wrote deployments/<chainId>.json (needs F and L).
# BLK-5: FeeSplitter is live at launch. Throwaway code-less holders stand in for the four legs that are not the
# Locksley Vault. On mainnet these are the real addresses the owner signs off (RUNBOOK_KEEPER.md), never these.
export PURSES=${PURSES:-0x00000000000000000000000000000000Fee14663}
export REBATE=${REBATE:-0x00000000000000000000000000000000Fee24663}
export BURN_BUYER=${BURN_BUYER:-0x00000000000000000000000000000000Fee34663}
export OPS=${OPS:-0x00000000000000000000000000000000Fee44663}
# deploy_fee_splitter <sender> [extra forge args]: broadcast DeployFeeSplitter, prints the address line
deploy_fee_splitter() { local s=$1; shift
  "$F/forge" script script/DeployFeeSplitter.s.sol:DeployFeeSplitter --rpc-url $L --broadcast --unlocked --slow --sender $s "$@" 2>&1 \
    | grep -E "^  FeeSplitter|ONCHAIN EXECUTION|Error:" | sed -n 1,3p; }
