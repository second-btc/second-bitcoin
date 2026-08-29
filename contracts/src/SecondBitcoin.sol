// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {FounderVesting} from "./FounderVesting.sol";
import {INonfungiblePositionManager} from "./interfaces/IUniswapV3.sol";

/// @title Second Bitcoin (2BTC) — "a second chance at a fair distribution"
/// @notice 210,000 coins (1/100 of Bitcoin), 8 decimals. Minted once at genesis, never again.
///
///   Distribution pool  188,530  (89.78%)  → halving draw: epoch k (0..32) releases pool/2^(k+1);
///                                           epoch k lasts 2,100·(k+1) Bitcoin blocks (2,100, then 4,200, 6,300 …),
///                                           so epoch k is seeded by the Bitcoin block at H0 + 2,100·k(k+1)/2.
///                                           Recipients (random Base wallets, drawn with that block hash as seed)
///                                           claim for two weeks after a 24 h delay. Unclaimed coins are halved:
///                                           half burned, half added to the next epoch's draw.
///   Public liquidity    21,000  (10.00%)  → single-sided Uniswap v3 position, no ETH from anyone,
///                                           position NFT sent to 0x…dEaD — liquidity owned by no one.
///   Founder                470  ( 0.22%)  → 50 liquid (the genesis reward), 420 = 0.2% locked,
///                                           unlocking one halving behind the public curve.
///
/// The operator can only: commit a snapshot hash (once per epoch), open the next epoch with its Merkle root
/// (under the cap the contract computes, ≥ 2 h after the commit), skip an epoch (half of its amount is burned, half moves to the next),
/// and seed the pool once. The operator can never mint, reclaim or move coins. The contract cannot verify a
/// root against Bitcoin — a wrong root is provable by anyone, and claims only open 24 h after a root is posted.
contract SecondBitcoin is ERC20 {
    // ------------------------------------------------------------------ constants
    uint256 public constant UNIT = 1e8;
    uint256 public constant TOTAL_SUPPLY = 210_000 * UNIT;
    uint256 public constant FOUNDER_LIQUID = 50 * UNIT; // the genesis reward
    uint256 public constant FOUNDER_LOCKED = 160 * UNIT; // with the 50 liquid: 210 coins, 0.1% of supply
    uint256 public constant LIQUIDITY = 21_000 * UNIT;
    uint256 public constant DISTRIBUTION = 188_790 * UNIT;

    uint256 public constant EPOCHS = 33; // k = 0..32
    uint256 public constant CLAIM_WINDOW = 1; // unclaimed coins of epoch k are settled (halved) when epoch k+1 opens
    uint256 public constant CLAIM_SECONDS = 2_100 * 600; // claims stay open for two weeks (2,100 Bitcoin blocks, nominal)
    uint256 public constant MIN_COMMIT_LEAD = 2 hours; // a root cannot be posted within 2 h of its snapshot commit
    uint256 public constant CLAIM_DELAY = 24 hours; // claims open 24 h after a root is posted (time to verify it)
    uint256 public constant MAX_PIECE = 50 * UNIT; // no single claim above the largest possible piece
    int24 public constant MIN_USABLE_TICK = -887_200; // Uniswap v3, tick spacing 200
    int24 public constant MAX_USABLE_TICK = 887_200;
    uint24 public constant POOL_FEE = 10_000; // 1% tier
    uint64 public constant BTC_BLOCKS_UNIT = 2_100; // epoch k lasts BTC_BLOCKS_UNIT * (k+1) Bitcoin blocks
    uint256 public constant ABANDON_AFTER = 730 days; // dead-man's switch: no open/skip for two years → burn pool (must exceed the longest epoch, epoch 32 ≈ 481 days)
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // ------------------------------------------------------------------ roles
    address public operator;
    address public immutable founder;
    FounderVesting public immutable vesting;

    // ------------------------------------------------------------------ epoch state
    struct Epoch {
        bytes32 snapshotHash; // sha256 of the eligible-address snapshot, committed BEFORE the seed block
        bytes32 btcHash; // Bitcoin block hash at H_k = H0 + 2,100·k(k+1)/2 — the seed of the draw
        bytes32 root; // Merkle root of (k, account, amount) leaves
        uint64 commitTime;
        uint64 openTime;
        uint64 btcHeight;
        uint32 count; // number of recipients (informational)
        uint128 cap; // claimable this epoch = scheduled amount + half of the previous epoch's unclaimed (+ half of a skipped epoch's amount)
        uint128 claimed;
        bool skipped; // epoch was skipped: no root, its scheduled amount moved to the next epoch
    }

    mapping(uint256 => Epoch) public epochs;
    mapping(uint256 => mapping(address => bool)) public hasClaimed;
    uint256 public epochsOpened; // index of the next epoch to open (skipped epochs count as opened)
    uint256 public epochsSkipped;
    uint256 public scheduledRemaining; // part of DISTRIBUTION not yet assigned to an epoch cap
    uint256 public carry; // moved into the next epoch's cap: half of the previous epoch's unclaimed + half of a skipped epoch's amount
    uint64 public genesisBtcHeight; // H0, fixed at the genesis commit
    uint64 public immutable genesisBlock; // host-chain block of deployment = snapshot block B of epoch 0
    uint64 public lastActivity; // last open/skip/seed — commits do not count (no keep-alive by commit spam)
    bool public finalized;
    uint256 public burned;

    // ------------------------------------------------------------------ liquidity
    bool public poolSeeded;
    address public pool;
    uint256 public positionTokenId;

    // ------------------------------------------------------------------ events
    event OperatorChanged(address indexed previous, address indexed next);
    event SnapshotCommitted(uint256 indexed epoch, bytes32 snapshotHash, uint64 time);
    event EpochOpened(
        uint256 indexed epoch, uint64 btcHeight, bytes32 btcHash, bytes32 root, uint32 count, uint256 cap, uint256 carriedIn, uint256 burnedExpired
    );
    event EpochSkipped(uint256 indexed epoch, uint256 amountMovedToNext); // the other half was burned
    event Claimed(uint256 indexed epoch, address indexed account, uint256 amount);
    event PoolSeeded(address pool, uint256 tokenId, uint128 liquidity, uint256 amountUsed, uint256 dustBurned);
    event Finalized(uint256 burnedAmount, bool abandoned);

    error NotOperator();
    error BadEpoch();
    error NotCommitted();
    error TooEarly();
    error BadBtcHeight();
    error WindowClosed();
    error AlreadyClaimed();
    error BadProof();
    error CapExceeded();
    error AlreadyDone();
    error PoolNotReady();
    error AlreadyCommitted();
    error TooLarge();
    error BadPoolParams();

    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    constructor(address operator_, address founder_) ERC20("Second Bitcoin", "2BTC") {
        require(operator_ != address(0) && founder_ != address(0), "zero");
        operator = operator_;
        founder = founder_;
        vesting = new FounderVesting(address(this), founder_);

        _mint(address(this), DISTRIBUTION + LIQUIDITY);
        _mint(address(vesting), FOUNDER_LOCKED);
        _mint(founder_, FOUNDER_LIQUID);
        assert(totalSupply() == TOTAL_SUPPLY);

        scheduledRemaining = DISTRIBUTION;
        lastActivity = uint64(block.timestamp);
        genesisBlock = uint64(block.number);
    }

    function decimals() public pure override returns (uint8) {
        return 8;
    }

    // ------------------------------------------------------------------ operator
    function setOperator(address next) external onlyOperator {
        require(next != address(0), "zero");
        emit OperatorChanged(operator, next);
        operator = next;
    }

    /// @notice Step 1 of an epoch: commit the snapshot hash before Bitcoin reaches height H0 + 2,100k.
    ///         Verifiers compare `commitTime` with the timestamp of that Bitcoin block.
    /// @param genesisHeight For k == 0 only: the Bitcoin height H0 that will seed genesis, fixed here — before the
    ///        block exists — so the operator cannot pick H0 after seeing candidate hashes. Ignored for k > 0.
    function commitSnapshot(uint256 k, bytes32 snapshotHash, uint64 genesisHeight) external onlyOperator {
        if (finalized || k != epochsOpened || k >= EPOCHS) revert BadEpoch();
        require(snapshotHash != bytes32(0), "zero hash");
        Epoch storage e = epochs[k];
        if (e.snapshotHash != bytes32(0)) revert AlreadyCommitted(); // one shot: a commit can never be replaced
        if (k == 0) {
            require(genesisHeight > 0, "zero H0");
            genesisBtcHeight = genesisHeight; // fixed forever; openEpoch(0) must use exactly this height
        }
        e.snapshotHash = snapshotHash;
        e.commitTime = uint64(block.timestamp);
        emit SnapshotCommitted(k, snapshotHash, e.commitTime);
    }

    /// @notice Step 2: once the seed block exists, publish the recipients' Merkle root. The cap is computed
    ///         by the contract: halving schedule + half of the previous epoch's unclaimed (+ a skipped epoch's half).
    function openEpoch(uint256 k, uint64 btcHeight, bytes32 btcHash, bytes32 root, uint32 count)
        external
        onlyOperator
    {
        if (finalized || k != epochsOpened || k >= EPOCHS) revert BadEpoch();
        Epoch storage e = epochs[k];
        if (e.snapshotHash == bytes32(0)) revert NotCommitted();
        require(root != bytes32(0) && btcHash != bytes32(0), "zero");

        // H_k = H0 + 2,100·k(k+1)/2; H0 itself was fixed at the genesis commit, before the block existed
        if (btcHeight != btcHeightOf(k)) revert BadBtcHeight();
        _requirePrevSettled(k);
        if (block.timestamp < uint256(e.commitTime) + MIN_COMMIT_LEAD) revert TooEarly();

        uint256 burnedNow = _expire(k);
        (uint256 cap, uint256 carriedIn) = _schedule(k);

        e.btcHeight = btcHeight;
        e.btcHash = btcHash;
        e.root = root;
        e.count = count;
        e.cap = uint128(cap);
        e.openTime = uint64(block.timestamp);
        epochsOpened = k + 1;
        lastActivity = uint64(block.timestamp);
        emit EpochOpened(k, btcHeight, btcHash, root, count, cap, carriedIn, burnedNow);
    }

    /// @notice Skip epoch k: no root, no claims. A skip is public and is treated exactly like unclaimed coins —
    ///         half of the epoch's amount is burned, half moves to the next epoch — so it is never a free
    ///         re-roll. Skipped epochs do not advance the founder's vesting (epochsDrawn). Allowed only once the
    ///         genesis height is fixed, so the seed schedule can never fall back to known blocks.
    function skipEpoch(uint256 k) external onlyOperator {
        if (finalized || k != epochsOpened || k >= EPOCHS) revert BadEpoch();
        if (genesisBtcHeight == 0) revert NotCommitted();
        _requirePrevSettled(k);
        Epoch storage e = epochs[k];
        _expire(k); // the previous epoch's unclaimed: half burned, half carried
        (uint256 amount,) = _schedule(k); // schedule + whatever was carried in
        e.skipped = true;
        e.openTime = uint64(block.timestamp); // for the 4/5 gap guard of the next epoch
        uint256 half = amount / 2;
        uint256 toBurn = (k == EPOCHS - 1) ? amount : half; // nothing follows the last epoch
        if (k < EPOCHS - 1) carry += amount - half;
        burned += toBurn;
        _burn(address(this), toBurn);
        epochsOpened = k + 1;
        epochsSkipped += 1;
        lastActivity = uint64(block.timestamp);
        emit EpochSkipped(k, amount - toBurn);
    }

    /// @notice Bitcoin height that seeds epoch k: H0 + 2,100 · k(k+1)/2 (epoch lengths 2,100, 4,200, 6,300 …).
    function btcHeightOf(uint256 k) public view returns (uint64) {
        return genesisBtcHeight + uint64(uint256(BTC_BLOCKS_UNIT) * k * (k + 1) / 2);
    }

    /// @notice Nominal length of epoch k in Bitcoin blocks.
    function epochLengthBlocks(uint256 k) public pure returns (uint256) {
        return uint256(BTC_BLOCKS_UNIT) * (k + 1);
    }

    /// @dev On-chain clock guard: epoch k cannot open/skip before 4/5 of epoch k-1's nominal length has passed
    ///      since epoch k-1 opened (the contract cannot see Bitcoin; this bounds how far fabricated hashes could run ahead).
    function minGapBefore(uint256 k) public pure returns (uint256) {
        return epochLengthBlocks(k - 1) * 600 * 4 / 5;
    }

    /// @dev Epoch k may be opened or skipped only once epoch k-1 is finished with: the 4/5 nominal gap has
    /// passed and, if k-1 was actually drawn, its claim window has closed. Claim windows therefore never
    /// overlap. That is what makes the settlement in _expire exact: the unclaimed amount is already final
    /// when epoch k opens, so no late claim can move the cap the draw was computed against, and epoch 0
    /// keeps its full two weeks instead of being cut short by epoch 1. A skipped epoch has no window.
    function _requirePrevSettled(uint256 k) internal view {
        if (k == 0) return;
        Epoch storage prev = epochs[k - 1];
        uint256 t = uint256(prev.openTime);
        if (block.timestamp < t + minGapBefore(k)) revert TooEarly();
        if (!prev.skipped && block.timestamp < t + CLAIM_DELAY + CLAIM_SECONDS) revert TooEarly();
    }

    /// @notice Epochs that were actually drawn (opened with a root) — what the founder's vesting follows.
    function epochsDrawn() external view returns (uint256) {
        return epochsOpened - epochsSkipped;
    }

    /// @dev halving schedule: epoch k gets half of what is still scheduled; the last epoch takes it all;
    ///      plus whatever was carried in (half of the previous epoch's unclaimed, half of a skipped epoch's amount).
    function _schedule(uint256 k) internal returns (uint256 cap, uint256 carriedIn) {
        uint256 base = (k == EPOCHS - 1) ? scheduledRemaining : scheduledRemaining / 2;
        scheduledRemaining -= base;
        carriedIn = carry;
        carry = 0;
        cap = base + carriedIn;
    }

    /// @dev the previous epoch's claim window closes now; its unclaimed coins are halved:
    ///      half is burned, half moves into this epoch's cap (a skipped previous epoch has nothing to expire).
    function _expire(uint256 k) internal returns (uint256 burnedNow) {
        if (k >= CLAIM_WINDOW) {
            Epoch storage x = epochs[k - CLAIM_WINDOW];
            uint256 expired = uint256(x.cap) - uint256(x.claimed);
            if (expired > 0) {
                burnedNow = expired / 2;
                carry += expired - burnedNow;
                burned += burnedNow;
                _burn(address(this), burnedNow);
            }
        }
    }

    // ------------------------------------------------------------------ claims
    function isClaimable(uint256 k) public view returns (bool) {
        Epoch storage e = epochs[k];
        uint256 opensAt = uint256(e.openTime) + CLAIM_DELAY;
        return !finalized && k < epochsOpened && k + CLAIM_WINDOW >= epochsOpened && !e.skipped
            && block.timestamp >= opensAt && block.timestamp < opensAt + CLAIM_SECONDS;
    }

    function leaf(uint256 k, address account, uint256 amount) public pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(k, account, amount))));
    }

    /// @notice Recipients claim their own coins. Nobody can claim on your behalf; nobody can push coins to you.
    ///         Claims open 24 h after the root is posted (time to recompute the draw) and stay open for two weeks,
    ///         or until the next epoch opens, whichever comes first.
    function claim(uint256 k, uint256 amount, bytes32[] calldata proof) external {
        if (!isClaimable(k)) revert WindowClosed();
        if (hasClaimed[k][msg.sender]) revert AlreadyClaimed();
        if (amount > MAX_PIECE) revert TooLarge();
        Epoch storage e = epochs[k];
        if (!MerkleProof.verifyCalldata(proof, e.root, leaf(k, msg.sender, amount))) revert BadProof();
        uint256 newClaimed = uint256(e.claimed) + amount;
        if (newClaimed > e.cap) revert CapExceeded();
        hasClaimed[k][msg.sender] = true;
        e.claimed = uint128(newClaimed);
        _transfer(address(this), msg.sender, amount);
        emit Claimed(k, msg.sender, amount);
    }

    /// @notice After the last epoch's claim window has passed, burn whatever was never claimed. Anyone may call.
    function finalize() external {
        if (finalized) revert AlreadyDone();
        if (epochsOpened != EPOCHS) revert BadEpoch();
        if (block.timestamp < uint256(epochs[EPOCHS - 1].openTime) + CLAIM_DELAY + CLAIM_SECONDS) revert TooEarly();
        _finalize(false);
    }

    /// @notice Dead-man's switch: if no epoch is opened or skipped for two years, anyone can burn the undistributed
    ///         pool (and never-seeded liquidity) so the supply stays honest. Claims for open epochs close at the same time.
    function abandon() external {
        if (finalized) revert AlreadyDone();
        if (block.timestamp < uint256(lastActivity) + ABANDON_AFTER) revert TooEarly();
        _finalize(true);
    }

    function _finalize(bool abandoned) internal {
        finalized = true;
        // finalize keeps an unseeded liquidity allocation (it can still be seeded); abandon burns everything
        uint256 keep = (poolSeeded || abandoned) ? 0 : LIQUIDITY;
        if (abandoned && !poolSeeded) poolSeeded = true; // nothing left to seed
        uint256 amount = balanceOf(address(this)) - keep;
        if (amount > 0) {
            burned += amount;
            _burn(address(this), amount);
        }
        emit Finalized(amount, abandoned);
    }

    // ------------------------------------------------------------------ liquidity
    /// @notice Seed the public pool exactly once: single-sided 2BTC position above the starting price,
    ///         zero ETH, position NFT burned. Tick/price math is done off-chain and passed in; the
    ///         amount checks below guarantee the position is in fact single-sided (no ETH leaves anyone).
    function seedPool(
        INonfungiblePositionManager npm,
        address weth,
        uint24 fee,
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper
    ) external onlyOperator {
        if (poolSeeded) revert AlreadyDone();
        if (fee != POOL_FEE) revert BadPoolParams();
        poolSeeded = true;
        lastActivity = uint64(block.timestamp);

        bool weAreToken0 = address(this) < weth;
        // the position must extend to the end of the price range on the 2BTC side (no hidden ceiling)
        if (weAreToken0 ? tickUpper != MAX_USABLE_TICK : tickLower != MIN_USABLE_TICK) revert BadPoolParams();
        (address token0, address token1) = weAreToken0 ? (address(this), weth) : (weth, address(this));
        pool = npm.createAndInitializePoolIfNecessary(token0, token1, fee, sqrtPriceX96);

        (uint256 tokenId, uint128 liquidity, uint256 used) =
            _mintSingleSided(npm, token0, token1, fee, tickLower, tickUpper, weAreToken0);
        positionTokenId = tokenId;
        npm.transferFrom(address(this), DEAD, tokenId);

        // rounding dust left from the liquidity allocation is burned, never kept
        uint256 dust = LIQUIDITY - used;
        if (dust > 0) {
            burned += dust;
            _burn(address(this), dust);
        }
        emit PoolSeeded(pool, tokenId, liquidity, used, dust);
    }

    function _mintSingleSided(
        INonfungiblePositionManager npm,
        address token0,
        address token1,
        uint24 fee,
        int24 tickLower,
        int24 tickUpper,
        bool weAreToken0
    ) internal returns (uint256 tokenId, uint128 liquidity, uint256 used) {
        _approve(address(this), address(npm), LIQUIDITY);
        uint256 minUsed = LIQUIDITY - LIQUIDITY / 1000; // allow v3 rounding dust only
        INonfungiblePositionManager.MintParams memory p = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            fee: fee,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: weAreToken0 ? LIQUIDITY : 0,
            amount1Desired: weAreToken0 ? 0 : LIQUIDITY,
            amount0Min: weAreToken0 ? minUsed : 0,
            amount1Min: weAreToken0 ? 0 : minUsed,
            recipient: address(this),
            deadline: block.timestamp
        });
        uint256 amount0;
        uint256 amount1;
        (tokenId, liquidity, amount0, amount1) = npm.mint(p);
        used = weAreToken0 ? amount0 : amount1;
        if (liquidity == 0 || used < minUsed) revert PoolNotReady();
        _approve(address(this), address(npm), 0);
    }

    // ------------------------------------------------------------------ views
    /// @notice What the cap of the next epoch would be if opened now: schedule + carry
    ///         (half of the previous epoch's currently-unclaimed coins, plus half of any skipped amount).
    function nextEpochCapPreview() external view returns (uint256 base, uint256 carriedIn) {
        uint256 k = epochsOpened;
        if (k >= EPOCHS) return (0, 0);
        base = (k == EPOCHS - 1) ? scheduledRemaining : scheduledRemaining / 2;
        carriedIn = carry;
        if (k >= CLAIM_WINDOW) {
            Epoch storage x = epochs[k - CLAIM_WINDOW];
            uint256 expired = uint256(x.cap) - uint256(x.claimed);
            carriedIn += expired - expired / 2;
        }
    }

    /// @notice Undistributed pool held by this contract (excludes the liquidity allocation until seeded).
    function poolBalance() external view returns (uint256) {
        return balanceOf(address(this)) - (poolSeeded ? 0 : LIQUIDITY);
    }
}
