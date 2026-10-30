#!/usr/bin/env bash
# FORK REHEARSALS ONLY. Writes a throwaway fork Safe into PINNED_MAINNET_SAFE of the Deploy.s.sol in the CURRENT
# directory, which must be a temp copy of contracts/ (the e2e scripts cd into one). Refuses to touch a git checkout.
#   pin_safe.sh <safe address>
set -euo pipefail
[[ ${1:-} =~ ^0x[0-9a-fA-F]{40}$ ]] || { echo "usage: pin_safe.sh <address>" >&2; exit 1; }
[ -d .git ] || git rev-parse --is-inside-work-tree >/dev/null 2>&1 && { echo "refusing: $(pwd) is a git checkout, not a temp copy" >&2; exit 1; }
SUM=$(cast to-check-sum-address "$1" 2>/dev/null || echo "$1")
sed -i "s/address internal constant PINNED_MAINNET_SAFE = address(0);/address internal constant PINNED_MAINNET_SAFE = $SUM;/" script/Deploy.s.sol
grep -q "PINNED_MAINNET_SAFE = $SUM;" script/Deploy.s.sol || { echo "pin failed" >&2; exit 1; }
