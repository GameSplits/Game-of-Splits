// Stash calls the relayer submits. Type strings match contracts/src/Stash.sol.

export const SHOOT_TYPE =
  "Shoot(address owner,uint256 maxPrice,uint256 expectedRound,uint256 nonce,uint256 deadline,uint256 epoch)";
export const TAKE_TYPE =
  "Take(address owner,uint256 maxPrice,uint8 presetId,uint8 color,uint256 nonce,uint256 deadline,uint256 epoch)";

export const SHOOT_TYPEHASH = "0x801186bd6009f0b16ebf43fffa8c3c173af2178b7c8457dbf9f9413499652cff";
export const TAKE_TYPEHASH = "0x0d04c6d024e9e0c841385c23ea018007a89b83781233965c4f2503c204df279d";

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
] as const;
