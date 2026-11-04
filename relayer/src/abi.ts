// Stash calls the relayer submits. Type strings match contracts/src/Stash.sol.
// The unsigned shoot, unsigned take, and deposit are intentionally absent.

export const SHOOT_TYPE =
  "Shoot(address owner,uint256 maxPrice,uint256 expectedRound,uint256 nonce,uint256 deadline,uint256 epoch)";
export const TAKE_TYPE =
  "Take(address owner,uint256 maxPrice,uint8 presetId,uint8 color,uint256 nonce,uint256 deadline,uint256 epoch)";
export const WITHDRAW_TYPE = "Withdraw(address owner,uint256 amount,uint256 nonce,uint256 deadline)";
export const AUTHORIZE_TYPE =
  "AuthorizeKey(address owner,address key,uint256 limit,uint256 expiry,uint256 nonce,uint256 deadline)";
export const SET_LIMIT_TYPE = "SetLimit(address owner,uint256 newLimit,uint256 nonce,uint256 deadline)";
export const REVOKE_TYPE = "RevokeKey(address owner,uint256 nonce,uint256 deadline)";

export const SHOOT_TYPEHASH = "0x801186bd6009f0b16ebf43fffa8c3c173af2178b7c8457dbf9f9413499652cff";
export const TAKE_TYPEHASH = "0x0d04c6d024e9e0c841385c23ea018007a89b83781233965c4f2503c204df279d";
export const WITHDRAW_TYPEHASH = "0x01c0cae105b74756987dd85f70208e6b1ab292bfe09eb9eb3cf1cb22c5b923ac";
export const AUTHORIZE_TYPEHASH = "0xc7c417990b8adaa983c11bd3af27f2b72404d9a41c2329fd63cccb0d688adadf";
export const SET_LIMIT_TYPEHASH = "0x49acf3a5fcb5086492df52f6e8520d5ebd4e10f3c9cb13c8fa807292ba28f22d";
export const REVOKE_TYPEHASH = "0xe7c3c128fa72e6e3ba56d2f036fdb8d1071644703a0d2af68e10cc7ca1812f51";

export const stashAbi = [
  {
    type: "function",
    name: "shoot",
    stateMutability: "nonpayable",
    inputs: [
      {
        name: "order",
        type: "tuple",
        components: [
          { name: "owner", type: "address" },
          { name: "maxPrice", type: "uint256" },
          { name: "expectedRound", type: "uint256" },
          { name: "nonce", type: "uint256" },
          { name: "deadline", type: "uint256" },
          { name: "epoch", type: "uint256" },
        ],
      },
      { name: "signature", type: "bytes" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "take",
    stateMutability: "nonpayable",
    inputs: [
      {
        name: "order",
        type: "tuple",
        components: [
          { name: "owner", type: "address" },
          { name: "maxPrice", type: "uint256" },
          { name: "presetId", type: "uint8" },
          { name: "color", type: "uint8" },
          { name: "nonce", type: "uint256" },
          { name: "deadline", type: "uint256" },
          { name: "epoch", type: "uint256" },
        ],
      },
      { name: "signature", type: "bytes" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "withdraw",
    stateMutability: "nonpayable",
    inputs: [
      {
        name: "order",
        type: "tuple",
        components: [
          { name: "owner", type: "address" },
          { name: "amount", type: "uint256" },
          { name: "nonce", type: "uint256" },
          { name: "deadline", type: "uint256" },
        ],
      },
      { name: "signature", type: "bytes" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "authorizeKey",
    stateMutability: "nonpayable",
    inputs: [
      {
        name: "order",
        type: "tuple",
        components: [
          { name: "owner", type: "address" },
          { name: "key", type: "address" },
          { name: "limit", type: "uint256" },
          { name: "expiry", type: "uint256" },
          { name: "nonce", type: "uint256" },
          { name: "deadline", type: "uint256" },
        ],
      },
      { name: "signature", type: "bytes" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "setLimit",
    stateMutability: "nonpayable",
    inputs: [
      {
        name: "order",
        type: "tuple",
        components: [
          { name: "owner", type: "address" },
          { name: "newLimit", type: "uint256" },
          { name: "nonce", type: "uint256" },
          { name: "deadline", type: "uint256" },
        ],
      },
      { name: "signature", type: "bytes" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "revokeKey",
    stateMutability: "nonpayable",
    inputs: [
      {
        name: "order",
        type: "tuple",
        components: [
          { name: "owner", type: "address" },
          { name: "nonce", type: "uint256" },
          { name: "deadline", type: "uint256" },
        ],
      },
      { name: "signature", type: "bytes" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "balance",
    stateMutability: "view",
    inputs: [{ name: "owner", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "session",
    stateMutability: "view",
    inputs: [{ name: "owner", type: "address" }],
    outputs: [
      { name: "key", type: "address" },
      { name: "expiry", type: "uint48" },
      { name: "epoch", type: "uint48" },
      { name: "limit", type: "uint256" },
      { name: "spent", type: "uint256" },
      { name: "feeCap", type: "uint256" },
    ],
  },
  {
    type: "function",
    name: "nonces",
    stateMutability: "view",
    inputs: [{ name: "owner", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
  },
] as const;

/** ERC-1271, called only for a wallet whose code hash is allowlisted. */
export const erc1271Abi = [
  {
    type: "function",
    name: "isValidSignature",
    stateMutability: "view",
    inputs: [
      { name: "hash", type: "bytes32" },
      { name: "signature", type: "bytes" },
    ],
    outputs: [{ name: "", type: "bytes4" }],
  },
] as const;

export const ERC1271_MAGIC = "0x1626ba7e";
