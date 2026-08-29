// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {Launcher} from "../src/Launcher.sol";
import {SecondBitcoin} from "../src/SecondBitcoin.sol";
import {INonfungiblePositionManager} from "../src/interfaces/IUniswapV3.sol";

/// Genesis in ONE transaction: Launcher deploys the token, seeds the single-sided pool, hands the operator role over.
///   forge script script/Deploy.s.sol --rpc-url $RPC --account <keystore> --broadcast [--verify ...]
/// env: OPERATOR, FOUNDER (default: broadcaster), NPM, WETH,
///      SQRT0 TL0 TU0 (params if 2BTC is token0)  SQRT1 TL1 TU1 (params if 2BTC is token1)  — from ops/pool_params.py --both
contract Deploy is Script {
    function run() external {
        address sender = msg.sender;
        address operator = vm.envOr("OPERATOR", sender);
        address founder = vm.envOr("FOUNDER", sender);
        address npm = vm.envAddress("NPM");
        address weth = vm.envAddress("WETH");
        Launcher.PoolParams memory p = Launcher.PoolParams({
            sqrtPriceX96IfToken0: uint160(vm.envUint("SQRT0")),
            tickLowerIfToken0: int24(vm.envInt("TL0")),
            tickUpperIfToken0: int24(vm.envInt("TU0")),
            sqrtPriceX96IfToken1: uint160(vm.envUint("SQRT1")),
            tickLowerIfToken1: int24(vm.envInt("TL1")),
            tickUpperIfToken1: int24(vm.envInt("TU1"))
        });
        vm.startBroadcast();
        Launcher l = new Launcher(operator, founder, INonfungiblePositionManager(npm), weth, p);
        vm.stopBroadcast();
        SecondBitcoin token = l.token();
        console2.log("Launcher            :", address(l));
        console2.log("SecondBitcoin (2BTC):", address(token));
        console2.log("FounderVesting      :", address(token.vesting()));
        console2.log("pool                :", token.pool());
        console2.log("position NFT        :", token.positionTokenId());
        console2.log("operator            :", token.operator());
        console2.log("founder             :", founder);
        console2.log("genesis block       :", token.genesisBlock());
    }
}
