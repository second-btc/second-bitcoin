// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

interface IV3Factory {
    function getPool(address, address, uint24) external view returns (address);
}

/// Base-fork verification of the chain constants hardcoded in SecondBitcoinV2.
/// Run: forge test --match-contract ForkVerify --fork-url https://mainnet.base.org
contract ForkVerify is Test {
    address constant BEACON = 0x000F3df6D732807Ef1319fB7B8bB8522d0Beac02;
    address constant FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
    address constant NPM = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;
    bytes32 constant INIT = 0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    function test_Beacon4788Exists() public view {
        assertGt(BEACON.code.length, 0, "EIP-4788 predeploy present on Base");
    }

    function test_BeaconReturnsRoot() public view {
        // the exact call _beaconSeed makes: 32-byte timestamp in, 32-byte root out
        (bool ok, bytes memory out) = BEACON.staticcall(abi.encode(uint256(block.timestamp)));
        assertTrue(ok && out.length == 32, "beacon returns a 32-byte root for the current timestamp");
        assertTrue(abi.decode(out, (bytes32)) != bytes32(0), "root is non-zero");
    }

    function test_UniswapConstantsCorrect() public view {
        assertGt(FACTORY.code.length, 0, "factory present");
        assertGt(NPM.code.length, 0, "NPM present");
        // a known live pool: WETH/USDC 0.05%
        address expected = IV3Factory(FACTORY).getPool(WETH, USDC, 500);
        assertTrue(expected != address(0), "reference pool exists");
        (address t0, address t1) = WETH < USDC ? (WETH, USDC) : (USDC, WETH);
        bytes32 key = keccak256(abi.encode(t0, t1, uint24(500)));
        address computed = address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", FACTORY, key, INIT)))));
        assertEq(computed, expected, "factory + init code hash reproduce the real pool address");
    }
}
