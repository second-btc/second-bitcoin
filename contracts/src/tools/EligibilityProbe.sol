// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Never deployed. Its runtime bytecode is injected via eth_call `stateOverride` so that anyone
///         can check thousands of addresses against the eligibility rule at an exact block in one RPC call.
///         EOA := no code, or an EIP-7702 delegation (0xef0100 || address).
contract EligibilityProbe {
    function probe(address[] calldata a, uint256 minWei, uint256 maxWei) external view returns (bool[] memory ok) {
        ok = new bool[](a.length);
        for (uint256 i = 0; i < a.length; i++) {
            address x = a[i];
            uint256 b = x.balance;
            if (b < minWei || b > maxWei) continue;
            uint256 size;
            assembly {
                size := extcodesize(x)
            }
            if (size == 0) {
                ok[i] = true;
            } else if (size == 23) {
                bytes memory c = x.code;
                ok[i] = (c[0] == 0xef && c[1] == 0x01 && c[2] == 0x00);
            }
        }
    }
}
