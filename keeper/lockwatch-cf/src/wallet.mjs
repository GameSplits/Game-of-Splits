// Minimal EIP-1559 signer for Cloudflare Workers (noble only, no viem).
import { secp256k1 } from "@noble/curves/secp256k1";
import { keccak_256 } from "@noble/hashes/sha3";
import { bytesToHex, hexToBytes } from "@noble/hashes/utils";

function keccak(bytes) {
  return keccak_256(bytes);
}

function strip0x(h) {
  return h.startsWith("0x") || h.startsWith("0X") ? h.slice(2) : h;
}

function hexToBytesStrict(h) {
  const s = strip0x(h);
  if (s.length % 2) throw new Error("odd hex");
  return hexToBytes(s);
}

function bytesToHex0x(b) {
  return "0x" + bytesToHex(b);
}

function addressFromPrivateKey(keyHex) {
  const priv = hexToBytesStrict(keyHex);
  const pub = secp256k1.getPublicKey(priv, false).slice(1); // uncompressed without 0x04
  const hash = keccak(pub);
  return bytesToHex0x(hash.slice(12));
}

/** RLP encode per Ethereum yellow paper. */
function rlpEncode(input) {
  if (input instanceof Uint8Array) return rlpEncodeBytes(input);
  if (Array.isArray(input)) return rlpEncodeList(input);
  throw new Error("rlp type");
}

function rlpEncodeBytes(b) {
  if (b.length === 1 && b[0] < 0x80) return b;
  if (b.length <= 55) {
    const out = new Uint8Array(1 + b.length);
    out[0] = 0x80 + b.length;
    out.set(b, 1);
    return out;
  }
  const len = encodeLength(b.length);
  const out = new Uint8Array(1 + len.length + b.length);
  out[0] = 0xb7 + len.length;
  out.set(len, 1);
  out.set(b, 1 + len.length);
  return out;
}

function rlpEncodeList(items) {
  const encoded = items.map((x) => rlpEncode(x));
  let total = 0;
  for (const e of encoded) total += e.length;
  if (total <= 55) {
    const out = new Uint8Array(1 + total);
    out[0] = 0xc0 + total;
    let o = 1;
    for (const e of encoded) {
      out.set(e, o);
      o += e.length;
    }
    return out;
  }
  const len = encodeLength(total);
  const out = new Uint8Array(1 + len.length + total);
  out[0] = 0xf7 + len.length;
  out.set(len, 1);
  let o = 1 + len.length;
  for (const e of encoded) {
    out.set(e, o);
    o += e.length;
  }
  return out;
}

function encodeLength(n) {
  if (n === 0) return new Uint8Array([0]);
  const hex = n.toString(16);
  const h = hex.length % 2 ? "0" + hex : hex;
  return hexToBytes(h);
}

function toUint(n) {
  if (typeof n === "bigint") {
    if (n === 0n) return new Uint8Array([]);
    let hex = n.toString(16);
    if (hex.length % 2) hex = "0" + hex;
    return hexToBytes(hex);
  }
  if (typeof n === "number") return toUint(BigInt(n));
  if (typeof n === "string") {
    const s = strip0x(n);
    if (!s || /^0+$/.test(s)) return new Uint8Array([]);
    const h = s.length % 2 ? "0" + s : s;
    return hexToBytes(h);
  }
  if (n instanceof Uint8Array) return n;
  throw new Error("toUint");
}

/**
 * Sign and serialize an EIP-1559 (type 2) transaction.
 * fields: { chainId, nonce, maxPriorityFeePerGas, maxFeePerGas, gasLimit, to, value, data, accessList? }
 */
export function signEip1559Tx(keyHex, fields) {
  const chainId = BigInt(fields.chainId);
  const nonce = BigInt(fields.nonce);
  const maxPriority = BigInt(fields.maxPriorityFeePerGas);
  const maxFee = BigInt(fields.maxFeePerGas);
  const gasLimit = BigInt(fields.gasLimit);
  const to = hexToBytesStrict(fields.to);
  const value = BigInt(fields.value ?? 0);
  const data = fields.data ? hexToBytesStrict(fields.data) : new Uint8Array([]);
  const accessList = []; // empty

  const unsigned = [
    toUint(chainId),
    toUint(nonce),
    toUint(maxPriority),
    toUint(maxFee),
    toUint(gasLimit),
    to,
    toUint(value),
    data,
    accessList,
  ];
  const encoded = rlpEncode(unsigned);
  const toSign = new Uint8Array(1 + encoded.length);
  toSign[0] = 0x02;
  toSign.set(encoded, 1);
  const msgHash = keccak(toSign);

  const priv = hexToBytesStrict(keyHex);
  const sig = secp256k1.sign(msgHash, priv);
  const compact = sig.toCompactRawBytes(); // 64 bytes r||s
  const r = compact.slice(0, 32);
  const s = compact.slice(32, 64);
  const yParity = sig.recovery; // 0 or 1

  const signed = [
    toUint(chainId),
    toUint(nonce),
    toUint(maxPriority),
    toUint(maxFee),
    toUint(gasLimit),
    to,
    toUint(value),
    data,
    accessList,
    toUint(BigInt(yParity)),
    r,
    s,
  ];
  const signedEnc = rlpEncode(signed);
  const raw = new Uint8Array(1 + signedEnc.length);
  raw[0] = 0x02;
  raw.set(signedEnc, 1);
  return bytesToHex0x(raw);
}

export function accountAddress(keyHex) {
  return addressFromPrivateKey(keyHex);
}

export { bytesToHex0x };
