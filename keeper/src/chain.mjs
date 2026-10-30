// Chain access for the keeper: clients, simulations that classify reverts, the route-A price, and send (simulate,
// sign, log, broadcast, wait). Nothing here logs a secret.
import {
  createPublicClient, createWalletClient, http, defineChain, encodeFunctionData, keccak256,
  BaseError, ContractFunctionRevertedError,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { coreAbi, routeErrorsAbi, v4QuoterAbi, testRouteAbi, MAINNET, SHORTFILL_SELECTORS, quotePoolFor } from "./abi.mjs";
import { logSend } from "./sendlog.mjs";
import { feePlan, GAS_CAP } from "./logic.mjs";

export function makeClients(cfg) {
  const chain = defineChain({
    id: cfg.chainId,
    name: cfg.chainId === 4663 ? "Robinhood Chain" : "Robinhood Chain Testnet",
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [cfg.rpcUrl] } },
  });
  const pub = createPublicClient({ chain, transport: http(cfg.rpcUrl) });
  const account = cfg.key ? privateKeyToAccount(cfg.key) : null;
  const wallet = account ? createWalletClient({ account, chain, transport: http(cfg.rpcUrl) }) : null;
  const address = account ? account.address : cfg.keeperAddress;
  return { chain, pub, wallet, account, address };
}

/** { name, args } for a contract revert, or null if the error isn't a revert (RPC down, etc.). */
export function revertOf(err) {
  if (!(err instanceof BaseError)) return null;
  const rev = err.walk((e) => e instanceof ContractFunctionRevertedError);
  if (!rev) return null;
  // match ShortFill by selector too (L6), so an ABI change can't break stall detection or the retry
  if (SHORTFILL_SELECTORS.has((rev.raw ?? "").slice(0, 10).toLowerCase())) return { name: "ShortFill", args: rev.data?.args ?? [] };
  if (rev.data) return { name: rev.data.errorName, args: rev.data.args ?? [] };
  return { name: rev.signature ?? rev.reason ?? "revert", args: [] };
}

const withRouteErrors = (abi) => [...abi, ...routeErrorsAbi];

/** Simulate a call as `from`. Returns { ok: true, result } or { ok: false, revert } (throws on non-revert errors). */
export async function simulate(c, { address, abi, functionName, args, from, blockNumber }) {
  try {
    const { result } = await c.pub.simulateContract({ address, abi: withRouteErrors(abi), functionName, args, account: from, ...(blockNumber !== undefined ? { blockNumber } : {}) });
    return { ok: true, result };
  } catch (e) {
    const revert = revertOf(e);
    if (!revert) throw e;
    return { ok: false, revert };
  }
}

/** Simulate the keeper's own buyback call (the quote): the buy-token output, or the revert (ShortFill = stall). */
export async function simulateSwap(c, cfg, ledger, route, usdgIn, minOut) {
  const call = ledger.call === "burn"
    ? { functionName: "burnBuyToken", args: [ledger.source, BigInt(route), usdgIn, minOut] }
    : { functionName: "buyForVault", args: [BigInt(route), usdgIn, minOut] };
  const r = await simulate(c, { address: cfg.core, abi: coreAbi, from: c.address, ...call });
  return r.ok ? { ok: true, route, out: r.result, call } : { ok: false, route, revert: r.revert, call };
}

/**
 * Route A's price for `usdgIn` in the anchor's units (buy-token wei per USDG unit, x1e18), from Uniswap's V4Quoter:
 * USDG -> ETH, then ETH -> the buy token on its quote pool. `ctx` = { buyToken, route }: on testnet, the TestRoute at
 * `route` (one that delivers the buy token) gives the rate.
 */
export async function priceRouteA(c, cfg, usdgIn, ctx) {
  if (cfg.priceMode === "testroute") {
    const rate = await c.pub.readContract({ address: ctx.route, abi: testRouteAbi, functionName: "RATE" });
    return rate * 10n ** 18n;
  }
  const pool = quotePoolFor(ctx.buyToken); // throws for a token with no quote pool: the caller fails closed
  const q = async (poolKey, zeroForOne, amt) => {
    const { result } = await c.pub.simulateContract({
      address: MAINNET.quoter, abi: v4QuoterAbi, functionName: "quoteExactInputSingle",
      args: [{ poolKey, zeroForOne, exactAmount: amt, hookData: "0x" }],
    });
    return result[0];
  };
  const eth = await q(MAINNET.usdgPool, false, usdgIn);
  const out = await q(pool, true, eth);
  return (out * 10n ** 18n) / usdgIn;
}

/**
 * Send one call: simulate with the exact args, then (live) sign, write the send log, broadcast, and wait. In a dry run
 * it stops after the simulation. Returns { dry, hash, result } or throws { revert } / Error.
 */
export async function send(c, cfg, log, { address, abi, functionName, args }) {
  const sim = await simulate(c, { address, abi, functionName, args, from: c.address });
  if (!sim.ok) {
    const e = new Error(`simulation reverted ${sim.revert.name}`);
    e.revert = sim.revert;
    throw e;
  }
  if (cfg.dryRun) {
    log({ event: "dry-run", to: address, functionName, args: args.map(String), result: String(sim.result ?? "") });
    return { dry: true, result: sim.result };
  }
  const data = encodeFunctionData({ abi, functionName, args });
  // M6: our own fees (2x base, no tip, hard ceiling) and a gas cap; never whatever the RPC suggests
  const base = (await c.pub.getBlock()).baseFeePerGas ?? 0n;
  const fees = feePlan(base, cfg.maxFeeWei);
  if (fees.skip) {
    const e = new Error(fees.skip);
    e.revert = { name: "FeeCap", args: [] };
    throw e;
  }
  const req = await c.wallet.prepareTransactionRequest({ account: c.account, to: address, data, value: 0n, chain: c.chain, ...fees });
  if (req.gas > GAS_CAP) {
    const e = new Error(`gas cap: estimate ${req.gas} > ${GAS_CAP}`);
    e.revert = { name: "GasCap", args: [] };
    throw e;
  }
  const serializedTransaction = await c.account.signTransaction(req);
  const hash = keccak256(serializedTransaction);
  await logSend(cfg, { chainId: cfg.chainId, nonce: req.nonce, hash, to: address, selector: data.slice(0, 10), sentAt: Math.floor(Date.now() / 1000) });
  await c.pub.sendRawTransaction({ serializedTransaction });
  const receipt = await c.pub.waitForTransactionReceipt({ hash, timeout: 120_000 });
  if (receipt.status !== "success") {
    // M2: decode why, by re-running the call at the block before (then at the block itself), so an onchain ShortFill
    // gets the same retry rule as a simulated one
    const e = new Error(`tx ${hash} reverted onchain`);
    e.onchain = true;
    e.hash = hash;
    for (const bn of [receipt.blockNumber - 1n, receipt.blockNumber]) {
      const r = await simulate(c, { address, abi, functionName, args, from: c.address, blockNumber: bn }).catch(() => null);
      if (r && !r.ok) {
        e.revert = r.revert;
        break;
      }
    }
    e.revert ??= { name: "RevertedOnchain", args: [] };
    log({ event: "reverted-onchain", to: address, functionName, hash, reason: e.revert.name });
    throw e;
  }
  log({ event: "sent", to: address, functionName, args: args.map(String), hash, block: Number(receipt.blockNumber) });
  return { dry: false, hash, result: sim.result };
}
