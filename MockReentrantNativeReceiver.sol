// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface INativeFundraising {
    function depositNative() external payable;
}

/// @notice 测试用恶意收款合约：收到原生币后尝试把同一笔资金重入募资合约。
contract MockReentrantNativeReceiver {
    /// @dev 目标募资合约地址。
    address public fundraising;
    /// @dev 是否在收款时发起重入。
    bool public attackEnabled;
    /// @dev 已发起的重入尝试次数。
    uint256 public reentryAttempts;
    /// @dev 是否曾有一次重入调用成功。
    bool public reentrySucceeded;

    /// @notice 配置被攻击的募资合约地址。
    /// @param fundraising_ 募资合约地址。
    function setFundraising(address fundraising_) external {
        fundraising = fundraising_;
    }

    /// @notice 开启或关闭重入攻击。
    /// @param enabled 是否开启攻击。
    function setAttackEnabled(bool enabled) external {
        attackEnabled = enabled;
    }

    /// @notice 收到原生币时重入目标合约。
    receive() external payable {
        if (attackEnabled) {
            reentryAttempts += 1;
            try INativeFundraising(fundraising).depositNative{value: msg.value}() {
                reentrySucceeded = true;
            } catch {}
        }
    }
}
