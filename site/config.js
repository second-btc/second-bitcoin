// Filled in at launch (v1.0.1, the same day as genesis). On localhost only, ?token/?rpc/?explorer
// overrides are honoured for fork/testnet rehearsals; on the published site the token and chain are
// hard-pinned here and only https ?rpc/?explorer are accepted.
export const CONFIG = {
  chainId: 8453,
  chainName: "Base",
  rpc: "https://mainnet.base.org",
  token: "0x292198f6aceb505EbaD96ba7654bAe70B57c0fdd", // genesis block 50615795, Base mainnet
  explorer: "https://basescan.org",
  whitepaper: "whitepaper/second_bitcoin_en.html",
  repo: "https://github.com/second-btc/second-bitcoin",
  // per-address Merkle proof for the draw: dataBase + "proof/" + lowercase(address) + ".json"
  // → { "proof": ["0x..", ...] }   (absent file = address not in the eligible set)
  dataBase: "data/",
};
