// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {LauncherV2} from "../src/LauncherV2.sol";
import {SecondBitcoinV2} from "../src/SecondBitcoinV2.sol";

/// @notice Genesis deploy: atomically deploy the token and seed the single-sided pool (one transaction,
///         so the pool can never be front-run). The eligible-list commit and seal are separate steps
///         run afterwards by the committer (see the launch runbook).
///
/// Env:
///   COMMITTER       — address that will commit the eligible-set root and seal the seed
///   FOUNDER         — receives the 50 liquid coins; the 0.1% share
///   SQRT_PRICE_X96  — pool starting price (from ops/pool_params.py for the chosen P0)
///   TICK_LOWER      — single-sided range lower tick (from pool_params.py)
///   TICK_UPPER      — single-sided range upper tick (from pool_params.py)
///
///   forge script script/DeployV2.s.sol --rpc-url $RPC_URL --account 2btc-operator --broadcast --verify
contract DeployV2 is Script {
    function run() external {
        address committer = vm.envAddress("COMMITTER");
        address founder = vm.envAddress("FOUNDER");
        uint160 sqrtPriceX96 = uint160(vm.envUint("SQRT_PRICE_X96"));
        int24 tickLower = int24(vm.envInt("TICK_LOWER"));
        int24 tickUpper = int24(vm.envInt("TICK_UPPER"));
        // The pool parameters above were computed off-chain for a PREDICTED token address (they depend on
        // the token/WETH sort order). Recompute the prediction here and abort — in simulation, before any
        // broadcast — if the deployer nonce moved or the ordering flipped: seeding at an inverted price
        // would be an unrecoverable mispricing.
        address deployer = vm.envAddress("DEPLOYER");
        address weth = 0x4200000000000000000000000000000000000006;
        bool wantToken0 = vm.envBool("WE_ARE_TOKEN0");
        address launcherPred = vm.computeCreateAddress(deployer, vm.getNonce(deployer));
        address tokenPred = vm.computeCreateAddress(launcherPred, 1);
        require((uint160(tokenPred) < uint160(weth)) == wantToken0, "token/WETH ordering mismatch - rerun pool_params");

        vm.startBroadcast();
        LauncherV2 launcher = new LauncherV2();
        address token = launcher.launch(committer, founder, sqrtPriceX96, tickLower, tickUpper);
        vm.stopBroadcast();
        require(token == tokenPred, "token address != prediction - env is stale, do not reuse");

        SecondBitcoinV2 t = SecondBitcoinV2(token);
        console2.log("token   ", token);
        console2.log("pool    ", t.pool());
        console2.log("vesting ", address(t.vesting()));
        console2.log("committer", t.committer());
        require(t.poolSeeded(), "not seeded");
    }
}
