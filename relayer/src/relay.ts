// Submit one signed Stash call. Simulate first, then send with a priority fee. Retry the send once.

import { GasCapError, LOW_BALANCE_WEI, NonceQueue, OwnerNonceGuard, RateLimit, ResignBook, decideSim, type Sim } from "./policy.ts";

export interface ShotRequest {
  owner: string;
  maxPrice: bigint;
  replaces: boolean;
  calldata: `0x${string}`;
}

export interface RelayDeps {
  now(): number;
  simulate(data: `0x${string}`): Promise<Sim>;
  send(data: `0x${string}`, opts: { nonce: bigint; priorityWei: bigint }): Promise<`0x${string}`>;
  ethBalance(): Promise<bigint>;
  alert(message: string): Promise<void>;
  priorityWei: bigint;
}

export interface RelayState {
  rates: RateLimit;
  ips: RateLimit;
  resigns: ResignBook;
  nonces: NonceQueue;
  owners: OwnerNonceGuard;
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

export function freshState(pending: () => Promise<bigint>): RelayState {
  return {
    rates: new RateLimit(30, 60_000),
    ips: new RateLimit(60, 60_000),
    resigns: new ResignBook(),
    nonces: new NonceQueue(pending),
    owners: new OwnerNonceGuard(),
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

async function readSim(deps: RelayDeps, data: `0x${string}`): Promise<Sim | RelayResult> {
  try {
    return await deps.simulate(data);
  } catch {
    try {
      return await deps.simulate(data);
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
  bumped: boolean,
): Promise<RelayResult> {
  const priorities = bumped ? [deps.priorityWei * 2n, deps.priorityWei * 2n] : [deps.priorityWei, deps.priorityWei * 2n];
  let last = priorities[0];
  for (let attempt = 0; attempt < 2; attempt++) {
    last = priorities[attempt] ?? last;
    try {
      const hash = await state.nonces.run((nonce) => deps.send(data, { nonce, priorityWei: last }));
      return { status: 200, body: { ok: true, hash } };
    } catch (err) {
      if (err instanceof GasCapError) return { status: 503, body: { ok: false, error: "gas price above cap" } };
      // The nonce queue refreshes from the pending count. One more attempt, then a clear error.
    }
  }
  return { status: 502, body: { ok: false, error: "relay failed" } };
}

export async function submitShot(deps: RelayDeps, state: RelayState, req: ShotRequest): Promise<RelayResult> {
  const owner = req.owner.toLowerCase();
  if (!state.rates.allow(owner, deps.now())) {
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
    const firstRead = await readSim(deps, req.calldata);
    if (isResult(firstRead)) return firstRead;
    let sim = firstRead;
    let bumped = false;
    if (!req.replaces) {
      const first = decideSim(sim, req.maxPrice, false);
      if (first === "retry") {
        bumped = true;
        const again = await readSim(deps, req.calldata);
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
    return await sendOnceOrTwice(deps, state, req.calldata, bumped);
  } catch {
    return { status: 502, body: { ok: false, error: "relay failed" } };
  } finally {
    state.owners.release(owner);
  }
}
