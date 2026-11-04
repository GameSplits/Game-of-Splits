// Submit one signed Stash call. Simulate first, then send with a priority fee. Retry the send once.

import {
  GasCapError,
  GasLimitError,
  LOW_BALANCE_WEI,
  MemoryUsedOrders,
  NonceQueue,
  OwnerNonceGuard,
  RateLimit,
  ResignBook,
  SpendBudget,
  SpendCapError,
  decideSim,
  mayHaveBroadcast,
  maybeSentHash,
  type Limiter,
  type Nonces,
  type Sim,
  type Spend,
  type UsedOrders,
} from "./policy.ts";

export interface ShotRequest {
  owner: string;
  maxPrice: bigint;
  replaces: boolean;
  calldata: `0x${string}`;
  /** Hard gas cap for this action. Simulation and the send both stay under it. */
  gasCap: bigint;
  /** Authorize, set limit or revoke. Reserved against the account share of the ETH budget when there is one. */
  account?: boolean;
}

export interface SendOpts {
  nonce: bigint;
  priorityWei: bigint;
  gasCap: bigint;
  /** Reserve the worst-case cost of this send against the hourly ETH budget. False means do not send. */
  reserve(wei: bigint): boolean | Promise<boolean>;
  /** Called just before the raw send goes out. */
  broadcasting?(): void;
}

export interface RelayDeps {
  now(): number;
  simulate(data: `0x${string}`, gasCap: bigint): Promise<Sim>;
  send(data: `0x${string}`, opts: SendOpts): Promise<`0x${string}`>;
  ethBalance(): Promise<bigint>;
  alert(message: string): Promise<void>;
  priorityWei: bigint;
}

export interface RelayState {
  /** Per wallet budgets. Only a call that passed its signature check and simulation and was sent is counted. */
  rates: Limiter;
  /** 60 relayed calls an hour for each wallet. */
  hourly: Limiter;
  /** Per IP, counted on every request before any work, so junk is throttled without touching a wallet's budget. */
  ips: Limiter;
  resigns: ResignBook;
  nonces: Nonces;
  owners: OwnerNonceGuard;
  /** Hourly ETH the relayer may commit to sends. */
  spend: Spend;
  /** Signed orders already taken in the last 10 minutes. A repeat is refused before any work. */
  used?: UsedOrders;
  /** Hourly ETH kept for account actions. Without it they share `spend` with plays. */
  accountSpend?: Spend;
  /** Relayed revokes per owner. A revoke skips the balance gate, so it has its own small budget. */
  revokes?: Limiter;
}

/** Splits the hourly ETH budget so account actions can only use their share. */
export function splitBudget(ethPerHourWei: bigint, accountShareBps: bigint): { play: bigint; account: bigint } {
  const account = (ethPerHourWei * accountShareBps) / 10_000n;
  return { play: ethPerHourWei - account, account };
}

/** 3 relayed revokes an hour for each owner. */
export const REVOKES_PER_HOUR = 3;

export interface RelayResult {
  status: number;
  body: {
    ok: boolean;
    hash?: string;
    error?: string;
    resign?: boolean;
    livePrice?: string;
    liveRound?: string;
    /** Set with status 202 when the send may have reached the node. The hash is the signed transaction's, if known. */
    pending?: boolean;
    maybeSent?: boolean;
  };
  /** Set when a send may have reached the node, so the order must stay taken. */
  maybeSent?: boolean;
  /** Set once a raw send was tried in this request. Such a result is never marked not sent, and the order stays taken. */
  tried?: boolean;
}

export function freshState(pending: () => Promise<bigint>, ethPerHourWei: bigint, accountShareBps = 0n): RelayState {
  const split = splitBudget(ethPerHourWei, accountShareBps);
  return {
    rates: new RateLimit(30, 60_000),
    hourly: new RateLimit(60, 3_600_000),
    ips: new RateLimit(60, 60_000),
    resigns: new ResignBook(),
    nonces: new NonceQueue(pending),
    owners: new OwnerNonceGuard(),
    spend: new SpendBudget(split.play),
    used: new MemoryUsedOrders(),
    revokes: new RateLimit(REVOKES_PER_HOUR, 3_600_000),
    ...(split.account > 0n ? { accountSpend: new SpendBudget(split.account) } : {}),
  };
}

function simFailure(sim: Exclude<Sim, { ok: true }>, signedMax: bigint, resign: boolean): RelayResult {
  if (sim.kind === "price") {
    return {
      status: 400,
      body: {
        ok: false,
        error: sim.price > signedMax ? "price above signed max" : "simulation failed",
        livePrice: sim.price.toString(),
      },
    };
  }
  if (sim.kind === "round") {
    return {
      status: resign ? 409 : 400,
      body: {
        ok: false,
        error: "wrong round",
        ...(resign ? { resign: true } : {}),
        liveRound: sim.actual.toString(),
      },
    };
  }
  return { status: 400, body: { ok: false, error: sim.reason ?? "simulation failed" } };
}

async function readSim(deps: RelayDeps, data: `0x${string}`, gasCap: bigint): Promise<Sim | RelayResult> {
  try {
    return await deps.simulate(data, gasCap);
  } catch {
    try {
      return await deps.simulate(data, gasCap);
    } catch {
      return { status: 502, body: { ok: false, error: "simulation failed" } };
    }
  }
}

function isResult(value: Sim | RelayResult): value is RelayResult {
  return "status" in value;
}

async function sendOnceOrTwice(
  deps: RelayDeps,
  state: RelayState,
  data: `0x${string}`,
  gasCap: bigint,
  bumped: boolean,
  account = false,
): Promise<RelayResult> {
  const spend = account && state.accountSpend ? state.accountSpend : state.spend;
  const priorities = bumped ? [deps.priorityWei * 2n, deps.priorityWei * 2n] : [deps.priorityWei, deps.priorityWei * 2n];
  let last = priorities[0];
  // Both attempts share one reservation. The retry only tops it up when it needs more.
  let held = 0n;
  let heldAt = 0;
  const reserve = async (wei: bigint): Promise<boolean> => {
    if (wei <= held) return true;
    const at = deps.now();
    if (!(await spend.reserve(wei, at))) return false;
    if (held > 0n) await spend.release(held, heldAt);
    held = wei;
    heldAt = at;
    return true;
  };
  let maybeSent = false;
  let maybeHash: string | undefined;
  // A send the node seemed to refuse can still have been forwarded, so once one was tried nothing here says "not sent".
  let tried = false;
  // Budget and alert writes after a send are best effort: a KV error there must not lose the sent state.
  const quietly = async (step: () => unknown) => {
    try {
      await step();
    } catch {
      // best effort
    }
  };
  const failed = (): RelayResult => ({ status: 502, body: { ok: false, error: "relay failed" }, tried: true });
  for (let attempt = 0; attempt < 2; attempt++) {
    last = priorities[attempt] ?? last;
    try {
      const priorityWei = last;
      const hash = await state.nonces.run((nonce) => deps.send(data, { nonce, priorityWei, gasCap, reserve, broadcasting: () => void (tried = true) }));
      return { status: 200, body: { ok: true, hash } };
    } catch (err) {
      if (err instanceof GasCapError || err instanceof GasLimitError || err instanceof SpendCapError) {
        if (held > 0n && !maybeSent) await quietly(() => spend.release(held, heldAt));
      }
      if ((err instanceof GasCapError || err instanceof GasLimitError || err instanceof SpendCapError) && tried) {
        if (err instanceof SpendCapError) {
          await quietly(async () => {
            if (await spend.alertDue(deps.now())) await deps.alert("relayer hourly ETH budget reached, relaying paused");
          });
        }
        return failed();
      }
      if (err instanceof GasCapError) return { status: 503, body: { ok: false, error: "gas price above cap" } };
      if (err instanceof GasLimitError) return { status: 400, body: { ok: false, error: "gas above cap" } };
      if (err instanceof SpendCapError) {
        if (await spend.alertDue(deps.now())) await deps.alert("relayer hourly ETH budget reached, relaying paused");
        return { status: 503, body: { ok: false, error: "relay paused" } };
      }
      // A timeout may still have reached the node, so the reservation is kept and there is no retry under a new nonce.
      if (mayHaveBroadcast(err)) {
        maybeSent = true;
        maybeHash = maybeSentHash(err);
        break;
      }
      // The nonce queue refreshes from the pending count. One more attempt, then a clear error.
    }
  }
  if (held > 0n && !maybeSent) await quietly(() => spend.release(held, heldAt));
  // A send that may have gone out gets 202, never a 5xx, so a client does not take it for "relayer down" and send again.
  if (maybeSent) {
    return { status: 202, body: { ok: false, pending: true, maybeSent: true, error: "relay pending", ...(maybeHash ? { hash: maybeHash } : {}) }, maybeSent: true };
  }
  if (tried) return failed();
  return { status: 502, body: { ok: false, error: "relay failed" } };
}

export async function submitShot(deps: RelayDeps, state: RelayState, req: ShotRequest): Promise<RelayResult> {
  const owner = req.owner.toLowerCase();
  // Look only. The wallet's budgets are counted after the call is sent, so nobody else can use them up.
  if ((await state.rates.full(owner, deps.now())) || (await state.hourly.full(owner, deps.now()))) {
    return { status: 429, body: { ok: false, error: "rate limit" } };
  }
  if (req.replaces) {
    const gate = state.resigns.take(owner, req.maxPrice, deps.now());
    if (gate === "above") return { status: 400, body: { ok: false, error: "above signed max" } };
    if (gate !== "ok") return { status: 400, body: { ok: false, error: "resign window closed" } };
  }
  if (!state.owners.hold(owner)) {
    return { status: 409, body: { ok: false, error: "nonce in use" } };
  }
  try {
    const firstRead = await readSim(deps, req.calldata, req.gasCap);
    if (isResult(firstRead)) return firstRead;
    let sim = firstRead;
    let bumped = false;
    if (!req.replaces) {
      const first = decideSim(sim, req.maxPrice, false);
      if (first === "retry") {
        bumped = true;
        const again = await readSim(deps, req.calldata, req.gasCap);
        if (isResult(again)) return again;
        sim = again;
      } else if (first === "resign") {
        state.resigns.offer(owner, req.maxPrice, deps.now());
        return simFailure(sim as Exclude<Sim, { ok: true }>, req.maxPrice, true);
      } else if (first === "reject") {
        return simFailure(sim as Exclude<Sim, { ok: true }>, req.maxPrice, false);
      }
    }
    if (!sim.ok) return simFailure(sim, req.maxPrice, false);
    const balance = await deps.ethBalance();
    if (balance < LOW_BALANCE_WEI) await deps.alert("relayer balance below 0.005 ETH");
    const sent = await sendOnceOrTwice(deps, state, req.calldata, req.gasCap, bumped, req.account === true);
    if (sent.status === 200) {
      // Counted only for a call that passed its checks and was sent. The in-flight guard keeps this owner serial.
      // The hash is already out, so a counting failure must not turn this into an error.
      try {
        await state.rates.allow(owner, deps.now());
        await state.hourly.allow(owner, deps.now());
      } catch {
        // best effort
      }
    }
    return sent;
  } catch {
    return { status: 502, body: { ok: false, error: "relay failed" } };
  } finally {
    state.owners.release(owner);
  }
}
