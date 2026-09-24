// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Stable extension boundary. Callbacks are atomic with ERC20 balance changes.
interface IOursTokenObserver {
    function token() external view returns (address);
    function onBalanceChange(address from, address to, uint256 amount) external returns (bytes4);
}
interface IOursTokenObserverFactory {
    function createTokenObserver(address[] calldata system) external returns (address);
}
