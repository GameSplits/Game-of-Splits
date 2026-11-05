# Stash relayer (Robinhood Chain testnet, 46630)

The relayer submits six signed Stash calls for the site. It pays gas. It holds no user funds and it cannot create orders: the site signs the payload, and the relayer submits that payload.

Stash on this chain is `0x79bf9F0B9d527b38fdD8Bcca4DD5b948290a1AE3`, wired to the 7555 set (FairCore `0xc76d5ED46786e67Fb5925928af18C08da7078Cf0`, Last Arrow `0x14700ccE7f3c0Fc7E1DA3BA303Fe632E52197316`, Sheriff's Seat `0x4f811cAAa659341a4d0066731F2bCa1b60e3F8ef`, USDG `0xA173301d53E1cA0790A6f8d074F515bFc543980c`). The relayer wallet is `0x58941E09432D2EF6316FA3b99476e69e68933c94`. Its key is the env var `RELAYER_KEY` and is never written into the repo.

Shoot and Take are signed by the session key. Withdraw, AuthorizeKey, SetLimit, and RevokeKey are signed by the owner. Every signed action uses the owner's Stash nonce (`nonces(owner)`).

## What it does

1. Rejects a payload whose `chainId` is not 46630 or whose `stash` is not the deployment above.
2. Checks a 65-byte signature against the Stash EIP-712 domain (`Stash` / `1` / chain 46630 / that contract). Shoot and Take must recover to the owner's current session key. The other four must recover to the owner. Any other signature length is refused, unless the signer is a contract whose code hash is listed in `ERC1271_CODEHASHES` (empty by default). For a listed wallet the relayer calls its `isValidSignature` with a 100,000 gas allowance and requires the ERC-1271 magic value. No signature is ever passed on unchecked. List only non-proxy wallet code: a proxy shares one code hash across implementations. The on-chain call is still bounded by the action's gas cap.
3. Refuses an order whose nonce is below the owner's current Stash nonce (`nonce used`). Such an order already landed.
4. Simulates the call with `eth_call` from the relayer, under the gas cap for that action. A revert is returned to the site and nothing is sent.
5. Sends the same calldata with a priority fee on top of the base fee, and with value 0. The gas limit is the estimate plus 20%, never above the cap: `RELAY_GAS_CAP_PLAY` for shoot and take (default 900,000), `RELAY_GAS_CAP_ACCOUNT` for withdraw, authorize, set limit and revoke (default 250,000). An estimate above the cap is refused with `gas above cap`. The relayer nonce comes from the pending transaction count.
6. If that send fails, refreshes the nonce and tries once more at double the priority fee. The second failure returns `relay failed`.

A quoted price that moved and still sits inside the signed max is simulated once more, then sent at double the priority fee. A wrong round returns `resign: true` plus `liveRound`. One replacement for that owner is accepted within 60 seconds when `replaces` is true and the new max price is at or below the original.

Limits are 60 requests per IP in a 60-second window, counted on every request before any other work. Each owner gets 30 relayed calls in a 60-second window and 60 in an hour, counted only after the signature check and the simulation pass and the call is sent, so nobody else can use up an owner's allowance with junk or replayed orders. Every send reserves its gas limit times its max fee against `RELAY_ETH_PER_HOUR` (default 0.02 ETH) over a rolling hour. When that is spent the relay answers `relay paused`, sends nothing and raises one alert, and resumes as the window rolls. A withdraw must be above the withdrawal fee (`WITHDRAW_FEE` in USDG units, default 1000000 = 1 USDG), and the owner's Stash balance must also be above it, read from the Stash before the call is sent. A relayed authorize key or set limit needs a Stash balance of at least `RELAY_ACCOUNT_MIN_BALANCE`, or it is refused with `deposit first`. A relayed revoke key is always accepted while the owner has a live key, so a key can always be cut off, and each owner gets 3 relayed revokes an hour. A revoke with no live key needs the same balance. Account actions reserve gas from their own share of the hourly budget (`RELAY_ACCOUNT_BUDGET_SHARE`) and plays from the rest. A Take carries only its preset line; a body with its own `line` is refused and `/lines` answers empty. The IP is the first `x-forwarded-for` hop, or the socket address when that header is absent. Counters live in the process. On Vercel each instance keeps its own, which is enough for this testnet.

Below 0.005 ETH the relayer logs `ALERT relayer balance below 0.005 ETH`, sets `low: true` on `GET /health`, and POSTs to `HEALTHCHECK_URL` when that var is set. Point the URL at the monitor's failure endpoint (for healthchecks.io, the check URL plus `/fail`).

## API

JSON bodies. Amounts are decimal strings. `presetId` and `color` are numbers. Responses are JSON. Browsers may call these routes; the signature is the authorization.

| Method | Path | Body |
| --- | --- | --- |
| GET | `/health` | none |
| POST | `/shoot` | Shoot order |
| POST | `/take` | Take order |
| POST | `/withdraw` | Withdraw order |
| POST | `/authorize-key` | AuthorizeKey order |
| POST | `/set-limit` | SetLimit order |
| POST | `/revoke-key` | RevokeKey order |

The same paths are served under `/api/...`. CORS allows `GET`, `POST`, and `OPTIONS` only from the origins in `ALLOW_ORIGIN` plus preview URLs matching `ALLOW_ORIGIN_PATTERN`. Any other origin gets no allow header. Signatures still protect every action; CORS only stops other sites calling the relayer from a browser.

`GET /health`

```json
{ "ok": true, "balanceWei": "10000000000000000", "low": false, "chainId": 46630, "stash": "0x79bf9F0B9d527b38fdD8Bcca4DD5b948290a1AE3", "relayer": "0x58941E09432D2EF6316FA3b99476e69e68933c94" }
```

`POST /shoot`

```json
{
  "chainId": 46630,
  "stash": "0x79bf9F0B9d527b38fdD8Bcca4DD5b948290a1AE3",
  "order": {
    "owner": "0x...",
    "maxPrice": "1150000",
    "expectedRound": "2",
    "nonce": "0",
    "deadline": "1790000000",
    "epoch": "1"
  },
  "signature": "0x...",
  "replaces": false
}
```

`POST /take`

```json
{
  "chainId": 46630,
  "stash": "0x79bf9F0B9d527b38fdD8Bcca4DD5b948290a1AE3",
  "order": {
    "owner": "0x...",
    "maxPrice": "1500000",
    "presetId": 0,
    "color": 1,
    "nonce": "1",
    "deadline": "1790000000",
    "epoch": "1"
  },
  "signature": "0x..."
}
```

`POST /withdraw`

```json
{
  "chainId": 46630,
  "stash": "0x79bf9F0B9d527b38fdD8Bcca4DD5b948290a1AE3",
  "order": { "owner": "0x...", "amount": "5000000", "nonce": "2", "deadline": "1790000000" },
  "signature": "0x..."
}
```

`POST /authorize-key`

```json
{
  "chainId": 46630,
  "stash": "0x79bf9F0B9d527b38fdD8Bcca4DD5b948290a1AE3",
  "order": {
    "owner": "0x...",
    "key": "0x...",
    "limit": "1000000000",
    "expiry": "1790000000",
    "nonce": "3",
    "deadline": "1790000000"
  },
  "signature": "0x..."
}
```

`POST /set-limit`

```json
{
  "chainId": 46630,
  "stash": "0x79bf9F0B9d527b38fdD8Bcca4DD5b948290a1AE3",
  "order": { "owner": "0x...", "newLimit": "2000000", "nonce": "4", "deadline": "1790000000" },
  "signature": "0x..."
}
```

`POST /revoke-key`

```json
{
  "chainId": 46630,
  "stash": "0x79bf9F0B9d527b38fdD8Bcca4DD5b948290a1AE3",
  "order": { "owner": "0x...", "nonce": "5", "deadline": "1790000000" },
  "signature": "0x..."
}
```

Success is `{ "ok": true, "hash": "0x..." }`. The hash is the transaction hash. The handler returns it without waiting for a receipt.

Failures:

| Status | `error` | When |
| --- | --- | --- |
| 400 | `wrong chain` | `chainId` is missing or not 46630 |
| 400 | `wrong stash` | `stash` is missing or not the deployment |
| 400 | `bad signature` | a 65-byte signature does not recover to the owner or the session key, or any other length from a signer that is not an allowlisted ERC-1271 wallet that accepts it |
| 400 | `nonce used` | the order's nonce is below the owner's Stash nonce |
| 400 | `gas above cap` | the gas estimate is above the cap for that action |
| 400 | `bad request` | the JSON shape is wrong |
| 400 | `price above signed max` | the quote is above `maxPrice` (`livePrice` is set) |
| 400 | `above signed max` | a replacement raises the signed max |
| 400 | `resign window closed` | a second replacement, or one with no offer |
| 400 | a decoded revert | `insufficient balance`, `deadline expired`, `key expired`, `bad nonce`, and the other Stash and game errors |
| 409 | `wrong round` | the round moved (`resign: true`, `liveRound` set) |
| 409 | `nonce in use` | this owner already has a call in flight on this instance |
| 400 | `amount must be above the withdrawal fee` | a withdraw at or below `WITHDRAW_FEE` |
| 400 | `balance at or below the withdrawal fee` | the owner's Stash balance is at or below `WITHDRAW_FEE` |
| 502 | `balance unavailable` | the Stash balance could not be read |
| 400 | `custom lines are off` | a Take with its own `line` |
| 429 | `rate limit` | the owner or the IP is over the window |
| 503 | `relay paused` | the hourly ETH budget is spent |
| 502 | `relay failed` | the send failed, the one retry failed, and nothing went out |
| 202 | `relay pending` | the send may have gone out (`pending: true`, `maybeSent: true`, `hash` when known). Do not send the order another way until its nonce moves, the hash is mined or its deadline passes |
| 502 | `simulation failed` | the `eth_call` itself failed twice |
| 502 | `session unavailable` | the session read failed |
| 503 | `balance unavailable` | `/health` could not read the balance |

Every refusal made before anything was sent carries `sent: false` in the body and the header `x-gos-relay: not-sent` (exposed to browsers through CORS). Only then is it safe to send the order another way at once. `relay failed` and `relay pending` never carry it.

### EIP-712

Domain: name `Stash`, version `1`, chainId `46630`, verifyingContract `0x79bf9F0B9d527b38fdD8Bcca4DD5b948290a1AE3`.

Primary types and fields, in this order:

- `Shoot(address owner,uint256 maxPrice,uint256 expectedRound,uint256 nonce,uint256 deadline,uint256 epoch)`
- `Take(address owner,uint256 maxPrice,uint8 presetId,uint8 color,uint256 nonce,uint256 deadline,uint256 epoch)`
- `Withdraw(address owner,uint256 amount,uint256 nonce,uint256 deadline)`
- `AuthorizeKey(address owner,address key,uint256 limit,uint256 expiry,uint256 nonce,uint256 deadline)`
- `SetLimit(address owner,uint256 newLimit,uint256 nonce,uint256 deadline)`
- `RevokeKey(address owner,uint256 nonce,uint256 deadline)`

`epoch` is `session(owner).epoch`. `deadline` and `expiry` are unix seconds.

## Env

| Name | Required | Value |
| --- | --- | --- |
| `CHAIN_ID` | yes | `46630` on testnet or `4663` on mainnet. Any other value, or none, refuses to start. There is no default chain |
| `RPC_URL` | yes | the testnet RPC, for example `https://rpc.testnet.chain.robinhood.com` |
| `STASH` | yes | must equal the Stash pinned for that chain in `src/config.ts` (`CHAINS`). Testnet is `0x79bf9F0B9d527b38fdD8Bcca4DD5b948290a1AE3`. Mainnet `MAINNET_STASH` is null until DeployStashMainnet has run, and while it is null the relayer refuses to start on 4663 |
| `RELAYER_KEY` | yes | hex key for `0x58941E09432D2EF6316FA3b99476e69e68933c94`. Dashboard or shell only |
| `HEALTHCHECK_URL` | no | POST target used when the balance is under 0.005 ETH |
| `PRIORITY_GWEI` | no | priority fee in gwei. Default `0.02` |
| `MAX_FEE_GWEI` | no | gas price cap in gwei (base fee plus tip). Over it the relay answers 503 and sends nothing. Default `0.5`, must be above twice `PRIORITY_GWEI` |
| `RELAY_GAS_CAP_PLAY` | no | gas cap for a relayed shoot or take. Default `900000`. The highest seen on testnet is 557,499 |
| `RELAY_GAS_CAP_ACCOUNT` | no | gas cap for a relayed withdraw, authorize, set limit or revoke. Default `250000`. The highest seen on testnet is 79,548 |
| `RELAY_ACCOUNT_MIN_BALANCE` | no | Least Stash balance in USDG units for a relayed authorize key or set limit. Below it the relay answers `deposit first`. Default `1000000` (1 USDG) |
| `RELAY_ACCOUNT_BUDGET_SHARE` | no | Share of `RELAY_ETH_PER_HOUR` kept for authorize key, set limit and revoke key. Plays get the rest, so account actions never pause plays. Default `0.25` |
| `RELAY_ETH_PER_HOUR` | no | ETH the relayer may commit to gas in any rolling hour, per instance. Default `0.02` |
| `ERC1271_CODEHASHES` | no | comma-separated code hashes of contract wallets whose non-65-byte signatures are checked. Default empty, which refuses all of them |
| `ALLOW_ORIGIN` / `ALLOWED_ORIGINS` | no | comma-separated exact origins. Default per chain. Testnet is `https://testnet.gameofsplits.fun,https://gos-testnet.vercel.app` and mainnet is `https://gameofsplits.fun,https://www.gameofsplits.fun`. `*` is refused |
| `ALLOW_ORIGIN_PATTERN` | no | one anchored regex for our Vercel previews. Default matches gos-testnet and gos-staging on the game-of-splits team and is never loaded when `CHAIN_ID` is 4663, even if set. `off` disables it |
| `KV_REST_API_URL` / `KV_REST_API_TOKEN` | production | Upstash REST URL and token. On Vercel link the `gos-seat-lines` store. Without them production refuses to start |
| `PORT` | local only | default `8787`. Vercel ignores it |

The process refuses to start on any other chain id or Stash address. A filled `.env` is gitignored. Copy `.env.example`.

## Local

```
cd relayer
npm ci
npm test
npm run test:fork
```

`npm test` is the unit suite. `npm run test:fork` starts an anvil fork of the public testnet RPC, funds the throwaway relayer with `anvil_setBalance` on that fork, and relays a signed shoot and a signed take through the deployed Stash. It needs `anvil` and `forge` on `PATH`. It does not broadcast.

```
cp .env.example .env
npm start
```

Fill `RELAYER_KEY` in the shell or the local file. The log line prints the relayer address and the port.

## Vercel

The service is one Node function, `api/relay.mjs`, because a warm instance then shares the nonce queue. `vercel.json` rewrites the paths above onto it. The handler returns the transaction hash and does not wait for a receipt, so it fits a function. Build emits `dist/` from `src/` (`npm run build`). Fluid Compute is the default runtime and covers the RPC calls.

1. Create a Vercel project named `gos-relayer-testnet`.
2. Set the root directory to `relayer`. Framework preset: Other. Node.js 22.
3. Build command: `npm run build` (also set in `vercel.json`). Install command: `npm ci`.
4. Set the env vars in the table above for Production and Preview. Set `RELAYER_KEY` in the dashboard. Do not put it in Git, in the build logs, or in a committed file.
5. Deploy the branch. This repository change does not deploy and does not broadcast.
6. `GET https://<deployment>/health` should show `chainId` 46630, the Stash address, `relayer` equal to `0x58941E09432D2EF6316FA3b99476e69e68933c94`, and `low: false` once that wallet holds more than 0.005 ETH.
7. Fund `0x58941E09432D2EF6316FA3b99476e69e68933c94` with testnet ETH from a normal wallet. The relayer only spends that ETH on gas.

To roll back, promote the previous Vercel deployment. The contract does not change.
