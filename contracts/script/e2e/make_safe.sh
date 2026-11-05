#!/usr/bin/env bash
# Deploy a real multisig SafeL2 1.4.1 proxy on a LOCAL anvil fork and print its address (fork tests only).
#   make_safe.sh <rpc> <salt>      needs cast on PATH or FOUNDRY_BIN; the sender is auto-impersonated
# Owners are throwaway addresses (printed as SAFE_OWNERS by `make_safe.sh owners`). The Safe then executes one real
# no-op transaction, approved on-chain by two owners (approveHash, impersonated by anvil), so its nonce is 1, like a
# Safe its signers have actually used: the deploy script requires that.
set -euo pipefail
O1=0x000000000000000000000000000000000000A001 O2=0x000000000000000000000000000000000000A002 O3=0x000000000000000000000000000000000000A003
# MAKE_SAFE_OWNERS=a,b,c makes the Safe with those three owners instead (accept_flow.sh 0d: a twin of the real Safe).
[ -n "${MAKE_SAFE_OWNERS:-}" ] && IFS=, read -r O1 O2 O3 <<< "$MAKE_SAFE_OWNERS"
[ "${1:-}" = owners ] && { echo "$O1,$O2,$O3"; exit 0; }
F=${FOUNDRY_BIN:-$(dirname "$(command -v cast)")}; L=$1; SALT=${2:-1}
FACTORY=0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67 SINGLETON=0x29fcB43b46531BcA003ddC8FCB67FFE91900C762
HANDLER=0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99 FROM=0x00000000000000000000000000000000De910000
INIT=$("$F/cast" calldata "setup(address[],uint256,address,bytes,address,address,uint256,address)" "[$O1,$O2,$O3]" 2 0x0000000000000000000000000000000000000000 0x $HANDLER 0x0000000000000000000000000000000000000000 0 0x0000000000000000000000000000000000000000)
"$F/cast" rpc anvil_setBalance $FROM 0x56BC75E2D63100000 --rpc-url $L >/dev/null
SAFE=$("$F/cast" call $FACTORY "createProxyWithNonce(address,bytes,uint256)(address)" $SINGLETON $INIT $SALT --from $FROM --rpc-url $L)
"$F/cast" send $FACTORY "createProxyWithNonce(address,bytes,uint256)" $SINGLETON $INIT $SALT --from $FROM --unlocked --rpc-url $L >/dev/null
[ "$("$F/cast" call $SAFE "getThreshold()(uint256)" --rpc-url $L)" = "2" ] || { echo "Safe deploy failed" >&2; exit 1; }
# one real Safe transaction (a no-op call to itself), pre-approved by owners 1 and 2
Z=0x0000000000000000000000000000000000000000
TXH=$("$F/cast" call $SAFE "getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)(bytes32)" $SAFE 0 0x 0 0 0 0 $Z $Z 0 --rpc-url $L)
for o in $O1 $O2; do
  "$F/cast" rpc anvil_setBalance $o 0x56BC75E2D63100000 --rpc-url $L >/dev/null
  "$F/cast" send $SAFE "approveHash(bytes32)" $TXH --from $o --unlocked --rpc-url $L >/dev/null
done
# v=1: "approved hash" signatures, sorted by owner. python3 pads the address (real addresses overflow bash printf).
SIG=0x$(python3 -c "import sys;o=sorted(int(a,16) for a in sys.argv[1:]);print(''.join('%064x%064x01'%(a,0) for a in o))" $O1 $O2)
"$F/cast" send $SAFE "execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)" $SAFE 0 0x 0 0 0 0 $Z $Z $SIG --from $O1 --unlocked --rpc-url $L >/dev/null
[ "$("$F/cast" call $SAFE "nonce()(uint256)" --rpc-url $L)" = "1" ] || { echo "Safe test tx failed" >&2; exit 1; }
echo $SAFE
