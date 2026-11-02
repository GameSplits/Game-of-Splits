// HTTP entry for signed shots. The signing key is loaded from the environment and never logged.

import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { pathToFileURL } from "node:url";
import {
  createPublicClient,
  createWalletClient,
  defineChain,
  encodeFunctionData,
  http,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { stashAbi } from "./abi.ts";
import { loadConfig, redact, type RelayerConfig } from "./config.ts";
import { decodeRevert, extractRevertData } from "./decode.ts";
import { NonceQueue, OwnerNonceGuard, RateLimit, ResignBook, type Sim } from "./policy.ts";
import { submitShot, type RelayDeps, type RelayState, type ShotRequest } from "./relay.ts";

interface Body {
  owner?: string;
  maxPrice?: string;
  expectedRound?: string;
  presetId?: number;
  color?: number;
  nonce?: string;
  deadline?: string;
  epoch?: string;
  signature?: string;
  replaces?: boolean;
}

function readBody(req: IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    let size = 0;
    req.on("data", (chunk: Buffer) => {
      size += chunk.length;
      if (size > 8192) {
        reject(new Error("too large"));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

function bad(res: ServerResponse, status: number, error: string): void {
  const body = JSON.stringify({ ok: false, error });
  res.writeHead(status, { "content-type": "application/json" });
  res.end(body);
}

export function encodeShot(kind: "shoot" | "take", body: Body): `0x${string}` {
  const signature = body.signature as Hex;
  if (kind === "shoot") {
    return encodeFunctionData({
      abi: stashAbi,
      functionName: "shoot",
      args: [
        {
          owner: body.owner as Hex,
          maxPrice: BigInt(body.maxPrice ?? "0"),
          expectedRound: BigInt(body.expectedRound ?? "0"),
          nonce: BigInt(body.nonce ?? "0"),
          deadline: BigInt(body.deadline ?? "0"),
          epoch: BigInt(body.epoch ?? "0"),
        },
        signature,
      ],
    });
  }
  return encodeFunctionData({
    abi: stashAbi,
    functionName: "take",
    args: [
      {
        owner: body.owner as Hex,
        maxPrice: BigInt(body.maxPrice ?? "0"),
        presetId: body.presetId ?? 0,
        color: body.color ?? 0,
        nonce: BigInt(body.nonce ?? "0"),
        deadline: BigInt(body.deadline ?? "0"),
        epoch: BigInt(body.epoch ?? "0"),
      },
      signature,
    ],
  });
}

export function parseShot(kind: "shoot" | "take", raw: string): ShotRequest {
  const body = JSON.parse(raw) as Body;
  if (!body.owner || !body.signature || !body.maxPrice || !body.nonce || !body.deadline || body.epoch === undefined) {
    throw new Error("bad request");
  }
  return {
    owner: body.owner,
    maxPrice: BigInt(body.maxPrice),
    replaces: body.replaces === true,
    calldata: encodeShot(kind, body),
  };
}

export function buildDeps(
  cfg: RelayerConfig,
  clients?: {
    simulate: RelayDeps["simulate"];
    send: RelayDeps["send"];
    ethBalance: RelayDeps["ethBalance"];
    pendingNonce: () => Promise<bigint>;
    alert?: RelayDeps["alert"];
  },
): { deps: RelayDeps; state: RelayState } {
  const secrets = [cfg.key, cfg.rpcUrl];
  const deps: RelayDeps = {
    now: () => Date.now(),
    simulate: clients?.simulate ?? (async () => ({ ok: true })),
    send: clients?.send ?? (async () => "0x"),
    ethBalance: clients?.ethBalance ?? (async () => LOW_PLACEHOLDER),
    alert: clients?.alert ?? (async (message) => {
      console.error(`ALERT ${redact(message, secrets)}`);
    }),
    priorityWei: cfg.priorityWei,
  };
  const state: RelayState = {
    rates: new RateLimit(),
    resigns: new ResignBook(),
    nonces: new NonceQueue(clients?.pendingNonce ?? (async () => 0n)),
    owners: new OwnerNonceGuard(),
  };
  return { deps, state };
}

const LOW_PLACEHOLDER = 10n ** 18n;

export function start(cfg: RelayerConfig): void {
  const account = privateKeyToAccount(cfg.key);
  const chain = defineChain({
    id: cfg.chainId,
    name: "Robinhood",
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [cfg.rpcUrl] } },
  });
  const transport = http(cfg.rpcUrl);
  const pub = createPublicClient({ chain, transport });
  const wallet = createWalletClient({ account, chain, transport });
  const secrets = [cfg.key, cfg.rpcUrl];

  const { deps, state } = buildDeps(cfg, {
    pendingNonce: () => pub.getTransactionCount({ address: account.address, blockTag: "pending" }),
    ethBalance: () => pub.getBalance({ address: account.address }),
    simulate: async (data) => {
      try {
        await pub.call({ account: account.address, to: cfg.stash, data });
        return { ok: true };
      } catch (err) {
        const dataHex = extractRevertData(err);
        return dataHex ? decodeRevert(dataHex) : { ok: false, kind: "other" };
      }
    },
    send: async (data, opts) => {
      const block = await pub.getBlock();
      const base = block.baseFeePerGas ?? 0n;
      const gas = await pub.estimateGas({ account: account.address, to: cfg.stash, data });
      return wallet.sendTransaction({
        account,
        chain,
        to: cfg.stash,
        data,
        nonce: Number(opts.nonce),
        gas: (gas * 12n) / 10n,
        maxFeePerGas: base + opts.priorityWei,
        maxPriorityFeePerGas: opts.priorityWei,
      });
    },
    alert: async (message) => {
      console.error(`ALERT ${redact(message, secrets)}`);
    },
  });

  const server = createServer(async (req, res) => {
    try {
      const url = req.url ?? "/";
      if (req.method === "GET" && url === "/health") {
        const balance = await deps.ethBalance();
        const low = balance < 5_000_000_000_000_000n;
        if (low) await deps.alert("relayer balance below 0.005 ETH");
        res.writeHead(200, { "content-type": "application/json" });
        res.end(JSON.stringify({ ok: true, balanceWei: balance.toString(), low }));
        return;
      }
      const kind = req.method === "POST" && url === "/shoot" ? "shoot" : req.method === "POST" && url === "/take" ? "take" : null;
      if (!kind) {
        bad(res, 404, "not found");
        return;
      }
      const raw = await readBody(req);
      const shot = parseShot(kind, raw);
      const result = await submitShot(deps, state, shot);
      res.writeHead(result.status, { "content-type": "application/json" });
      res.end(JSON.stringify(result.body));
    } catch (err) {
      const message = err instanceof Error ? err.message : "";
      console.error(redact(message, secrets));
      bad(res, 400, "bad request");
    }
  });

  server.listen(cfg.port, "127.0.0.1", () => {
    console.log(`relayer listening on ${cfg.port}`);
  });
}

const entry = process.argv[1];
if (entry && import.meta.url === pathToFileURL(entry).href) {
  try {
    start(loadConfig(process.env));
  } catch (err) {
    const message = err instanceof Error ? err.message : "config failed";
    console.error(redact(message, [process.env.RELAYER_KEY ?? "", process.env.RPC_URL ?? ""]));
    process.exit(1);
  }
}
