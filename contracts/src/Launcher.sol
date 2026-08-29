// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SecondBitcoin} from "./SecondBitcoin.sol";
import {INonfungiblePositionManager} from "./interfaces/IUniswapV3.sol";

/// @title Launcher — genesis in one transaction: deploy the token, seed the single-sided pool, hand over.
/// @notice Because the token's address is not known until it exists, both tick sets are passed in
///         (for the case 2BTC < WETH → 2BTC is token0, and the opposite); the launcher picks the right one.
///         Nothing can be inserted between deployment and seeding: there is no block in which the pair
///         exists without the public position.
contract Launcher {
    SecondBitcoin public immutable token;

    struct PoolParams {
        uint160 sqrtPriceX96IfToken0;
        int24 tickLowerIfToken0;
        int24 tickUpperIfToken0;
        uint160 sqrtPriceX96IfToken1;
        int24 tickLowerIfToken1;
        int24 tickUpperIfToken1;
    }

    constructor(address operator, address founder, INonfungiblePositionManager npm, address weth, PoolParams memory p) {
        SecondBitcoin t = new SecondBitcoin(address(this), founder);
        bool token0 = address(t) < weth;
        t.seedPool(
            npm,
            weth,
            t.POOL_FEE(),
            token0 ? p.sqrtPriceX96IfToken0 : p.sqrtPriceX96IfToken1,
            token0 ? p.tickLowerIfToken0 : p.tickLowerIfToken1,
            token0 ? p.tickUpperIfToken0 : p.tickUpperIfToken1
        );
        t.setOperator(operator);
        token = t;
    }
}
