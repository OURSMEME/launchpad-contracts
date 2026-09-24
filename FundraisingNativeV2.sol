// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./FundraisingNative.sol";

/// @notice 用于升级 FundraisingNative 的第二版实现。
contract FundraisingNativeV2 is FundraisingNative {
    /// @notice 执行第二版初始化预留。
    /// @custom:oz-upgrades-validate-as-initializer
    function initializeV2() external reinitializer(2) {}

    /// @notice 返回当前合约实现版本。
    function version() external pure returns (string memory) {
        return "v2";
    }
}
