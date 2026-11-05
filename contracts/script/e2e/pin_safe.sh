#!/usr/bin/env bash
# FORK REHEARSALS ONLY. Rewrites PINNED_MAINNET_SAFE in the Deploy.s.sol of the CURRENT directory to a throwaway fork
# Safe. The current directory must be a temp copy of contracts/ (the e2e scripts cd into one). Refuses a git checkout.
# Works whatever the pin is now (the real Safe since 4 Nov, or address(0) in old trees).
# The e2e scripts only call this with FORK_SAFE=1. By default they use the real pinned Safe, impersonated by anvil.
#   pin_safe.sh <safe address>
set -euo pipefail
[[ ${1:-} =~ ^0x[0-9a-fA-F]{40}$ ]] || { echo "usage: pin_safe.sh <address>" >&2; exit 1; }
if [ -d .git ] || git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "refusing: $(pwd) is a git checkout, not a temp copy" >&2; exit 1
fi
SUM=$(cast to-check-sum-address "$1" 2>/dev/null || echo "$1")
sed -E -i "s/(address internal constant PINNED_MAINNET_SAFE = )(address\(0\)|0x[0-9a-fA-F]{40});/\1$SUM;/" script/Deploy.s.sol
grep -q "PINNED_MAINNET_SAFE = $SUM;" script/Deploy.s.sol || { echo "pin failed" >&2; exit 1; }
