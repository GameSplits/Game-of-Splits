# Internal review

No audit firm has issued a report on this repository. Treat the contracts as unaudited. The public docs say the same: https://docs.gameofsplits.fun/docs/security

The full record of how the contracts were checked is in the [`audits/`](audits/README.md) folder:

- [audits/README.md](audits/README.md): methods, scope, the deployed commit, and what was not done
- [audits/findings.md](audits/findings.md): every confirmed finding with its severity, status and fix
- [audits/static-analysis.md](audits/static-analysis.md): Slither and Aderyn results and triage
- [audits/test-results.md](audits/test-results.md): test counts, invariants, coverage and rehearsals
- [audits/site-and-infra.md](audits/site-and-infra.md): the site, relayer and hosting, as a summary

The earlier Slither triage is kept in [contracts/SLITHER.md](contracts/SLITHER.md). Scope, the admin model and known limitations are in [SECURITY.md](SECURITY.md).

## External AI-assisted reviews

External reviews of this code were AI-assisted. They were not an engagement with an audit firm, and no firm signed the result. Every reported item was checked by hand against the code before it was accepted or rejected.

Fixed findings from the earlier rounds are kept as regression tests:

- `contracts/test/audit/Audit36.t.sol`, findings dated 25 Oct 2026 in the file comment, including the unseeded-anchor case
- `contracts/test/audit/ReviewLowsRegression.t.sol`, the low-severity set marked K16 in the tests
- `contracts/test/audit/ReviewSweepRegression.t.sol`, an earlier external review sweep
- `contracts/test/audit/FlashPass.fork.t.sol`, the pass flash-loan case

## FairCore swap accounting

Severity: Low. Status: fixed in commit [`ed72b0a`](https://github.com/GameSplits/Game-of-Splits/commit/ed72b0a) ("Measure FairCore swap output on own balance"), merged to `main` on 31 Oct 2026 UTC. The mainnet deployment includes the fix.

`FairCore._swap` measured the buy-token balance change on the recipient, which is LocksleyVault or the dead address `0x000000000000000000000000000000000000dEaD`. Permissionless calls can add to those balances while a route is running: `RakeBuyer.forward`, `FeeSplitter.distribute` and `RobinAmongThieves.flushBondBurn`. A route that delivered less than `minOut` could therefore still pass the check, and `Burned` or `BoughtForVault` could report a larger fill than the route delivered.

The fix pays the route output to FairCore and measures the increase on FairCore's own balance. That increase must be at least `minOut`, and FairCore then transfers exactly that amount to the recipient. Routes, the price floor and the caps are unchanged. The fix adds `contracts/test/unit/MaliciousRoute.t.sol`.

The same commit also adds these checks:

- FeeSplitter rejects FairCore and RakeBuyer as legs and as rescue targets.
- RakeBuyer rejects FairCore as its vault or `forwardTo`.
- SafeAccept requires that legs, the rake vault and `forwardTo` have no code or are on the allowlist.

The residual risk is in [SECURITY.md](SECURITY.md#swap-payee-residual).
