// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev Test-only forwarding shim that spends gas in a chosen function before running real code.
contract SettlementGasHarness {
    address private immutable implementation;
    bytes4 private immutable slowSelector;
    uint256 private immutable gasToSpend;
    constructor(address target, bytes4 selector, uint256 amount) {
        implementation = target; slowSelector = selector; gasToSpend = amount;
    }
    fallback() external payable {
        if (msg.sig == slowSelector) {
            uint256 amount = gasToSpend;
            assembly ("memory-safe") {
                let start := gas()
                for {} lt(sub(start, gas()), amount) {} {}
            }
        }
        address target = implementation;
        assembly ("memory-safe") {
            let p := mload(0x40)
            calldatacopy(p, 0, calldatasize())
            let ok := delegatecall(gas(), target, p, calldatasize(), 0, 0)
            returndatacopy(p, 0, returndatasize())
            if iszero(ok) { revert(p, returndatasize()) }
            return(p, returndatasize())
        }
    }
}
