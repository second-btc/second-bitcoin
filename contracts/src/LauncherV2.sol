// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SecondBitcoinV2} from "./SecondBitcoinV2.sol";

/// @title Atomic launcher for Second Bitcoin
/// @notice Deploys the token and seeds its single-sided pool in ONE transaction, so no block ever exists
///         between deployment and seeding — closing the pool-front-run window entirely. The launcher is the
///         token's `deployer`, which is the only extra address permitted to call `seedPool` (once). The
///         founder's 50 liquid coins still go to `founder`; the launcher only orchestrates and keeps nothing.
///         The eligible-list commit and seal happen afterwards, by the committer.
contract LauncherV2 {
    event Launched(address indexed token, address pool);

    function launch(address committer, address founder, uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper)
        external
        returns (address token)
    {
        SecondBitcoinV2 t = new SecondBitcoinV2(committer, founder);
        t.seedPool(sqrtPriceX96, tickLower, tickUpper); // msg.sender == token.deployer() == this launcher
        require(t.poolSeeded(), "seed failed");
        emit Launched(address(t), t.pool());
        return address(t);
    }
}
