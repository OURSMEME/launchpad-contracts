// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/** @notice Launch-window tax settings snapshotted by each curve at initialization. */
interface IOursSnipeTax {
    function snipeTaxStartBps() external view returns (uint256);
    function snipeTaxSeconds() external view returns (uint256);
}
