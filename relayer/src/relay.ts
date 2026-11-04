// Submit one signed Stash call. Simulate first, then send with a priority fee. Retry the send once.

import {
  GasCapError,
  GasLimitError,
  LOW_BALANCE_WEI,
  NonceQueue,
  OwnerNonceGuard,
  RateLimit,
  ResignBook,
  SpendBudget,
  SpendCapError,
  decideSim,
  type Sim,
} from "./policy.ts";

export interface ShotRequest {
  owner: string;
  maxPrice: bigint;
  replaces: boolean;
  calldata: `0x${string}`;
  /** Hard gas cap for this action. Simulation and the send both stay under it. */
  gasCap: bigint;
}

export interface SendOpts {
  nonce: bigint;
  priorityWei: bigint;
  gasCap: bigint;
  /** Reserve the worst-case cost of this send against the hourly ETH budget. False means do not send. */
  reserve(wei: bigint): boolean;
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
  rates: RateLimit;
  /** 60 relayed calls an hour for each wallet. */
  hourly: RateLimit;
  /** Per IP, counted on every request before any work, so junk is throttled without touching a wallet's budget. */
  ips: RateLimit;
  resigns: ResignBook;
  nonces: NonceQueue;
  owners: OwnerNonceGuard;
  /** Hourly ETH the relayer may commit to sends. */
  spend: SpendBudget;
}

export interface RelayResult {
  status: number;
  body: {
    ok: boolean;
    hash?: string;
    error?: string;
    resign?: boolean;
    livePrice?: string;
    liveRound?: string;
  };
}

export function freshState(pending: () => Promise<bigint>, ethPerHourWei: bigint): RelayState {
  return {
    rates: new RateLimit(30, 60_000),
    hourly: new RateLimit(60, 3_600_000),
    ips: new RateLimit(60, 60_000),
    resigns: new ResignBook(),
    nonces: new NonceQueue(pending),
    owners: new OwnerNonceGuard(),
    spend: new SpendBudget(ethPerHourWei),
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
): Promise<RelayResult> {
  const priorities = bumped ? [deps.priorityWei * 2n, deps.priorityWei * 2n] : [deps.priorityWei, deps.priorityWei * 2n];
  let last = priorities[0];
  for (let attempt = 0; attempt < 2; attempt++) {
    last = priorities[attempt] ?? last;
    try {
      const priorityWei = last;
      const reserve = (wei: bigint) => state.spend.reserve(wei, deps.now());
      const hash = await state.nonces.run((nonce) => deps.send(data, { nonce, priorityWei, gasCap, reserve }));
      return { status: 200, body: { ok: true, hash } };
    } catch (err) {
      if (err instanceof GasCapError) return { status: 503, body: { ok: false, error: "gas price above cap" } };
      if (err instanceof GasLimitError) return { status: 400, body: { ok: false, error: "gas above cap" } };
      if (err instanceof SpendCapError) {
        if (state.spend.alertDue(deps.now())) await deps.alert("relayer hourly ETH budget reached, relaying paused");
        return { status: 503, body: { ok: false, error: "relay paused" } };
      }
      // The nonce queue refreshes from the pending count. One more attempt, then a clear error.
    }
  }
  return { status: 502, body: { ok: false, error: "relay failed" } };
}

export async function submitShot(deps: RelayDeps, state: RelayState, req: ShotRequest): Promise<RelayResult> {
  const owner = req.owner.toLowerCase();
  // Look only. The wallet's budgets are counted after the call is sent, so nobody else can use them up.
  if (state.rates.full(owner, deps.now()) || state.hourly.full(owner, deps.now())) {
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
    const sent = await sendOnceOrTwice(deps, state, req.calldata, req.gasCap, bumped);
    if (sent.status === 200) {
      // Counted only for a call that passed its checks and was sent. The in-flight guard keeps this owner serial.
      state.rates.allow(owner, deps.now());
      state.hourly.allow(owner, deps.now());
    }
    return sent;
  } catch {
    return { status: 502, body: { ok: false, error: "relay failed" } };
  } finally {
    state.owners.release(owner);
  }
}
