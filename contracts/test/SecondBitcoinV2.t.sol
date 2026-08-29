// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SecondBitcoinV2} from "../src/SecondBitcoinV2.sol";
import {FounderVestingV2} from "../src/FounderVestingV2.sol";

/// Test harness: models EIP-4788 with a per-timestamp beacon + retention (a missed slot returns 0),
/// so the real seal()/retarget() recovery path is exercised, not bypassed.
contract V2Harness is SecondBitcoinV2 {
    bytes32 public beacon; // default value for any timestamp (happy path)
    mapping(uint64 => bool) public noBeacon; // simulate an expired/unavailable slot

    constructor(address committer_, address founder_) SecondBitcoinV2(committer_, founder_) {}

    function setBeacon(bytes32 b) external {
        beacon = b;
    }

    function setNoBeacon(uint64 ts) external {
        noBeacon[ts] = true;
    }

    function _beaconSeed(uint64 ts) internal view override returns (bytes32) {
        if (noBeacon[ts]) return bytes32(0);
        return beacon;
    }
}

contract SecondBitcoinV2Test is Test {
    V2Harness t;
    address committer = makeAddr("committer");
    address founder = makeAddr("founder");
    uint256 constant UNIT = 1e8;

    // eligible set of 4. With N == WINNERS0, the win band is the whole range → all four win.
    address a0 = address(uint160(0x1000));
    address a1 = address(uint160(0x1001));
    address a2 = address(uint160(0x1002));
    address a3 = address(uint160(0x1003));
    bytes32 root;
    uint256 N;
    mapping(address => bytes32[]) proof;

    function setUp() public {
        vm.warp(1_800_000_000);
        t = new V2Harness(committer, founder);
        N = t.WINNERS0();
        t.setBeacon(keccak256("beacon"));
        _buildTree();
    }

    // ----------------------------------------------------------------- merkle helpers
    function _leaf(address a) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(a))));
    }

    function _hp(bytes32 x, bytes32 y) internal pure returns (bytes32 v) {
        (bytes32 lo, bytes32 hi) = x < y ? (x, y) : (y, x);
        assembly {
            mstore(0, lo)
            mstore(0x20, hi)
            v := keccak256(0, 0x40)
        }
    }

    function _buildTree() internal {
        bytes32 l0 = _leaf(a0);
        bytes32 l1 = _leaf(a1);
        bytes32 l2 = _leaf(a2);
        bytes32 l3 = _leaf(a3);
        bytes32 n1 = _hp(l0, l1);
        bytes32 n2 = _hp(l2, l3);
        root = _hp(n1, n2);
        proof[a0] = _arr(l1, n2);
        proof[a1] = _arr(l0, n2);
        proof[a2] = _arr(l3, n1);
        proof[a3] = _arr(l2, n1);
    }

    function _arr(bytes32 x, bytes32 y) internal pure returns (bytes32[] memory p) {
        p = new bytes32[](2);
        p[0] = x;
        p[1] = y;
    }

    // ----------------------------------------------------------------- genesis flow
    function _genesis() internal {
        _genesisN(N);
    }

    function _genesisN(uint256 n) internal {
        vm.prank(committer);
        t.commitSet(root, n, uint64(block.timestamp + 1 hours));
        vm.warp(block.timestamp + 1 hours);
        t.seal();
    }

    // ================================================================= supply
    function test_SupplyAndExclusions() public view {
        assertEq(t.totalSupply(), 210_000 * UNIT);
        assertEq(t.balanceOf(address(t)), (188_790 + 21_000) * UNIT); // DRAW + LIQUIDITY
        assertEq(t.balanceOf(address(t.vesting())), 160 * UNIT);
        assertEq(t.balanceOf(founder), 50 * UNIT);
        assertEq(t.DRAW() + t.LIQUIDITY() + t.FOUNDER_LIQUID() + t.FOUNDER_LOCKED(), t.TOTAL_SUPPLY());
        assertTrue(t.excluded(address(t)));
        assertTrue(t.excluded(founder));
        assertTrue(t.excluded(address(t.vesting())));
        assertTrue(t.excluded(t.DEAD()));
    }

    // ================================================================= genesis
    function test_CommitAndSeal() public {
        vm.prank(committer);
        t.commitSet(root, N, uint64(block.timestamp + 1 hours));
        assertEq(t.eligibleCount(), N);
        // one-shot: setRoot is already set → re-commit reverts AlreadyDone
        vm.prank(committer);
        vm.expectRevert(SecondBitcoinV2.AlreadyDone.selector);
        t.commitSet(root, N, uint64(block.timestamp + 1 hours));

        vm.warp(block.timestamp + 1 hours);
        t.seal();
        assertTrue(t.genesisSeed() != bytes32(0));
        assertEq(t.startTime(), uint64(block.timestamp));
        assertEq(t.committer(), address(0)); // powerless after seal
    }

    function test_CommitOnlyCommitter() public {
        vm.expectRevert(SecondBitcoinV2.NotCommitter.selector);
        t.commitSet(root, N, uint64(block.timestamp + 1 hours));
    }

    function test_CommitBelowWinnersReverts() public {
        uint256 tooFew = t.WINNERS0() - 1; // hoist the getter out of the arg list (vm.expectRevert gotcha)
        uint64 ts = uint64(block.timestamp + 1 hours);
        vm.prank(committer);
        vm.expectRevert(SecondBitcoinV2.BadArg.selector);
        t.commitSet(root, tooFew, ts); // N < WINNERS0
    }

    function test_SealLeadTooFar() public {
        uint64 tooFar = uint64(block.timestamp + t.MAX_SEAL_LEAD() + 1); // hoist getter out of the arg list
        vm.prank(committer);
        vm.expectRevert(SecondBitcoinV2.BadArg.selector);
        t.commitSet(root, N, tooFar); // beyond MAX_SEAL_LEAD
    }

    function test_SealRecoveryNoBeaconThenReseal() public {
        uint64 ts1 = uint64(block.timestamp + 1 hours);
        vm.prank(committer);
        t.commitSet(root, N, ts1);
        t.setNoBeacon(ts1); // that slot's beacon never lands
        vm.warp(ts1 + 1);
        vm.expectRevert(bytes("no beacon"));
        t.seal();
        // retarget to a fresh slot (allowed: current beacon is missing) and seal there
        uint64 ts2 = uint64(block.timestamp + 30 minutes);
        vm.prank(committer);
        t.retarget(ts2);
        vm.warp(ts2 + 1);
        t.seal();
        assertTrue(t.genesisSeed() != bytes32(0));
    }

    function test_RetargetRequiresMissingBeacon() public {
        uint64 ts1 = uint64(block.timestamp + 1 hours);
        vm.prank(committer);
        t.commitSet(root, N, ts1);
        vm.warp(ts1 + 1); // beacon IS available at ts1 (harness returns default) → retarget must refuse
        vm.prank(committer);
        vm.expectRevert(SecondBitcoinV2.BadArg.selector);
        t.retarget(uint64(block.timestamp + 30 minutes));
    }

    function test_RetargetBeforeMissReverts() public {
        uint64 ts1 = uint64(block.timestamp + 1 hours);
        vm.prank(committer);
        t.commitSet(root, N, ts1);
        vm.prank(committer);
        vm.expectRevert(SecondBitcoinV2.BadArg.selector); // block.timestamp <= sealTimestamp
        t.retarget(uint64(block.timestamp + 90 minutes));
    }

    function test_RetargetPermissionlessAndUnlimited() public {
        uint64 ts = uint64(block.timestamp + 1 hours);
        vm.prank(committer);
        t.commitSet(root, N, ts);
        address keeper = makeAddr("randomkeeper"); // NOT the committer
        // re-aim many times (well past the old 4-cap), permissionlessly, whenever the slot is missed
        for (uint256 i = 0; i < 8; i++) {
            t.setNoBeacon(ts);
            vm.warp(uint256(ts) + 1);
            ts = uint64(block.timestamp + 30 minutes);
            vm.prank(keeper);
            t.retarget(ts);
        }
        // finally a good slot → anyone seals
        vm.warp(uint256(ts) + 1);
        t.seal();
        assertTrue(t.genesisSeed() != bytes32(0));
    }

    function test_HardeningPreSeal() public {
        // before seal: no winner check, draw not open, sweep locked
        vm.expectRevert(SecondBitcoinV2.NotSealed.selector);
        t.isDrawWinner(a0);
        assertFalse(t.drawOpen());
        vm.prank(a0);
        vm.expectRevert(SecondBitcoinV2.WindowClosed.selector);
        t.claimDraw(proof[a0]);
        vm.expectRevert(SecondBitcoinV2.NotSealed.selector);
        t.sweepDraw();
    }

    // ================================================================= the draw
    function test_DrawClaim() public {
        _genesis(); // N == WINNERS0 → all four win
        assertTrue(t.isDrawWinner(a0));
        assertTrue(t.drawOpen());
        uint256 piece = t.drawPiece(a0);
        assertGe(piece, 1 * UNIT);
        assertLe(piece, 50 * UNIT);

        vm.prank(a0);
        t.claimDraw(proof[a0]);
        assertEq(t.balanceOf(a0), piece);
        assertEq(t.drawClaimed(), piece);
        assertTrue(t.claimedDraw(a0));
    }

    function test_DrawGuards() public {
        _genesis();
        // excluded may not claim
        vm.prank(founder);
        vm.expectRevert(SecondBitcoinV2.Excluded.selector);
        t.claimDraw(proof[a0]);
        // wrong proof (address not in tree) → NotEligible
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(SecondBitcoinV2.NotEligible.selector);
        t.claimDraw(proof[a0]);
        // double claim → AlreadyClaimed
        vm.prank(a0);
        t.claimDraw(proof[a0]);
        vm.prank(a0);
        vm.expectRevert(SecondBitcoinV2.AlreadyClaimed.selector);
        t.claimDraw(proof[a0]);
    }

    function test_NonWinnerCannotClaim() public {
        _genesisN(100_000); // win rate = WINNERS0/N = 24% → at least one of the four loses
        address loser;
        address[4] memory as_ = [a0, a1, a2, a3];
        for (uint256 i = 0; i < 4; i++) {
            if (!t.isDrawWinner(as_[i])) {
                loser = as_[i];
                break;
            }
        }
        require(loser != address(0), "expected a non-winner in the sample");
        vm.prank(loser);
        vm.expectRevert(SecondBitcoinV2.NotWinner.selector);
        t.claimDraw(proof[loser]);
    }

    function test_PartialLottery() public {
        _genesisN(2 * t.WINNERS0()); // win rate = 50%
        uint256 winners;
        uint256 sample = 3000;
        for (uint256 i = 0; i < sample; i++) {
            if (t.isDrawWinner(address(uint160(0x20000 + i)))) winners += 1;
        }
        // ~50% ± tolerance
        assertGt(winners, (sample * 40) / 100);
        assertLt(winners, (sample * 60) / 100);
    }

    // ================================================================= claim window / sweep
    function test_ClaimWindowCloses() public {
        _genesis();
        // sweep is locked until the window closes
        vm.expectRevert(SecondBitcoinV2.WindowClosed.selector);
        t.sweepDraw();
        // just before close: still open
        vm.warp(uint256(t.startTime()) + t.CLAIM_WINDOW() - 1);
        assertTrue(t.drawOpen());
        // at close: shut
        vm.warp(uint256(t.startTime()) + t.CLAIM_WINDOW());
        assertFalse(t.drawOpen());
        vm.prank(a1);
        vm.expectRevert(SecondBitcoinV2.WindowClosed.selector);
        t.claimDraw(proof[a1]);
    }

    function test_SweepDrawBurns() public {
        _genesis();
        vm.prank(a0);
        t.claimDraw(proof[a0]);
        uint256 claimed = t.drawClaimed();
        uint256 supplyBefore = t.totalSupply();

        vm.warp(uint256(t.startTime()) + t.CLAIM_WINDOW());
        t.sweepDraw();
        assertEq(t.drawClaimed(), t.DRAW()); // marked swept
        assertEq(supplyBefore - t.totalSupply(), t.DRAW() - claimed); // unclaimed burned
        assertEq(t.burned(), t.DRAW() - claimed);
    }

    // ================================================================= founder vesting (time-based)
    function test_FounderVestingLinear() public {
        _genesis();
        FounderVestingV2 v = t.vesting();
        assertEq(v.vestedAmount(), 0); // nothing at seal
        vm.warp(uint256(t.startTime()) + 365 days); // half of 2 years
        assertApproxEqRel(v.vestedAmount(), 80 * UNIT, 1e16); // ~half of 160
        vm.warp(uint256(t.startTime()) + 730 days); // full
        assertEq(v.vestedAmount(), 160 * UNIT);
        v.release();
        assertEq(t.balanceOf(founder), (50 + 160) * UNIT);
    }
}
