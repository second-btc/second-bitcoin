// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ITokenTime {
    function startTime() external view returns (uint64); // 0 until the token is sealed
}

/// @title FounderVestingV2 — the founder's locked coins (160 = 0.076%) unlock LINEARLY over 2 years from seal.
/// @notice The one-shot broad draw distributes to the public within its claim window; the founder's locked
///         share vests behind that, linearly over VEST_DURATION from startTime (the seal). Fully autonomous
///         and permissionless — no operator, no per-epoch action. Nothing unlocks before seal (startTime == 0).
contract FounderVestingV2 {
    IERC20 public immutable token;
    address public immutable beneficiary;
    uint256 public constant VEST_DURATION = 730 days; // 2 years, linear, from seal
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
        uint64 t0 = ITokenTime(address(token)).startTime();
        if (t0 == 0) return 0; // not sealed yet → nothing unlocked
        uint256 elapsed = block.timestamp - uint256(t0);
        uint256 total = totalAllocation();
        if (elapsed >= VEST_DURATION) return total;
        return total * elapsed / VEST_DURATION;
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
