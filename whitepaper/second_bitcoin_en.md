# Second Bitcoin: A Second Chance at a Fair Start

*secondbtc*
*August 2026 · a one-time redistribution*


**Abstract.** Bitcoin opened a way to issue coins through mining. It took issuance away from any central institution, but left distribution to a mining race. To enter that race you needed information and equipment. So today, for almost everyone, the only way to obtain bitcoin is to buy it from someone who was there earlier. We open that distribution over again — with a coin that distributes itself.

It is issued to people who already hold wallets, on a principle of equality, and the only thing a recipient has to do is claim. Total supply is 210,000 coins — one hundredth of Bitcoin's. It is minted once at genesis, with no function to mint more. 2BTC likewise does not decide who will hold it: a sealed seed and randomness set each share, so no one can choose the recipients. What it does is open the same odds to wallets that mining could never give a place to. This equality is per wallet, not per person; that capital can create several qualifying wallets to enter more often is a limit we set out in §1.

Distribution is a **single act of redistribution at genesis**. About 90% of the supply is allocated broadly, by one random seed, to wallets that already exist. There is no registration and no sale.

Each wallet's allocation and share are a function of the sealed seed and that wallet's own address. The contract computes and verifies it at the moment of claim, so there is no recipients' list to publish in advance and no publisher to trust. Trust is required in one place only: who builds the eligibility list, and how. Because the rule, its input data, and the program that computes it are all public, anyone can re-run the same computation and compare it against the list we posted; an address outside the rule shows up in that comparison. The author keeps one tenth of one percent — 210 coins, most of it locked and released over 2 years after the seal.

## 1. Introduction

Bitcoin's paper begins with the problem of trust. This one begins with the next problem: who ends up holding it.

Bitcoin issues coins as a reward for mining. Mining is open in the sense that it turns no one away. But to actually enter, you needed information and equipment. In 2009 a single laptop could mine fifty coins a day — yet even then the threshold was whether you knew how to mine and had the machine to do it. In 2026 a laptop earns nothing. Mining has become the province of industrial rigs on cheap power, and a single coin costs more than most people earn in a month. Now the threshold is whether you have the equipment, and if not, whether you have the money. At every point, the door was shut to anyone with neither information, nor equipment, nor capital.

Instead, we leave who receives what not to any hand but to a rule sealed on the blockchain. Between a lower and an upper bound of eligibility, every wallet has the same chance, and randomness sets each one's share. This equality is per wallet, not per person. Someone with capital can create several wallets above the floor to enter more often. Even so, no wallet has better odds than another, and the eligibility floor makes preparing those wallets a matter of capital, not a free script. The eligibility rule is also fixed and published at issuance without prior notice, so it is hard to prepare wallets aimed at the criteria in advance.

## 2. Distribution

One coin divides into a hundred million smallest units. In a nod to Bitcoin's satoshi, we call the unit sat2. Total supply is 210,000 coins, minted once at genesis, with no mint function thereafter.

| Allocation | Coins | Share | Method |
|---|---:|---:|---|
| **Redistribution** | 188,790 | 89.9% | fixed genesis list · self-verifying allocation · 1–50 per wallet, skewed |
| Public liquidity | 21,000 | 10.0% | single-sided Uniswap v3 · no ETH · position token burned |
| Founder, liquid | 50 | 0.024% | genesis reward |
| Founder, locked | 160 | 0.076% | released linearly over 2 years after the seal |

Distribution happens once, at genesis. About 90% of the supply is allocated by a single redistribution; the rest is liquidity and the founder's share. This 89.9% is a budget, though: the number of recipients is set so the sum of the random pieces stays under it, so the amount actually distributed is somewhat less, and whatever is not distributed, along with whatever is not claimed, is burned.

## 3. The redistribution

### 3.1 Who is eligible — and why

Eligibility is fixed once and forever, from the on-chain state at snapshot block *B*. *B* is not a chosen block — it is **the genesis block itself, the block in which this contract was deployed**. The moment the rules become public, *B* and both balance legs (*B* and *B*−2 weeks) are already history. So no one can read the rules and then move funds or spin up wallets to qualify. The founder chooses when to deploy; the thresholds were fixed before deployment and live in the repository's history, and what that choice can buy is bounded by the residual trust disclosed in §3.2.

1. **Assets** — held between **0.1 and 40 ETH** at both *B* and two weeks before *B* — Base and Ethereum balances combined; the 40 ETH ceiling is roughly one bitcoin's worth around genesis.
2. **Account age** — first transaction at least 12 months before *B*, taking the earlier of Base and Ethereum.
3. **Real activity** — transacted across several months, with between 20 and 20,000 transactions across Base and Ethereum combined (a real user, not automated infrastructure).
4. **Recent activity** — sent a transaction on either chain within the last ~two weeks.
5. **A plain wallet** — no contract code, or an EIP-7702 delegation only.

**Why the bounds:**
- **Floor 0.1 ETH** — filters out the empty wallets that can be minted at random. It makes filling the list with sybil addresses a matter of capital, not a script.
- **Ceiling 40 ETH, roughly 1 BTC** — the reason this coin exists. Excluding the already-large wallets widens the set of first recipients and keeps the start from concentrating in a few hands. The entire redistribution goes only to wallets holding less than 40 ETH.
- **Age and history** — selects active, real-use wallets. Requiring an old account and months of activity screens out wallets thrown together to chase the drop. This blocks sybils and, at the same time, makes it hard to suspect that the founder — or anyone — prepared wallets in advance: such a wallet would have had to be genuinely used for over a year, and the rules are revealed only at issuance. And because abandoned wallets never claim and so end in burn, this threshold also raises the claim rate.

Because eligibility is set directly in ETH balances, no exchange rate or oracle is needed. Anyone can check it from on-chain ETH balances alone, and the question of "which price was used" never arises as a point of trust.

### 3.2 The self-verifying allocation

A claimant submits only one proof: that their address is in the eligibility list. It is a Merkle proof — a mathematical demonstration that a single address is included, without re-posting the whole list. The contract then computes a fixed hash, keccak256, from the sealed seed and that address, and decides for itself whether the address has a share and how many coins it takes. Because each wallet's result is independent of the others, the contract only ever computes for the one claimant. There is no recipients' list to publish in advance, and no publisher to trust.

This trustlessness has a boundary. It holds for "allocation and share," but not for "the construction of the eligibility list." The list is computed solely from the on-chain state of the public block *B* and the fixed criteria of §3.1, with no room for the founder to change it at will — but the party who actually performs that computation and posts it on-chain is the founder. The seed is sealed after the list is committed, from L1 beacon randomness at a time designated at the moment of commitment. So the seal cannot be re-rolled by changing its timing, and planting an address in the list cannot bias it toward winning: a planted address wins with the same odds as anyone else.

If, however, the person building the list is dishonest, they can quietly insert wallets they control that genuinely meet the criteria. Such wallets have broken no rule, so they do receive allocations. The total issuance is unchanged, but that share goes to the author rather than to someone else — real coins. There is, in principle, no cap on how much can be planted this way. The defense is reproducibility. Because the rule, the inputs, and the computing program are published as-is, verification is not a new judgment but a re-run of the same computation: a third party runs the program again to produce the canonical list and compares it, hash for hash, against the committed one. An address outside the rule shows up in that comparison. Sampling alone can miss a few planted addresses, so the comparison must be exhaustive — and someone must actually carry it out. The eligibility rule is fixed before deployment and lives in the repository's history, and *B* is set by the block in which the deployment transaction lands. By the time the rules are public, both balance legs are already history — so dressing up wallets to fit the rule after reading it is blocked; the only room left is the case above, of placing already-held qualifying wallets into the list. We draw the boundary of trust-minimization here, plainly.

### 3.3 Pieces — 1 to 50, mean about 7, skewed

Recipients do not all receive the same number. Instead of a uniform split, with its mean of 25.5, pieces are drawn from a heavily right-skewed distribution: mostly 1 to 5, rarely up to 50, with a mean of about 7. The distribution and its probabilities are published.

The redistribution budget is 188,790 coins. The number of recipients is set, with a safety margin, so the sum of the pieces does not exceed that budget — roughly twenty-some thousand wallets receive, with the exact number fixed when the eligible list is committed and the count of eligible wallets *N* is known. Because each piece is computed from its own address alone, the amount actually distributed is somewhat below the budget, and that difference, along with whatever is not claimed, is burned. If eligible wallets outnumber what the budget can hold, recipients are drawn at random from among them; if fewer, every eligible wallet receives.

## 4. Network

A standard ERC-20 on **Base**, an Ethereum L2. A claim costs about a cent, and Ethereum wallets work as they are. The name is *Second Bitcoin*, ticker *2BTC*, eight decimals. **A different address under the same name is not this.**

## 5. Incentives

The author's share is one tenth of one percent — **210 coins** — disclosed here. Of these, **50 are liquid** at genesis, used for testing and demonstration; the other **160 are locked**, released linearly over 2 years from the seal. While the public redistribution completes within its claim window, the founder's locked share unlocks slowly behind it. After genesis the founder has no on-chain powers — no minting, no clawback, no interference in the allocation.

## 6. Liquidity

Ten percent of the supply is placed into a single-sided Uniswap v3 position — coins only, no ETH — from a published starting price $P_0$ up to the top of the range, in the genesis transaction itself. The position's ownership token is burned, so this liquidity belongs to no one and cannot be withdrawn. **This is the ground for saying there is no sale: no one, the founder included, can take out the ETH that comes in.** Below $P_0$ there is no liquidity; the first buyer brings the first ETH, and that ETH is all a later seller can sell into. In other words, the pool has **no bid at first**: a holder can only sell once someone deposits ETH to buy, and until then any real trading market is one holders make themselves. The protocol provides no buy-side liquidity.

The only market the author opens is this single-sided pool. Peer-to-peer trades, pools someone else creates, exchanges — those are others' doing, not ours. $P_0$ is merely the price at which the locked liquidity begins, not a basis for value. The founder's 50 liquid coins can trade in this market like any other wallet's. We make no claim about the price thereafter.

## 7. Claiming

A recipient claims **for themselves, from their own address**. The claim window stays open for **at least 180 days** from the seal, so no one misses it. When the window closes, the unclaimed remainder is **burned in full**. There is no mechanism to claim on someone's behalf. If many wallets are abandoned, a substantial part may burn — this is by design: what is burned is not redistributed, it simply reduces the remaining supply.

Because distribution is a single event at genesis, there are no epochs and no clock. After the seal, nothing about this coin needs a person or any outside data to keep running.

## 8. Privacy

This coin is **permissionless** in the sense that there is no account to register or connect. But that is not confidentiality — not anonymity. Because the eligibility list and the sealed seed are both public, anyone can compute, before a claim, whether each eligible address was selected and for how much. And the mere fact that an address is on the list reveals that at the snapshot it was a wallet holding between 0.1 and 40 ETH, active for over a year. A participant should weigh that this openness can become a target-and-phishing risk. It is the intrinsic cost of on-chain self-verification and cannot be designed away. The author publishes under a pseudonym.

## 9. Conclusion

Bitcoin took trust out of issuance. This coin takes it out of distribution. With a single sealed random value, it opens one broad redistribution to wallets that already exist. The rules are fixed before the first coin moves; the founder's share is small, disclosed, and behind everyone else's. There is no treasury, no sale, no promise. Each wallet's share is a function of the sealed seed and that wallet's own address, and anyone can verify it. From a starting line that mining had already divided, this opens to the wallets left behind the same odds at a second start. Whether it is worth anything is not for this paper to say.

---

### Appendix — parameters (summary)

| | |
|---|---|
| Supply | 210,000 coins (8 decimals), minted at genesis, no mint function |
| Allocation | redistribution 188,790 (89.9%) · liquidity 21,000 (10%) · founder 210 (0.1%) |
| Redistribution | one-shot · fixed-list self-verify · 1–50 skewed, mean ~7 · ~20-some thousand wallets within the 188,790 budget · eligibility: 0.1–40 ETH, account age ≥12 months, activity history, no price oracle · undistributed and unclaimed burned |
| Claiming | open ≥180 days from the seal · unclaimed burned in full · no claim-on-behalf, no dead-man switch, no operator |
| Seed | sealed after the list commit (L1 beacon randomness at a time designated at commit) · cannot be re-rolled by seal timing · no human involvement after |
| Liquidity | single-sided v3, P₀ published, LP burned, non-withdrawable, no protocol bid |
| Founder | 210 = 0.1%, locked and released linearly over 2 years after the seal |

*This document describes software. It is not an offer, solicitation, or advice. The coin may be worth nothing; there is no warranty of any kind, and it is unaffiliated with Bitcoin, Base, or Uniswap. Availability may be restricted in some jurisdictions, and eligibility, transferability, and value are not guaranteed.*
