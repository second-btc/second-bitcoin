// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {INonfungiblePositionManager} from "../src/interfaces/IUniswapV3.sol";

/// @dev Minimal stand-in for Uniswap's NonfungiblePositionManager: pulls the single-sided amount
///      (minus 1 unit of rounding dust), mints a fake NFT. The real thing is exercised on an Anvil fork.
contract MockNPM {
    address public lastPool = address(0xBEEF);
    mapping(uint256 => address) public ownerOf;
    uint256 public nextId = 1;
    bool public simulateTwoSided;
    uint256 public lastAmount0Desired;
    uint256 public lastAmount1Desired;

    function setTwoSided(bool v) external {
        simulateTwoSided = v;
    }

    function createAndInitializePoolIfNecessary(address, address, uint24, uint160) external payable returns (address) {
        return lastPool;
    }

    function mint(INonfungiblePositionManager.MintParams calldata p)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        lastAmount0Desired = p.amount0Desired;
        lastAmount1Desired = p.amount1Desired;
        if (simulateTwoSided) {
            // price inside range: both sides needed → nothing usable from a single-sided deposit
            require(0 >= p.amount0Min && 0 >= p.amount1Min, "Price slippage check");
            return (0, 0, 0, 0);
        }
        amount0 = p.amount0Desired > 0 ? p.amount0Desired - 1 : 0;
        amount1 = p.amount1Desired > 0 ? p.amount1Desired - 1 : 0;
        require(amount0 >= p.amount0Min && amount1 >= p.amount1Min, "Price slippage check");
        if (amount0 > 0) IERC20(p.token0).transferFrom(msg.sender, address(this), amount0);
        if (amount1 > 0) IERC20(p.token1).transferFrom(msg.sender, address(this), amount1);
        tokenId = nextId++;
        ownerOf[tokenId] = p.recipient;
        liquidity = uint128(amount0 + amount1);
    }

    function transferFrom(address from, address to, uint256 tokenId) external {
        require(ownerOf[tokenId] == from && msg.sender == from, "not owner");
        ownerOf[tokenId] = to;
    }
}
