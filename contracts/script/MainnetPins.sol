// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

/// @notice Values the mainnet deploy can't take back once set, pinned in a reviewed commit so a stale or testnet env
/// can't reach chain 4663. Deploy refuses anything else on 4663, and SafeAcceptVerify checks the live state against
/// these pins (not only against the env the deploy used).
library MainnetPins {
    /// The mainnet keeper EOA (0x4696…21E5). Gas money only; the Safe can replace it after a 48h timelock.
    address internal constant KEEPER = 0x4696ebA115691d7AA5A3bb810F172cdb7DCF21E5;

    /// Chapter 0 Alms allowlist: contracts/eligible/fair0.json, in that order. AlmsVote.setEligible has no remove,
    /// so these ids are permanent. A test (MainnetPins.t.sol) keeps this list equal to fair0.json.
    function fair0Eligible() internal pure returns (bytes32[] memory ids) {
        ids = new bytes32[](3);
        ids[0] = 0xb02173170bada3eb8162396b27744f9c5ac99bed3a632b1c4d2bc9b1b366b0e8; // Lung Cancer Foundation of America
        ids[1] = 0xc1f8523fd8f90bb29f8c20ef2dd5bce2d8a94d172083b59840e312f32a44a02b; // Pauseai US
        ids[2] = 0x48058626e8f67696c865eb4bacf23f3716d0f28968a65c29410dfc31d59fd93f; // 2Wish for Henry Nowak
    }
}
