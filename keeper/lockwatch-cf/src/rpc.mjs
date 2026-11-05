// Minimal JSON-RPC + ABI helpers for RAT lockwatch (no viem in the Worker bundle).

const SEL = {
  currentRound: "8a19c8bc",
  closeTime: "675f1879",
  rounds: "8c65c81f",
  lockPairing: "821b1e97",
  fallbackSeed: "adbe72d5",
  pair: "9280bddf",
};

function pad32(hexNo0x) {
  return hexNo0x.replace(/^0x/, "").toLowerCase().padStart(64, "0");
}
function encUint(n) {
  return pad32(BigInt(n).toString(16));
}
function encAddr(a) {
  return pad32(a.replace(/^0x/, "").toLowerCase());
}

export function calldata(fn, args = []) {
  if (fn === "currentRound") return "0x" + SEL.currentRound;
  if (fn === "closeTime") return "0x" + SEL.closeTime + encUint(args[0]);
  if (fn === "rounds") return "0x" + SEL.rounds + encUint(args[0]);
  if (fn === "lockPairing") return "0x" + SEL.lockPairing + encUint(args[0]);
  if (fn === "fallbackSeed") return "0x" + SEL.fallbackSeed + encUint(args[0]);
  if (fn === "pair") return "0x" + SEL.pair + encUint(args[0]) + encUint(args[1]);
  throw new Error(`unknown fn ${fn}`);
}

export async function rpc(rpcUrl, method, params) {
  let lastErr;
  for (let attempt = 0; attempt < 4; attempt++) {
    const r = await fetch(rpcUrl, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
    });
    if (r.status === 429 || r.status === 503) {
      lastErr = new Error(`rpc ${method}: HTTP ${r.status}`);
      await new Promise((res) => setTimeout(res, 500 * (attempt + 1) * (attempt + 1)));
      continue;
    }
    const j = await r.json();
    if (j.error) {
      const msg = j.error.message || JSON.stringify(j.error);
      if (/too many requests/i.test(msg) || j.error.code === -32005) {
        lastErr = new Error(`rpc ${method}: ${msg}`);
        await new Promise((res) => setTimeout(res, 500 * (attempt + 1) * (attempt + 1)));
        continue;
      }
      throw new Error(`rpc ${method}: ${msg}`);
    }
    return j.result;
  }
  throw lastErr || new Error(`rpc ${method}: retries exhausted`);
}

export async function getBlock(rpcUrl) {
  const b = await rpc(rpcUrl, "eth_getBlockByNumber", ["latest", false]);
  return { number: BigInt(b.number), timestamp: BigInt(b.timestamp) };
}

export async function ethCall(rpcUrl, to, data, from) {
  const tx = { to, data };
  if (from) tx.from = from;
  return rpc(rpcUrl, "eth_call", [tx, "latest"]);
}

export async function ethCallOk(rpcUrl, to, data, from) {
  try {
    await ethCall(rpcUrl, to, data, from);
    return { ok: true };
  } catch (e) {
    return { ok: false, error: e.message };
  }
}

/** Decode rounds(uint256) return (ABI-encoded tuple). */
export function decodeRounds(hex) {
  const h = hex.replace(/^0x/, "");
  if (h.length < 18 * 64) throw new Error("rounds decode short");
  const word = (i) => h.slice(i * 64, (i + 1) * 64);
  const u = (i) => BigInt("0x" + word(i));
  // Layout matches the Solidity return of rounds():
  // 0 entrantsAcc, 1 pairingSeed, 2 entrants, 3 houseEntrants, 4 cursor, 5 shuffled,
  // 6 matches, 7 settled, 8 eligible, 9 bonusCursor, 10 status, 11 waiting, 12 bonusFixed,
  // 13 seedL2Block, 14 waitingId, 15 bonusPerPlayer, 16 paidTotal, 17 seedMixed
  return {
    pairingSeed: "0x" + word(1),
    entrants: Number(u(2)),
    status: Number(u(10)),
    seedL2Block: u(13),
    seedMixed: u(17) !== 0n,
  };
}

export function decodeUint(hex) {
  return BigInt(hex);
}

export async function ethGetTransactionCount(rpcUrl, address) {
  const hex = await rpc(rpcUrl, "eth_getTransactionCount", [address, "pending"]);
  return BigInt(hex);
}

export async function ethEstimateGas(rpcUrl, tx) {
  const hex = await rpc(rpcUrl, "eth_estimateGas", [tx]);
  return BigInt(hex);
}

export async function ethSendRawTransaction(rpcUrl, raw) {
  return rpc(rpcUrl, "eth_sendRawTransaction", [raw]);
}

export async function ethGetTransactionReceipt(rpcUrl, hash) {
  return rpc(rpcUrl, "eth_getTransactionReceipt", [hash]);
}

/** Poll until receipt or timeoutMs. */
export async function waitReceipt(rpcUrl, hash, { timeoutMs = 60000, pollMs = 1500 } = {}) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const rcpt = await ethGetTransactionReceipt(rpcUrl, hash);
    if (rcpt) return rcpt;
    await new Promise((r) => setTimeout(r, pollMs));
  }
  throw new Error(`receipt timeout for ${hash}`);
}
