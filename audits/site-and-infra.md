# Site, relayer and hosting

This is a summary. The site lives in its own repository, and the relayer, keeper and watcher are in this one. Operational details such as hosting accounts, firewall settings and key handling are deliberately left out of the public record.

## What was checked

- **Code review of the site's server routes:** help chat, support tickets, sign-in sessions, settle and analytics reads, swap quotes, the admin view, and wallet bridge messaging. Each item had to come with a reproduction or a code-path proof. Anything unproven was recorded as Info.
- **Relayer HTTP surface:** signature checks before any budget is charged, gas caps, the hourly ETH budget, per-wallet and per-IP limits, origin allowlist, and the order id. Several fix-review rounds focused on never sending the same order twice.
- **Watcher and keeper:** authentication on the check and log endpoints, the keeper runner's chain, gas and nonce pins, and redaction of secrets in alerts.
- **Live checks (read-only):**
  - security headers on every host: HSTS, `nosniff`, frame restrictions, `object-src 'none'`, Permissions-Policy and a CSP with reporting;
  - a crawl of 343 URLs on the app host and 304 on the docs host, which found no source maps and no server secrets in pages or bundles;
  - the relayer answers CORS only for the site's own origins;
  - admin routes return 401.
- **Dependencies:** `npm audit` on every package. At the reviewed commit (5 Nov), the framework version was checked against the advisories published in 2026 and was already on the patched release.
- **Secrets:** a full-history scan of both repositories (see [static-analysis.md](static-analysis.md#secret-scanning)).

## Results

| Pass (2026) | Result |
|---|---|
| Website audit, 5 Nov | 0 Critical, 0 High. Fixed before mainnet: the help and support rate limits counted denied requests against everyone (SUP-01, Medium), and support tickets skipped the bot check when its keys were missing |
| Off-chain and site deep pass, 5 Nov | 0 Critical, 0 High. Five items (DP-1 to DP-5, two Medium and three Low) were fixed and then rechecked with their proofs of concept: an unthrottled settle read, client-written chat history, link filtering in chat replies, a host check on the bot challenge, and a malformed watcher token |
| Earlier fixes, rechecked 5 Nov | Sign-in domain taken from a spoofable header: closed. Relayer state kept in memory instead of the shared store: closed on mainnet (`/health` reports the shared store). Relayer order id: closed |
| Live sweep, 10 Nov | No secrets, source maps or broken links. The relayer origin allowlist and the admin lockout were confirmed live |
| Final sweep, 11 Nov | Confirmed fixed on the live site: same-origin checks and rate limits on the swap, satchel, analytics and settle APIs; an enforced Content-Security-Policy (no longer report-only); the help chat requiring the bot challenge in production; the relayer accepting only the site's own origins; valid TLS on every host; and the bot challenge checking the hostname |

## Known open items

A few minor items are still open, all Low or Info:
- a status endpoint on the relayer that has no rate limit;
- an edge case where two replies to a support ticket sent at the same moment can lose one;
- an optional extra flag on one security header.

None of them can move player funds or get around a contract rule. The contracts enforce every payout, limit and timelock on their own.

The site has transitive advisories in browser-side wallet libraries. None was shown to be reachable from the server. Fixing them needs major-version upgrades of the wallet SDKs, which were not made right before launch.

## Reporting

Report site issues the same way as contract issues: email support@gameofsplits.fun with `Security:` in the title.
