// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SecondBitcoinV2} from "../src/SecondBitcoinV2.sol";
import {INonfungiblePositionManager} from "../src/interfaces/IUniswapV3.sol";

contract V2H is SecondBitcoinV2 {
    constructor(address c, address f) SecondBitcoinV2(c, f) {}

    function _beaconSeed(uint64) internal pure override returns (bytes32) {
        return keccak256("seed");
    }
}

/// slot0 stand-in placed (via etch) at the pool address; returns a settable price.
contract MockPool {
    uint160 public price;

    function setPrice(uint160 p) external {
        price = p;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (price, 0, 0, 0, 0, 0, true);
    }
}

/// NonfungiblePositionManager stand-in (etched at UNIV3_NPM). Forwards the pulled tokens to the pool
/// (excluded), mints a fake NFT, mirrors single-sided behaviour.
contract MockNPMV2 {
    address public poolAddr;
    mapping(uint256 => address) public ownerOf;
    uint256 public nextId = 1;

    function setPool(address p) external {
        poolAddr = p;
    }

    function createAndInitializePoolIfNecessary(address, address, uint24, uint160)
        external
        payable
        returns (address)
    {
        return poolAddr;
    }

    function mint(INonfungiblePositionManager.MintParams calldata p)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 a0, uint256 a1)
    {
        a0 = p.amount0Desired > 0 ? p.amount0Desired - 1 : 0;
        a1 = p.amount1Desired > 0 ? p.amount1Desired - 1 : 0;
        require(a0 >= p.amount0Min && a1 >= p.amount1Min, "slippage");
        if (a0 > 0) IERC20(p.token0).transferFrom(msg.sender, poolAddr, a0);
        if (a1 > 0) IERC20(p.token1).transferFrom(msg.sender, poolAddr, a1);
        tokenId = nextId++;
        ownerOf[tokenId] = p.recipient;
        liquidity = uint128(a0 + a1);
    }

    function transferFrom(address from, address to, uint256 tokenId) external {
        require(ownerOf[tokenId] == from, "not owner");
        ownerOf[tokenId] = to;
    }
}

contract SeedPoolTest is Test {
    V2H t;
    address committer = makeAddr("c");
    address founder = makeAddr("f");
    address constant NPM = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint160 constant SQRT = 79228162514264337593543950336; // ~1:1
    int24 constant MAXT = 887_200;
    int24 constant MINT = -887_200;

    function setUp() public {
        vm.warp(1_800_000_000);
        t = new V2H(committer, founder);
        // genesis
        uint256 w = t.WINNERS0(); // hoist out of the prank
        vm.prank(committer);
        t.commitSet(_root(), w, uint64(block.timestamp + 30 minutes));
        vm.warp(block.timestamp + 30 minutes);
        t.seal();
        // etch mocks
        vm.etch(NPM, address(new MockNPMV2()).code);
        MockNPMV2(NPM).setPool(t.computedPool());
        vm.etch(t.computedPool(), address(new MockPool()).code);
        MockPool(t.computedPool()).setPrice(SQRT);
    }

    function _root() internal pure returns (bytes32) {
        // any non-zero root; seedPool tests don't claim
        return keccak256("root");
    }

    function _ticks() internal view returns (int24 lo, int24 hi) {
        bool tok0 = address(t) < WETH;
        return tok0 ? (int24(0), MAXT) : (MINT, int24(0));
    }

    function test_SeedPoolHappyPath() public {
        (int24 lo, int24 hi) = _ticks();
        vm.prank(founder);
        t.seedPool(SQRT, lo, hi);

        assertTrue(t.poolSeeded());
        assertEq(t.pool(), t.computedPool());
        assertEq(MockNPMV2(NPM).ownerOf(t.positionTokenId()), DEAD, "LP NFT burned to DEAD");
        // liquidity left the contract (moved to the excluded pool + 1 dust burned)
        assertEq(t.balanceOf(address(t)), 188_790 * 1e8, "only the draw budget remains");
        assertEq(t.burned(), 1, "rounding dust burned");
    }

    function test_SeedPoolOnlyFounderOrDeployer() public {
        (int24 lo, int24 hi) = _ticks();
        // a third party (neither founder nor the deployer) is rejected
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(SecondBitcoinV2.NotFounder.selector);
        t.seedPool(SQRT, lo, hi);
    }

    function test_SeedPoolOnce() public {
        (int24 lo, int24 hi) = _ticks();
        vm.prank(founder);
        t.seedPool(SQRT, lo, hi);
        vm.prank(founder);
        vm.expectRevert(SecondBitcoinV2.AlreadyDone.selector);
        t.seedPool(SQRT, lo, hi);
    }

    function test_SeedPoolRejectsPreInitializedPrice() public {
        // attacker pre-initialised the pool at a different price → slot0 mismatch → refuse
        MockPool(t.computedPool()).setPrice(SQRT * 2);
        (int24 lo, int24 hi) = _ticks();
        vm.prank(founder);
        vm.expectRevert(SecondBitcoinV2.BadPoolParams.selector);
        t.seedPool(SQRT, lo, hi);
    }

    function test_SeedPoolRejectsWrongTick() public {
        bool tok0 = address(t) < WETH;
        // break the mandatory far tick
        (int24 lo, int24 hi) = tok0 ? (int24(0), int24(0)) : (int24(0), int24(0));
        vm.prank(founder);
        vm.expectRevert(SecondBitcoinV2.BadPoolParams.selector);
        t.seedPool(SQRT, lo, hi);
    }
}
