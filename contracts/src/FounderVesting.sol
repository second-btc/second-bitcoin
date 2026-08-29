// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IEpochSource {
    function epochsDrawn() external view returns (uint256);
}

/// @title FounderVesting (v1) — the founder's locked coins unlock one halving *behind* the public curve.
/// @notice Unlock schedule is tied to epochs actually drawn on the token (epochsDrawn), not wall-clock.
///         epoch 0 (genesis) → 0%, epoch 1 → 50% of locked, epoch 2 → 75%, epoch k → 1 - 1/2^k, epoch 32 → 100%.
///         (Used by the v1 SecondBitcoin contract. v2 uses FounderVestingV2, which is time-based.)
contract FounderVesting {
    IERC20 public immutable token;
    address public immutable beneficiary;
    uint256 public constant LAST_EPOCH = 32;
    uint256 public released;

    event Released(uint256 amount);

    constructor(address token_, address beneficiary_) {
        require(token_ != address(0) && beneficiary_ != address(0), "zero");
        token = IERC20(token_);
        beneficiary = beneficiary_;
    }

    /// @dev Total ever held by this contract (balance + released). Donations vest on the same curve.
    function totalAllocation() public view returns (uint256) {
        return token.balanceOf(address(this)) + released;
    }

    function vestedAmount() public view returns (uint256) {
        uint256 drawn = IEpochSource(address(token)).epochsDrawn();
        if (drawn <= 1) return 0; // genesis only → nothing unlocked
        uint256 k = drawn - 1; // number of halvings actually drawn
        uint256 total = totalAllocation();
        if (k >= LAST_EPOCH) return total;
        return total - (total >> k);
    }

    function releasable() public view returns (uint256) {
        return vestedAmount() - released;
    }

    /// @notice Anyone may call; funds always go to the beneficiary.
    function release() external {
        uint256 amount = releasable();
        require(amount > 0, "nothing vested");
        released += amount;
        require(token.transfer(beneficiary, amount), "transfer failed");
        emit Released(amount);
    }
}
