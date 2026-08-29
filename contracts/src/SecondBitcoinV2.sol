// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {FounderVestingV2} from "./FounderVestingV2.sol";
import {INonfungiblePositionManager} from "./interfaces/IUniswapV3.sol";

interface IUniV3PoolSlot0 {
    function slot0() external view returns (uint160 sqrtPriceX96, int24, uint16, uint16, uint16, uint8, bool);
}

/// @title Second Bitcoin (2BTC) — one-shot broad lottery
/// @notice Supply 210,000 (8 decimals), minted once at genesis, never again. One distribution mechanism:
///   a single broad, self-verifying lottery of 188,790 coins (89.9%) to a frozen genesis list, decided by
///   one sealed seed. Plus liquidity 21,000 (10%) single-sided, and founder 210 (0.1% = 50 liquid + 160
///   vesting linearly over 2 years). There is no holder distribution, no epochs, no time-weighting.
///
///   After the genesis seal, no operator ever acts: winning and the piece are pure self-verified functions
///   of the sealed seed and the claimant's address; unclaimed coins are burned permissionlessly.
///
/// Chain/param items to finalize before deploy:
///   (1) _beaconSeed — verify the EIP-4788 call semantics on Base MAINNET (parity/retention), not just a fork.
///   (2) WINNERS0 / piece skew — finalize after the eligible-count (N) snapshot with the strengthened criteria.
contract SecondBitcoinV2 is ERC20, ReentrancyGuard {

    // Base chain constants. Verified on a Base fork: factory + init hash reproduce the real pool address,
    // NPM present (test/ForkVerify.t.sol).
    address internal constant WETH_BASE = 0x4200000000000000000000000000000000000006;
    address internal constant UNIV3_FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
    address internal constant UNIV3_NPM = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1; // NonfungiblePositionManager
    bytes32 internal constant UNIV3_POOL_INIT_HASH =
        0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;

    // Seal recovery: the seed target must be near-future (so its beacon is still retained at seal time).
    // A missed target can be re-aimed permissionlessly and without limit — grinding is impossible because
    // retarget is refused whenever a valid beacon already exists (see retarget), so the only thing an
    // unlimited, open recovery can do is keep the ~90% DRAW from bricking on a run of missed slots.
    uint256 public constant MAX_SEAL_LEAD = 2 hours;

    // ------------------------------------------------------------------ supply (sums to 210,000)
    uint256 public constant UNIT = 1e8;
    uint256 public constant TOTAL_SUPPLY = 210_000 * UNIT;
    uint256 public constant DRAW = 188_790 * UNIT; // one-shot broad lottery (89.9% = old 70% + 19.9%)
    uint256 public constant LIQUIDITY = 21_000 * UNIT; // single-sided pool (10%)
    uint256 public constant FOUNDER_LIQUID = 50 * UNIT;
    uint256 public constant FOUNDER_LOCKED = 160 * UNIT; // +50 = 210 = 0.1%

    // ------------------------------------------------------------------ draw params
    uint256 public constant CLAIM_WINDOW = 180 days; // one-shot claim window from seal; then unclaimed burns

    // TODO(2): finalize after the N snapshot. WINNERS0 = target winners; with skewed mean ~7 and a safety
    // margin, WINNERS0 * E[piece] must stay below DRAW (the drawClaimed backstop is the hard guard).
    uint256 public constant WINNERS0 = 24_000; // provisional (avg ~7 → ~168k, a margin under 188,790)

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint24 public constant POOL_FEE = 10_000;
    int24 public constant MIN_USABLE_TICK = -887_200;
    int24 public constant MAX_USABLE_TICK = 887_200;

    // ------------------------------------------------------------------ roles / genesis commitment
    address public founder;
    address public committer; // may commit the eligible set once, then cleared
    address public immutable deployer; // whoever deployed (e.g. an atomic Launcher); may seed the pool once
    FounderVestingV2 public immutable vesting;
    uint64 public immutable genesisBlock;

    bytes32 public setRoot; // Merkle root of the eligible-address set (bound with N)
    uint256 public eligibleCount; // N
    uint64 public sealTimestamp; // beacon slot that seeds the lottery
    bytes32 public genesisSeed; // 0 until seal()
    uint64 public startTime; // T0, set at seal; the claim window is [startTime, startTime + CLAIM_WINDOW)

    // ------------------------------------------------------------------ draw accounting
    uint256 public drawClaimed; // <= DRAW (hard backstop)
    mapping(address => bool) public claimedDraw;

    // System addresses that can never win/claim (belt-and-suspenders; they are not in the eligible list).
    mapping(address => bool) public excluded;

    uint256 public burned;

    // ------------------------------------------------------------------ liquidity
    bool public poolSeeded;
    address public pool;
    uint256 public positionTokenId;

    event SetCommitted(bytes32 setRoot, uint256 eligibleCount, uint64 sealTimestamp);
    event Sealed(bytes32 genesisSeed, uint64 startTime);
    event DrawClaimed(address indexed account, uint256 amount);
    event Swept(uint256 burnedAmount);
    event PoolSeeded(address pool, uint256 tokenId, uint128 liquidity, uint256 amountUsed, uint256 dustBurned);

    error NotCommitter();
    error NotFounder();
    error AlreadyDone();
    error NotCommitted();
    error AlreadySealed();
    error NotSealed();
    error BadArg();
    error Excluded();
    error NotEligible();
    error NotWinner();
    error WindowClosed();
    error AlreadyClaimed();
    error CapExceeded();
    error PoolNotReady();
    error BadPoolParams();

    constructor(address committer_, address founder_) ERC20("Second Bitcoin", "2BTC") {
        require(committer_ != address(0) && founder_ != address(0), "zero");
        committer = committer_;
        deployer = msg.sender;
        founder = founder_;
        vesting = new FounderVestingV2(address(this), founder_);

        // system addresses excluded from winning (they are never in the eligible list anyway).
        excluded[address(0)] = true;
        excluded[address(this)] = true;
        excluded[address(vesting)] = true;
        excluded[founder_] = true;
        excluded[DEAD] = true;
        excluded[_computePool()] = true;

        _mint(address(this), DRAW + LIQUIDITY); // 209,790
        _mint(address(vesting), FOUNDER_LOCKED); // 160
        _mint(founder_, FOUNDER_LIQUID); // 50
        assert(totalSupply() == TOTAL_SUPPLY); // 210,000

        genesisBlock = uint64(block.number);
    }

    function decimals() public pure override returns (uint8) {
        return 8;
    }

    /// @notice The deterministic pool address this contract expects (excluded at genesis).
    function computedPool() external view returns (address) {
        return _computePool();
    }

    /// @dev Deterministic Uniswap v3 pool address for (this, WETH, 1% fee) on Base.
    function _computePool() internal view returns (address) {
        (address t0, address t1) =
            address(this) < WETH_BASE ? (address(this), WETH_BASE) : (WETH_BASE, address(this));
        bytes32 key = keccak256(abi.encode(t0, t1, POOL_FEE));
        return address(
            uint160(uint256(keccak256(abi.encodePacked(hex"ff", UNIV3_FACTORY, key, UNIV3_POOL_INIT_HASH))))
        );
    }

    // ================================================================== genesis (only human steps)

    function commitSet(bytes32 setRoot_, uint256 eligibleCount_, uint64 sealTimestamp_) external {
        if (msg.sender != committer) revert NotCommitter();
        if (setRoot != bytes32(0)) revert AlreadyDone();
        if (setRoot_ == bytes32(0) || eligibleCount_ < WINNERS0) revert BadArg();
        if (sealTimestamp_ <= block.timestamp || sealTimestamp_ > block.timestamp + MAX_SEAL_LEAD) revert BadArg();
        setRoot = setRoot_;
        eligibleCount = eligibleCount_;
        sealTimestamp = sealTimestamp_;
        // committer is retained until seal() succeeds so a missed beacon window can be re-aimed (retarget).
        emit SetCommitted(setRoot_, eligibleCount_, sealTimestamp_);
    }

    /// @notice Re-aim the seed target ONLY if the current target's beacon is unavailable (missed window).
    ///         Permissionless and unlimited: the list (setRoot, N) is untouched, so this cannot change who is
    ///         eligible, and because retarget is refused whenever a valid beacon already exists, nobody can
    ///         discard an unfavourable seed to fish for a better one (no best-of-N grind). It is pure liveness
    ///         recovery, so it does not depend on the committer key surviving to seal.
    function retarget(uint64 newSealTimestamp) external {
        if (setRoot == bytes32(0)) revert NotCommitted();
        if (genesisSeed != bytes32(0)) revert AlreadySealed();
        if (block.timestamp <= sealTimestamp) revert BadArg(); // only after the current target is missed
        if (_beaconSeed(sealTimestamp) != bytes32(0)) revert BadArg(); // a valid beacon exists → seal, don't re-roll
        if (newSealTimestamp <= block.timestamp || newSealTimestamp > block.timestamp + MAX_SEAL_LEAD) {
            revert BadArg();
        }
        sealTimestamp = newSealTimestamp;
        emit SetCommitted(setRoot, eligibleCount, newSealTimestamp);
    }

    /// @notice Permissionless: once sealTimestamp passes (and its beacon is retained), anyone locks the seed.
    function seal() external {
        if (setRoot == bytes32(0)) revert NotCommitted();
        if (genesisSeed != bytes32(0)) revert AlreadySealed();
        if (block.timestamp < sealTimestamp) revert BadArg();
        bytes32 s = _beaconSeed(sealTimestamp);
        require(s != bytes32(0), "no beacon"); // beacon expired → retarget() and try a new slot
        genesisSeed = keccak256(abi.encodePacked("2BTC-seed", s, setRoot, eligibleCount));
        startTime = uint64(block.timestamp);
        committer = address(0); // sealed: the committer is now powerless
        emit Sealed(genesisSeed, startTime);
    }

    /// @dev EIP-4788 beacon-roots ring buffer (8191 slots ≈ 4.5 h retention on Base's 2 s blocks — bounded
    ///      by MAX_SEAL_LEAD and recoverable via retarget). On OP Stack this predeploy holds the L1 beacon
    ///      root, so the seed is L1 consensus randomness fixed at commit time (ungrindable by seal timing).
    ///      Verified on a Base fork (test/ForkVerify.t.sol). NOTE(1): confirm exact-timestamp match semantics
    ///      and block-timestamp parity on Base MAINNET before deploy — a target with no matching block reverts.
    address internal constant BEACON_ROOTS = 0x000F3df6D732807Ef1319fB7B8bB8522d0Beac02;

    function _beaconSeed(uint64 ts) internal view virtual returns (bytes32) {
        (bool ok, bytes memory out) = BEACON_ROOTS.staticcall(abi.encode(uint256(ts)));
        if (!ok || out.length != 32) return bytes32(0); // not available → seal() reverts, never a wrong seed
        return abi.decode(out, (bytes32));
    }

    // ================================================================== the broad draw

    /// @notice Whether `account` won, from the sealed seed and committed set (pure self-verify).
    function isDrawWinner(address account) public view returns (bool) {
        if (genesisSeed == bytes32(0)) revert NotSealed();
        if (excluded[account]) return false;
        uint256 h = uint256(keccak256(abi.encodePacked(genesisSeed, account)));
        uint256 r = Math.mulDiv(h, eligibleCount, type(uint256).max); // uniform in [0, N)
        return r < WINNERS0;
    }

    /// @notice A winner's piece, in sat2. Right-skewed to a low mean (most small, rare large).
    ///         TODO(2): finalize the skew (published probability table) with the target mean after N.
    function drawPiece(address account) public view returns (uint256) {
        uint256 h = uint256(keccak256(abi.encodePacked(genesisSeed, account)));
        uint256 u = uint256(keccak256(abi.encodePacked(h, "piece"))) % 10_000; // 0..9999
        // 1 + 49 * (u/9999)^7  → integer in [1,50] (u=9999 reaches 50), mean ≈ 7
        uint256 skew = (u ** 7 * 49) / (uint256(9_999) ** 7);
        uint256 coins = 1 + skew;
        if (coins > 50) coins = 50; // defensive clamp (formula already bounds at 50)
        return coins * UNIT;
    }

    function drawOpen() public view returns (bool) {
        if (genesisSeed == bytes32(0)) return false;
        return block.timestamp >= uint256(startTime) && block.timestamp < uint256(startTime) + CLAIM_WINDOW;
    }

    /// @notice Claim your win. `proof` proves membership in the committed eligible set.
    function claimDraw(bytes32[] calldata proof) external {
        address a = msg.sender;
        if (excluded[a]) revert Excluded();
        if (claimedDraw[a]) revert AlreadyClaimed();
        if (!drawOpen()) revert WindowClosed();
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(a))));
        if (!MerkleProof.verifyCalldata(proof, setRoot, leaf)) revert NotEligible();
        if (!isDrawWinner(a)) revert NotWinner();

        uint256 amount = drawPiece(a);
        uint256 nc = drawClaimed + amount;
        if (nc > DRAW) revert CapExceeded(); // hard backstop: total distributed never exceeds the budget
        drawClaimed = nc;
        claimedDraw[a] = true;
        _transfer(address(this), a, amount);
        emit DrawClaimed(a, amount);
    }

    // ================================================================== unclaimed → burn

    /// @notice After the claim window, burn whatever the lottery never distributed. Permissionless.
    function sweepDraw() external {
        if (genesisSeed == bytes32(0)) revert NotSealed();
        if (block.timestamp < uint256(startTime) + CLAIM_WINDOW) revert WindowClosed();
        uint256 toBurn = DRAW - drawClaimed;
        if (toBurn == 0) return;
        drawClaimed = DRAW; // mark swept
        burned += toBurn;
        _burn(address(this), toBurn);
        emit Swept(toBurn);
    }

    // ================================================================== helpers / liquidity

    /// @notice Seed the single-sided pool once. npm/weth/fee are fixed Base constants (no arbitrary external
    ///         contract is trusted), and the created pool must equal the constructor-excluded address.
    function seedPool(uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper) external nonReentrant {
        if (msg.sender != founder && msg.sender != deployer) revert NotFounder();
        if (poolSeeded) revert AlreadyDone();
        poolSeeded = true;

        INonfungiblePositionManager npm = INonfungiblePositionManager(UNIV3_NPM);
        bool weAreToken0 = address(this) < WETH_BASE;
        if (weAreToken0 ? tickUpper != MAX_USABLE_TICK : tickLower != MIN_USABLE_TICK) revert BadPoolParams();
        (address token0, address token1) =
            weAreToken0 ? (address(this), WETH_BASE) : (WETH_BASE, address(this));
        pool = npm.createAndInitializePoolIfNecessary(token0, token1, POOL_FEE, sqrtPriceX96);
        if (pool != _computePool()) revert BadPoolParams(); // must equal the address excluded at genesis
        // front-run defense: if someone pre-created & initialised the pool, createAndInitialize... silently
        // ignores our price. Refuse rather than inherit an attacker's price. (Still prefer an atomic
        // deploy+seed launcher so no block exists between deployment and seeding — see the launch runbook.)
        (uint160 initialized,,,,,,) = IUniV3PoolSlot0(pool).slot0();
        if (initialized != sqrtPriceX96) revert BadPoolParams();

        (uint256 tokenId, uint128 liquidity, uint256 used) =
            _mintSingleSided(npm, token0, token1, POOL_FEE, tickLower, tickUpper, weAreToken0);
        positionTokenId = tokenId;
        npm.transferFrom(address(this), DEAD, tokenId);

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
        uint256 minUsed = LIQUIDITY - LIQUIDITY / 1000;
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
}
