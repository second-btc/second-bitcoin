// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {LauncherV2} from "../src/LauncherV2.sol";
import {SecondBitcoinV2} from "../src/SecondBitcoinV2.sol";

/// Real Base Uniswap validation of the atomic launch: deploy + seed in one tx against the live
/// factory/NPM. Run: forge test --match-contract LauncherFork --fork-url https://mainnet.base.org
contract LauncherForkTest is Test {
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    int24 constant MAXT = 887_200;
    int24 constant MINT = -887_200;
    uint160 constant SQRT_TICK0 = 79228162514264337593543950336; // price at tick 0 (1:1)

    address committer = makeAddr("committer");
    address founder = makeAddr("founder");

    function test_AtomicLaunchOnBase() public {
        LauncherV2 launcher = new LauncherV2();
        // predict the token address (launcher's first CREATE, nonce 1) to pick the single-sided direction
        address predicted = vm.computeCreateAddress(address(launcher), 1);
        bool tok0 = predicted < WETH;
        (int24 lo, int24 hi) = tok0 ? (int24(0), MAXT) : (MINT, int24(0));

        address token = launcher.launch(committer, founder, SQRT_TICK0, lo, hi);
        assertEq(token, predicted, "token deployed at predicted address");

        SecondBitcoinV2 t = SecondBitcoinV2(token);
        assertTrue(t.poolSeeded(), "seeded");
        assertEq(t.pool(), t.computedPool(), "real pool == precomputed");
        // LP NFT burned to DEAD, so nobody owns/withdraws the liquidity
        // (position token id recorded; ownership check is on the real NPM)
        assertGt(t.pool().code.length, 0, "real pool contract exists");
        // founder got exactly the 50 liquid coins; contract keeps the draw budget
        assertEq(t.balanceOf(founder), 50 * 1e8);
        assertEq(t.balanceOf(address(t)), 188_790 * 1e8, "only the draw budget remains");
        assertGt(t.balanceOf(t.pool()), 20_000 * 1e8, "liquidity is in the pool");
    }

    function test_LauncherIsDeployerNotFounderHolder() public {
        LauncherV2 launcher = new LauncherV2();
        address predicted = vm.computeCreateAddress(address(launcher), 1);
        bool tok0 = predicted < WETH;
        (int24 lo, int24 hi) = tok0 ? (int24(0), MAXT) : (MINT, int24(0));
        address token = launcher.launch(committer, founder, SQRT_TICK0, lo, hi);
        SecondBitcoinV2 t = SecondBitcoinV2(token);
        // launcher keeps nothing and cannot seed again
        assertEq(t.balanceOf(address(launcher)), 0);
        assertEq(t.deployer(), address(launcher));
        vm.prank(founder);
        vm.expectRevert(SecondBitcoinV2.AlreadyDone.selector);
        t.seedPool(SQRT_TICK0, lo, hi);
    }
}
