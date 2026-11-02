// Submit one signed shot. Simulate first, then send with a priority fee. Retry once inside the signed max.

import { LOW_BALANCE_WEI, NonceQueue, OwnerNonceGuard, RateLimit, ResignBook, decideSim, type Sim } from "./policy.ts";

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

function liveOf(sim: Sim): { livePrice?: string; liveRound?: string } {
  if (sim.ok || sim.kind === "other") return {};
  if (sim.kind === "price") return { livePrice: sim.price.toString() };
  return { liveRound: sim.actual.toString() };
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
    let sim = await deps.simulate(req.calldata);
    let bumped = false;
    if (!req.replaces) {
      const first = decideSim(sim, req.maxPrice, false);
      if (first === "retry") {
        bumped = true;
        sim = await deps.simulate(req.calldata);
      } else if (first === "resign") {
        state.resigns.offer(owner, req.maxPrice, deps.now());
        return { status: 409, body: { ok: false, error: "wrong round", resign: true, ...liveOf(sim) } };
      } else if (first === "reject") {
        const error = !sim.ok && sim.kind === "price" ? "price above signed max" : "simulation failed";
        return { status: 400, body: { ok: false, error, ...liveOf(sim) } };
      }
    }
    if (!sim.ok) {
      const error = sim.kind === "price" ? "price above signed max" : sim.kind === "round" ? "wrong round" : "simulation failed";
      return { status: 400, body: { ok: false, error, ...liveOf(sim) } };
    }
    const balance = await deps.ethBalance();
    if (balance < LOW_BALANCE_WEI) await deps.alert("relayer balance below 0.005 ETH");
    const priorityWei = bumped ? deps.priorityWei * 2n : deps.priorityWei;
    const hash = await state.nonces.run((nonce) => deps.send(req.calldata, { nonce, priorityWei }));
    return { status: 200, body: { ok: true, hash } };
  } catch {
    return { status: 502, body: { ok: false, error: "relay failed" } };
  } finally {
    state.owners.release(owner);
  }
}
