// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SecondBitcoinV2} from "../src/SecondBitcoinV2.sol";

contract V2Harness2 is SecondBitcoinV2 {
    bytes32 public beacon;

    constructor(address c, address f) SecondBitcoinV2(c, f) {}

    function setBeacon(bytes32 b) external {
        beacon = b;
    }

    function _beaconSeed(uint64) internal view override returns (bytes32) {
        return beacon;
    }
}

/// Fuzzed action driver. Each public function is called with random args by the invariant runner.
contract Handler is Test {
    V2Harness2 public t;
    address[4] public actors;
    mapping(address => bytes32[]) internal proofs;

    constructor(V2Harness2 _t, address[4] memory _actors) {
        t = _t;
        actors = _actors;
        _buildProofs();
    }

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

    function root() public view returns (bytes32) {
        return _hp(_hp(_leaf(actors[0]), _leaf(actors[1])), _hp(_leaf(actors[2]), _leaf(actors[3])));
    }

    function _buildProofs() internal {
        bytes32 n1 = _hp(_leaf(actors[0]), _leaf(actors[1]));
        bytes32 n2 = _hp(_leaf(actors[2]), _leaf(actors[3]));
        proofs[actors[0]] = _p(_leaf(actors[1]), n2);
        proofs[actors[1]] = _p(_leaf(actors[0]), n2);
        proofs[actors[2]] = _p(_leaf(actors[3]), n1);
        proofs[actors[3]] = _p(_leaf(actors[2]), n1);
    }

    function _p(bytes32 x, bytes32 y) internal pure returns (bytes32[] memory a) {
        a = new bytes32[](2);
        a[0] = x;
        a[1] = y;
    }

    // ------------------------------------------------------------- fuzzed actions
    function claimDraw(uint256 i) public {
        address a = actors[i % 4];
        if (t.genesisSeed() == bytes32(0) || t.claimedDraw(a) || !t.drawOpen() || !t.isDrawWinner(a)) return;
        vm.prank(a);
        t.claimDraw(proofs[a]);
    }

    function move(uint256 i, uint256 j, uint256 amt) public {
        address from = actors[i % 4];
        address to = actors[j % 4];
        uint256 bal = t.balanceOf(from);
        if (bal == 0) return;
        amt = bound(amt, 0, bal);
        vm.prank(from);
        t.transfer(to, amt);
    }

    function warp(uint256 s) public {
        vm.warp(block.timestamp + bound(s, 1, 40 days));
    }

    function sweepDraw() public {
        if (t.genesisSeed() == bytes32(0)) return;
        try t.sweepDraw() {} catch {}
    }
}

contract SecondBitcoinV2InvariantTest is Test {
    V2Harness2 t;
    Handler h;
    address founder = makeAddr("founder2");

    function setUp() public {
        vm.warp(1_800_000_000);
        t = new V2Harness2(address(this), founder);
        t.setBeacon(keccak256("beacon2"));

        address[4] memory actors =
            [address(uint160(0x2100)), address(uint160(0x2101)), address(uint160(0x2102)), address(uint160(0x2103))];
        h = new Handler(t, actors);

        // genesis with N = WINNERS0 so all four actors win the draw
        t.commitSet(h.root(), t.WINNERS0(), uint64(block.timestamp + 1 hours));
        vm.warp(block.timestamp + 1 hours);
        t.seal();

        targetContract(address(h));
    }

    // the draw bucket never overspends
    function invariant_drawBucket() public view {
        assertLe(t.drawClaimed(), t.DRAW(), "draw bucket");
    }

    // solvency: the contract always holds exactly the undistributed draw budget + the (unseeded) liquidity.
    // sweepDraw moves the unclaimed remainder to `burned` and sets drawClaimed = DRAW, so this stays exact.
    function invariant_solvency() public view {
        assertEq(t.balanceOf(address(t)), (t.DRAW() - t.drawClaimed()) + t.LIQUIDITY(), "contract holds exactly the unclaimed budget + liquidity");
    }

    // supply is conserved: only sweepDraw burns, tracked in `burned`.
    function invariant_supplyConservation() public view {
        assertEq(t.totalSupply(), t.TOTAL_SUPPLY() - t.burned(), "totalSupply == 210,000 - burned");
    }
}
