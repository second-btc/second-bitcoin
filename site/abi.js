// Minimal ABI for the SecondBitcoinV2 (one-shot broad lottery) functions the dashboard reads and calls.
export const ABI = [
  // --- reads: supply / accounting
  { type: "function", stateMutability: "view", name: "totalSupply", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", stateMutability: "view", name: "decimals", inputs: [], outputs: [{ type: "uint8" }] },
  { type: "function", stateMutability: "view", name: "burned", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", stateMutability: "view", name: "DRAW", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", stateMutability: "view", name: "LIQUIDITY", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", stateMutability: "view", name: "drawClaimed", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", stateMutability: "view", name: "balanceOf", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }] },
  { type: "function", stateMutability: "view", name: "pool", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", stateMutability: "view", name: "eligibleCount", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", stateMutability: "view", name: "WINNERS0", inputs: [], outputs: [{ type: "uint256" }] },

  // --- reads: genesis / claim window
  { type: "function", stateMutability: "view", name: "genesisSeed", inputs: [], outputs: [{ type: "bytes32" }] },
  { type: "function", stateMutability: "view", name: "startTime", inputs: [], outputs: [{ type: "uint64" }] },
  { type: "function", stateMutability: "view", name: "CLAIM_WINDOW", inputs: [], outputs: [{ type: "uint256" }] },

  // --- reads: the draw
  { type: "function", stateMutability: "view", name: "drawOpen", inputs: [], outputs: [{ type: "bool" }] },
  { type: "function", stateMutability: "view", name: "isDrawWinner", inputs: [{ type: "address" }], outputs: [{ type: "bool" }] },
  { type: "function", stateMutability: "view", name: "drawPiece", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }] },
  { type: "function", stateMutability: "view", name: "claimedDraw", inputs: [{ type: "address" }], outputs: [{ type: "bool" }] },

  // --- writes
  { type: "function", stateMutability: "nonpayable", name: "claimDraw", inputs: [{ type: "bytes32[]", name: "proof" }], outputs: [] },
  { type: "function", stateMutability: "nonpayable", name: "sweepDraw", inputs: [], outputs: [] },
];
