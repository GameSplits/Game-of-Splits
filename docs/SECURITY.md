# Swap payee residual

FairCore counts a keeper swap by its own buy-token balance, then forwards that amount to the vault or to the burn address. A payment to the vault or to the burn address during the swap is not counted.

That measurement assumes nothing permissionless pays FairCore the buy token while the route runs. FeeSplitter rejects FairCore and RakeBuyer as legs and as rescue targets. RakeBuyer rejects FairCore as `forwardTo` when the change is queued, and its constructor rejects a vault equal to FairCore. `address(0)` still means the vault.

What remains: the Safe can still aim a FeeSplitter leg, or RakeBuyer's `forwardTo`, at some other contract. That takes the 7-day FeeSplitter timelock or RakeBuyer's timelock. A route that calls that contract during the swap takes FairCore's 48-hour `SetRoute` timelock. If both are in place, the contract can push buy tokens to FairCore and a short-filling route can pass `minOut`. The tokens forwarded are the payee's, not an extra mint, but the route keeps the USDG.

SafeAccept fails that shape. A leg, RakeBuyer's vault, or `forwardTo` must have no code (an EOA, the unset forward, or the burn address) or be on the allowlist passed in (the Locksley Vault, and the burn address). A forwarder contract is rejected. The deployment file's `feeSplitter`, when present, must name this deploy's FairCore and RakeBuyer.

The watcher should alert when a FeeSplitter leg or `forwardTo` is set to an address that has code. That is the signal for the timelocked misconfiguration above. It is not a substitute for the accept check.
