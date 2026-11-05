#!/usr/bin/env bash
# Sourced by the 4663 fork rehearsals (accept_flow.sh, fair0_sim.sh, e2e/keeper_watcher.sh) after anvil is up and the
# shell is in the temp copy of contracts/. Needs F (Foundry bin dir), L (the anvil URL) and E2E (this directory).
# Default: the real pinned mainnet Safe and its real owners, read from the fork. anvil --auto-impersonate signs for it.
# FORK_SAFE=1: a throwaway multisig SafeL2 from make_safe.sh, pinned into this temp copy by pin_safe.sh.
# Sets OWNER_SAFE, GOS_SAFE, ALMS_SAFE, SAFE_OWNERS and DEP (an unused deployer with nonce 0, never make_safe's sender).
REAL_SAFE=$(grep -oE 'PINNED_MAINNET_SAFE = 0x[0-9a-fA-F]{40}' script/Deploy.s.sol | awk '{print $3}')
if [ "${FORK_SAFE:-0}" = 1 ]; then
  OWNER_SAFE=$(bash "$E2E/make_safe.sh" $L 1); SAFE_OWNERS=$(bash "$E2E/make_safe.sh" owners)
  PATH="$F:$PATH" bash "$E2E/pin_safe.sh" $OWNER_SAFE
else
  [ -n "$REAL_SAFE" ] || { echo "no PINNED_MAINNET_SAFE in script/Deploy.s.sol" >&2; exit 1; }
  OWNER_SAFE=$REAL_SAFE
  SAFE_OWNERS=$("$F/cast" call $OWNER_SAFE "getOwners()(address[])" --rpc-url $L | tr -d '[] ')
fi
export OWNER_SAFE GOS_SAFE=$OWNER_SAFE ALMS_SAFE=$OWNER_SAFE SAFE_OWNERS
DEP=${DEP:-0x00000000000000000000000000000000De924663}
[ "$("$F/cast" nonce $DEP --rpc-url $L)" = 0 ] || { echo "deployer $DEP has a nonce on this fork, set DEP" >&2; exit 1; }
export DEPLOYER=$DEP
for a in $DEP $OWNER_SAFE ${SAFE_OWNERS//,/ }; do "$F/cast" rpc anvil_setBalance $a 0x56BC75E2D63100000 --rpc-url $L >/dev/null; done
echo "Safe $OWNER_SAFE ($([ "${FORK_SAFE:-0}" = 1 ] && echo throwaway fork Safe || echo real pinned Safe)), owners $SAFE_OWNERS, deployer $DEP"
