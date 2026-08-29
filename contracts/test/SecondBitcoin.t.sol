// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {SecondBitcoin} from "../src/SecondBitcoin.sol";
import {FounderVesting} from "../src/FounderVesting.sol";
import {INonfungiblePositionManager} from "../src/interfaces/IUniswapV3.sol";
import {MockNPM} from "./MockNPM.sol";
import {Launcher} from "../src/Launcher.sol";

contract SecondBitcoinTest is Test {
    SecondBitcoin t;
    FounderVesting v;
    address operator = makeAddr("operator");
    address founder = makeAddr("founder");
    uint256 constant UNIT = 1e8;
    uint64 constant H0 = 910_000;
    bytes32 constant SNAP = keccak256("snapshot");
    bytes32 constant BTCH = bytes32(uint256(0xabc));
    address constant WETH = 0x4200000000000000000000000000000000000006;

    string fx;
    bytes32 fxRoot;
    uint256 fxCount;

    function setUp() public {
        vm.warp(1_700_000_000);
        vm.roll(50_000_000);
        t = new SecondBitcoin(operator, founder);
        v = t.vesting();
        fx = vm.readFile("test/fixtures/epoch0.json");
        fxRoot = vm.parseJsonBytes32(fx, ".root");
        fxCount = vm.parseJsonUint(fx, ".count");
    }

    // ---------------------------------------------------------------- helpers
    function epochCap(uint256 k) internal view returns (uint256 cap, uint256 claimed, bool skipped) {
        (,,,,,,, uint128 c, uint128 cl, bool s) = t.epochs(k);
        return (uint256(c), uint256(cl), s);
    }

    function winner(uint256 i) internal view returns (address a, uint256 amt, bytes32[] memory proof) {
        string memory p = string.concat(".winners[", vm.toString(i), "]");
        a = vm.parseJsonAddress(fx, string.concat(p, ".account"));
        amt = vm.parseJsonUint(fx, string.concat(p, ".amount"));
        proof = vm.parseJsonBytes32Array(fx, string.concat(p, ".proof"));
    }

    function hk(uint256 k) internal pure returns (uint64) {
        return H0 + uint64(2100 * k * (k + 1) / 2);
    }

    /// commit → wait the 2 h lead → open. For k > 0 both guards must clear: the 4/5 nominal gap
    /// (epoch k-1 lasts 2,100·k blocks) and epoch k-1's claim window, which may no longer overlap.
    function openK(uint256 k, bytes32 root) internal {
        if (k > 0) {
            uint256 gap = 2100 * k * 600;
            uint256 window = t.CLAIM_DELAY() + t.CLAIM_SECONDS() + 1;
            vm.warp(block.timestamp + (gap > window ? gap : window));
        }
        vm.startPrank(operator);
        t.commitSnapshot(k, SNAP, H0);
        vm.warp(block.timestamp + 2 hours);
        t.openEpoch(k, hk(k), BTCH, root, uint32(fxCount));
        vm.stopPrank();
    }

    function openAll(uint256 upTo) internal {
        for (uint256 k = t.epochsOpened(); k <= upTo; k++) {
            openK(k, fxRoot);
        }
    }

    function claimable() internal {
        vm.warp(block.timestamp + 24 hours + 1);
    }

    // ---------------------------------------------------------------- supply
    function test_SupplySplit() public view {
        assertEq(t.totalSupply(), 210_000 * UNIT);
        assertEq(t.decimals(), 8);
        assertEq(t.name(), "Second Bitcoin");
        assertEq(t.symbol(), "2BTC");
        assertEq(t.balanceOf(address(t)), (188_790 + 21_000) * UNIT);
        assertEq(t.balanceOf(address(v)), 160 * UNIT);
        assertEq(t.balanceOf(founder), 50 * UNIT);
        assertEq(t.poolBalance(), 188_790 * UNIT);
        assertEq(t.scheduledRemaining(), 188_790 * UNIT);
        assertEq(t.DISTRIBUTION() + t.LIQUIDITY() + t.FOUNDER_LOCKED() + t.FOUNDER_LIQUID(), t.TOTAL_SUPPLY());
        assertEq(t.genesisBlock(), 50_000_000, "snapshot block B of epoch 0 is the deployment block");
    }

    // ---------------------------------------------------------------- commit / open rules
    function test_CommitIsOneShotAndFixesH0() public {
        vm.startPrank(operator);
        vm.expectRevert(SecondBitcoin.NotCommitted.selector);
        t.openEpoch(0, H0, BTCH, fxRoot, 1);
        vm.expectRevert(SecondBitcoin.BadEpoch.selector);
        t.commitSnapshot(1, SNAP, 0);
        vm.expectRevert(bytes("zero H0"));
        t.commitSnapshot(0, SNAP, 0);
        t.commitSnapshot(0, SNAP, H0);
        assertEq(t.genesisBtcHeight(), H0, "H0 fixed at commit, before the block exists");
        // no second commit, no new H0, ever
        vm.expectRevert(SecondBitcoin.AlreadyCommitted.selector);
        t.commitSnapshot(0, keccak256("other"), H0 + 5);
        assertEq(t.genesisBtcHeight(), H0);
        // cannot open within 2 h of the commit, cannot open with another height
        vm.expectRevert(SecondBitcoin.TooEarly.selector);
        t.openEpoch(0, H0, BTCH, fxRoot, 1);
        vm.warp(block.timestamp + 2 hours);
        vm.expectRevert(SecondBitcoin.BadBtcHeight.selector);
        t.openEpoch(0, H0 + 1, BTCH, fxRoot, 1);
        t.openEpoch(0, H0, BTCH, fxRoot, 1);
        assertEq(t.epochsOpened(), 1);
        // epoch 1 must clear BOTH gaps: the 4/5 nominal gap and epoch 0's claim window, which may not overlap
        t.commitSnapshot(1, SNAP, 0);
        vm.warp(block.timestamp + 11 days);
        vm.expectRevert(SecondBitcoin.TooEarly.selector); // 4/5 of epoch 0's 2,100 blocks = 11.67 d
        t.openEpoch(1, H0 + 2100, BTCH, fxRoot, 1);
        vm.warp(block.timestamp + 1 days); // 4/5 gap cleared at 12 d — but epoch 0 is still claimable
        assertTrue(t.isClaimable(0), "epoch 0's window is still open at 12 days");
        vm.expectRevert(SecondBitcoin.TooEarly.selector);
        t.openEpoch(1, H0 + 2100, BTCH, fxRoot, 1);
        vm.warp(block.timestamp + 4 days); // past 24 h + two weeks from epoch 0's open (15.58 d)
        assertFalse(t.isClaimable(0), "epoch 0's window closes before epoch 1 opens: claims never overlap");
        vm.expectRevert(SecondBitcoin.BadBtcHeight.selector);
        t.openEpoch(1, H0 + 2099, BTCH, fxRoot, 1);
        t.openEpoch(1, H0 + 2100, BTCH, fxRoot, 1);
        assertEq(t.btcHeightOf(2), H0 + 6300, "epoch 2 seeded at H0 + 2,100 + 4,200");
        assertEq(t.btcHeightOf(32), H0 + 1_108_800);
        assertEq(t.epochLengthBlocks(32), 69_300);
        vm.stopPrank();
        vm.expectRevert(SecondBitcoin.NotOperator.selector);
        t.commitSnapshot(2, SNAP, 0);
    }

    function test_CommitDoesNotKeepAlive() public {
        openK(0, fxRoot);
        uint64 last = t.lastActivity();
        vm.warp(block.timestamp + 300 days);
        vm.prank(operator);
        t.commitSnapshot(1, SNAP, 0);
        assertEq(t.lastActivity(), last, "a commit alone does not reset the abandon timer");
        assertEq(t.ABANDON_AFTER(), 730 days, "dead-man switch exceeds the longest epoch (~481 days)");
    }

    function test_CapScheduleHalves_UnclaimedHalfBurnedHalfCarried() public {
        uint256 expectedRemaining = 188_790 * UNIT;
        uint256 burnedBefore;
        uint256 prevCap;
        for (uint256 k = 0; k < 33; k++) {
            openK(k, fxRoot);
            (uint256 cap,,) = epochCap(k);
            uint256 base = k == 32 ? expectedRemaining : expectedRemaining / 2;
            expectedRemaining -= base;
            // nobody claims in this test: the whole previous cap expires → half burned, half carried in
            uint256 carriedIn = k == 0 ? 0 : prevCap - prevCap / 2;
            assertEq(cap, base + carriedIn, "cap == schedule + half of previous unclaimed");
            if (k > 0) assertEq(t.burned() - burnedBefore, prevCap / 2, "half of previous unclaimed burned");
            burnedBefore = t.burned();
            prevCap = cap;
        }
        assertEq(t.scheduledRemaining(), 0);
        (uint256 c0,,) = epochCap(0);
        assertEq(c0, 94_395 * UNIT);
    }

    // ---------------------------------------------------------------- claims (cross-checked with Python merkle)
    function test_ClaimWithPythonProofs() public {
        openK(0, fxRoot);
        claimable();
        uint256 total;
        uint256 n;
        for (uint256 i = 0; i < fxCount; i += 7) {
            (address a, uint256 amt, bytes32[] memory proof) = winner(i);
            vm.prank(a);
            t.claim(0, amt, proof);
            assertEq(t.balanceOf(a), amt);
            assertTrue(amt >= 5 * UNIT && amt <= 50 * UNIT && amt % UNIT == 0, "piece rule 5..50 whole coins");
            total += amt;
            n++;
        }
        assertGt(n, 40);
        (uint256 cap, uint256 claimed,) = epochCap(0);
        assertEq(claimed, total);
        assertLt(vm.parseJsonUint(fx, ".total"), cap);
    }

    function test_ClaimDelayAndRejections() public {
        openK(0, fxRoot);
        (address a, uint256 amt, bytes32[] memory proof) = winner(3);
        // within 24 h of the root: closed (time to verify the draw)
        assertFalse(t.isClaimable(0));
        vm.prank(a);
        vm.expectRevert(SecondBitcoin.WindowClosed.selector);
        t.claim(0, amt, proof);
        claimable();
        assertTrue(t.isClaimable(0));
        vm.prank(a);
        vm.expectRevert(SecondBitcoin.BadProof.selector);
        t.claim(0, amt + 1, proof);
        vm.prank(makeAddr("thief"));
        vm.expectRevert(SecondBitcoin.BadProof.selector);
        t.claim(0, amt, proof);
        vm.prank(a);
        vm.expectRevert(SecondBitcoin.WindowClosed.selector);
        t.claim(1, amt, proof);
        vm.prank(a);
        t.claim(0, amt, proof);
        vm.prank(a);
        vm.expectRevert(SecondBitcoin.AlreadyClaimed.selector);
        t.claim(0, amt, proof);
    }

    function test_NoClaimAboveMaxPiece() public {
        // a rogue root paying 1,000 coins to one address is refused at claim time: pieces are at most 50
        address rogue = makeAddr("rogue");
        uint256 big = 1_000 * UNIT;
        bytes32 leaf = t.leaf(0, rogue, big);
        vm.startPrank(operator);
        t.commitSnapshot(0, SNAP, H0);
        vm.warp(block.timestamp + 2 hours);
        t.openEpoch(0, H0, BTCH, leaf, 1); // single-leaf tree: root == leaf
        vm.stopPrank();
        claimable();
        vm.prank(rogue);
        vm.expectRevert(SecondBitcoin.TooLarge.selector);
        t.claim(0, big, new bytes32[](0));
    }

    function test_ClaimGas() public {
        openK(0, fxRoot);
        claimable();
        (address a, uint256 amt, bytes32[] memory proof) = winner(7);
        vm.prank(a);
        uint256 g = gasleft();
        t.claim(0, amt, proof);
        g -= gasleft();
        console2.log("claim gas (proof depth %d): %d", proof.length, g);
        assertLt(g, 100_000);
    }

    function test_ClaimWindowIsTwoWeeks() public {
        openK(0, fxRoot);
        claimable();
        assertTrue(t.isClaimable(0));
        vm.warp(block.timestamp + t.CLAIM_SECONDS());
        assertFalse(t.isClaimable(0), "closed two weeks after it opened, even before the next epoch");
        (address a, uint256 amt, bytes32[] memory proof) = winner(2);
        vm.prank(a);
        vm.expectRevert(SecondBitcoin.WindowClosed.selector);
        t.claim(0, amt, proof);
    }

    function test_WindowClosesAtNextEpoch_HalfBurnHalfCarry() public {
        openK(0, fxRoot);
        claimable();
        (address a, uint256 amt, bytes32[] memory proof) = winner(0);
        assertTrue(t.isClaimable(0));
        vm.prank(a);
        t.claim(0, amt, proof);
        uint256 supplyBefore = t.totalSupply();
        (uint256 cap0, uint256 claimed0,) = epochCap(0);
        uint256 unclaimed = cap0 - claimed0;
        (uint256 pBase, uint256 pCarry) = t.nextEpochCapPreview();
        assertEq(pCarry, unclaimed - unclaimed / 2, "preview shows half of the unclaimed as carry");
        openK(1, fxRoot);
        assertFalse(t.isClaimable(0), "window closed when the next epoch opened");
        assertEq(supplyBefore - t.totalSupply(), unclaimed / 2, "half of epoch 0's unclaimed burned");
        (uint256 cap1,,) = epochCap(1);
        assertEq(cap1, pBase + pCarry, "epoch 1 cap = schedule + half of epoch 0's unclaimed");
        (address b, uint256 amtb, bytes32[] memory proofb) = winner(1);
        vm.prank(b);
        vm.expectRevert(SecondBitcoin.WindowClosed.selector);
        t.claim(0, amtb, proofb);
    }

    // ---------------------------------------------------------------- skip
    function test_SkipEpochHalvesAmountAndDoesNotVest() public {
        // skip before the genesis commit is refused: the seed schedule can never fall back to H0 = 0
        vm.prank(operator);
        vm.expectRevert(SecondBitcoin.NotCommitted.selector);
        t.skipEpoch(0);
        openK(0, fxRoot);
        vm.warp(block.timestamp + 2100 * 600 + 24 hours + 1); // epoch 0's claim window must close first
        uint256 supplyBefore = t.totalSupply();
        (uint256 cap0,,) = epochCap(0);
        vm.prank(operator);
        t.skipEpoch(1);
        assertEq(t.epochsOpened(), 2);
        assertEq(t.epochsSkipped(), 1);
        assertEq(t.epochsDrawn(), 1);
        (,, bool skipped) = epochCap(1);
        assertTrue(skipped);
        assertFalse(t.isClaimable(1));
        assertEq(v.releasable(), 0, "a skipped epoch does not unlock founder coins");
        // skip(1): epoch 0's unclaimed halved (half burned) + epoch 1's amount (schedule + carried half) halved again
        uint256 carriedFrom0 = cap0 - cap0 / 2;
        uint256 amount1 = 47_197_50000000 + carriedFrom0;
        assertEq(supplyBefore - t.totalSupply(), cap0 / 2 + amount1 / 2, "a skip burns half: never a free re-roll");
        openK(2, fxRoot);
        (uint256 cap2,,) = epochCap(2);
        assertEq(cap2, 23_598_75000000 + (amount1 - amount1 / 2), "epoch 2 = schedule + half of the skipped amount");
        assertEq(v.releasable(), 80 * UNIT, "first drawn halving unlocks 50%");
    }

    function test_LauncherDeploysAndSeedsInOneTransaction() public {
        MockNPM npm = new MockNPM();
        Launcher.PoolParams memory p = Launcher.PoolParams({
            sqrtPriceX96IfToken0: 1 << 96, tickLowerIfToken0: 200, tickUpperIfToken0: 887_200,
            sqrtPriceX96IfToken1: 1 << 96, tickLowerIfToken1: -887_200, tickUpperIfToken1: -200
        });
        Launcher l = new Launcher(operator, founder, INonfungiblePositionManager(address(npm)), WETH, p);
        SecondBitcoin tk = l.token();
        assertTrue(tk.poolSeeded(), "seeded in the genesis transaction");
        assertEq(tk.operator(), operator, "operator handed over");
        assertEq(tk.founder(), founder);
        assertEq(tk.genesisBlock(), uint64(block.number));
        assertEq(npm.ownerOf(tk.positionTokenId()), tk.DEAD());
        assertEq(tk.balanceOf(address(tk)), 188_790 * UNIT);
        assertEq(tk.balanceOf(founder), 50 * UNIT);
        vm.prank(address(l));
        vm.expectRevert(SecondBitcoin.NotOperator.selector);
        tk.commitSnapshot(0, SNAP, H0); // the launcher keeps no power
    }

    // ---------------------------------------------------------------- vesting
    function test_VestingOneHalvingBehind() public {
        assertEq(v.releasable(), 0);
        openK(0, fxRoot);
        assertEq(v.releasable(), 0, "genesis unlocks nothing");
        vm.expectRevert(bytes("nothing vested"));
        v.release();
        openAll(1);
        assertEq(v.releasable(), 80 * UNIT, "50% at 1st halving");
        vm.prank(makeAddr("anyone"));
        v.release();
        assertEq(t.balanceOf(founder), 50 * UNIT + 80 * UNIT);
        openAll(2);
        assertEq(v.releasable(), 40 * UNIT, "+25% at 2nd");
        openAll(32);
        v.release();
        assertEq(t.balanceOf(address(v)), 0, "all unlocked at last halving");
        assertEq(t.balanceOf(founder), 210 * UNIT);
    }

    // ---------------------------------------------------------------- finalize / abandon
    function test_FinalizeBurnsUnclaimed() public {
        openAll(31);
        string memory fx32 = vm.readFile("test/fixtures/epoch32.json");
        vm.warp(block.timestamp + 2100 * 32 * 600);
        vm.startPrank(operator);
        t.commitSnapshot(32, SNAP, 0);
        vm.warp(block.timestamp + 2 hours);
        t.openEpoch(32, hk(32), BTCH, vm.parseJsonBytes32(fx32, ".root"), 1);
        vm.stopPrank();
        claimable();
        address a = vm.parseJsonAddress(fx32, ".winners[0].account");
        uint256 amt = vm.parseJsonUint(fx32, ".winners[0].amount");
        bytes32[] memory proof = vm.parseJsonBytes32Array(fx32, ".winners[0].proof");
        assertEq(amt, 4390);
        vm.prank(a);
        t.claim(32, amt, proof);
        vm.expectRevert(SecondBitcoin.TooEarly.selector);
        t.finalize();
        vm.warp(block.timestamp + t.CLAIM_DELAY() + t.CLAIM_SECONDS());
        t.finalize();
        assertTrue(t.finalized());
        assertEq(t.burned(), 188_790 * UNIT - amt, "everything unclaimed ends up burned (half at each window, the rest at the end)");
        assertEq(t.totalSupply(), 210_000 * UNIT - (188_790 * UNIT - amt));
        assertEq(t.poolBalance(), 0);
        assertEq(t.balanceOf(address(t)), 21_000 * UNIT, "unseeded liquidity kept by finalize");
        vm.expectRevert(SecondBitcoin.AlreadyDone.selector);
        t.finalize();
    }

    function test_FinalizeNeedsAllEpochs() public {
        openAll(5);
        vm.warp(block.timestamp + 400 days);
        vm.expectRevert(SecondBitcoin.BadEpoch.selector);
        t.finalize();
    }

    function test_AbandonBurnsEverythingAfterTwoYears() public {
        openAll(2);
        vm.expectRevert(SecondBitcoin.TooEarly.selector);
        t.abandon();
        vm.warp(block.timestamp + 600 days); // longer than any epoch but shorter than the dead-man's two years
        vm.expectRevert(SecondBitcoin.TooEarly.selector);
        t.abandon();
        vm.warp(block.timestamp + 130 days);
        t.abandon();
        assertTrue(t.finalized());
        assertEq(t.balanceOf(address(t)), 0, "abandon burns the pool and the unseeded liquidity allocation");
        assertEq(t.totalSupply(), 210 * UNIT, "only founder coins remain");
        vm.prank(operator);
        vm.expectRevert(SecondBitcoin.BadEpoch.selector);
        t.commitSnapshot(3, SNAP, 0);
    }

    // ---------------------------------------------------------------- operator powers (and their limits)
    function test_OperatorCanOnlyRotate() public {
        address next = makeAddr("next");
        vm.prank(operator);
        t.setOperator(next);
        assertEq(t.operator(), next);
        vm.prank(operator);
        vm.expectRevert(SecondBitcoin.NotOperator.selector);
        t.commitSnapshot(0, SNAP, H0);
        assertEq(t.allowance(address(t), next), 0);
        assertEq(t.allowance(address(t), operator), 0);
    }

    // ---------------------------------------------------------------- liquidity seeding
    function test_SeedPoolSingleSidedBurnsNFTAndDust() public {
        MockNPM npm = new MockNPM();
        bool weAreToken0 = address(t) < WETH;
        int24 lower = weAreToken0 ? int24(200) : int24(-887_200);
        int24 upper = weAreToken0 ? int24(887_200) : int24(-200);
        vm.prank(operator);
        t.seedPool(INonfungiblePositionManager(address(npm)), WETH, 10_000, 1 << 96, lower, upper);
        assertTrue(t.poolSeeded());
        assertEq(npm.ownerOf(t.positionTokenId()), t.DEAD());
        assertEq(t.balanceOf(address(npm)), 21_000 * UNIT - 1);
        assertEq(t.burned(), 1, "rounding dust burned");
        assertEq(t.balanceOf(address(t)), 188_790 * UNIT);
        assertEq(t.allowance(address(t), address(npm)), 0);
        assertEq(npm.lastAmount0Desired(), weAreToken0 ? 21_000 * UNIT : 0);
        assertEq(npm.lastAmount1Desired(), weAreToken0 ? 0 : 21_000 * UNIT);
        vm.prank(operator);
        vm.expectRevert(SecondBitcoin.AlreadyDone.selector);
        t.seedPool(INonfungiblePositionManager(address(npm)), WETH, 10_000, 1 << 96, lower, upper);
    }

    function test_SeedPoolEnforcesTierAndFullRange() public {
        MockNPM npm = new MockNPM();
        bool weAreToken0 = address(t) < WETH;
        int24 lower = weAreToken0 ? int24(200) : int24(-887_200);
        int24 upper = weAreToken0 ? int24(887_200) : int24(-200);
        vm.prank(operator);
        vm.expectRevert(SecondBitcoin.BadPoolParams.selector);
        t.seedPool(INonfungiblePositionManager(address(npm)), WETH, 3_000, 1 << 96, lower, upper);
        // a hidden ceiling / floor is refused
        vm.prank(operator);
        vm.expectRevert(SecondBitcoin.BadPoolParams.selector);
        t.seedPool(INonfungiblePositionManager(address(npm)), WETH, 10_000, 1 << 96, weAreToken0 ? int24(200) : int24(-500_000), weAreToken0 ? int24(500_000) : int24(-200));
        assertFalse(t.poolSeeded());
    }

    function test_SeedPoolRevertsIfNotSingleSided() public {
        MockNPM npm = new MockNPM();
        npm.setTwoSided(true);
        bool weAreToken0 = address(t) < WETH;
        vm.prank(operator);
        vm.expectRevert(bytes("Price slippage check"));
        t.seedPool(INonfungiblePositionManager(address(npm)), WETH, 10_000, 1 << 96, weAreToken0 ? int24(-200) : int24(-887_200), weAreToken0 ? int24(887_200) : int24(200));
        assertFalse(t.poolSeeded(), "state rolled back");
    }
}
