// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev 兼容“不标准返回值”的 ERC20/ETH 转账辅助库。
library TransferHelper {
    /// @dev approve 调用失败。
    error TransferHelperApproveFailed();
    /// @dev transfer 调用失败。
    error TransferHelperTransferFailed();
    /// @dev transferFrom 调用失败。
    error TransferHelperTransferFromFailed();
    /// @dev 原生 ETH 转账失败。
    error TransferHelperTransferETHFailed();

    /// @dev 安全调用 ERC20 approve。
    /// @param token ERC20 地址。
    /// @param to 被授权地址。
    /// @param value 授权额度。
    function safeApprove(address token, address to, uint value) internal {
        // bytes4(keccak256(bytes('approve(address,uint256)')));
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x095ea7b3, to, value));
        // require(success && (data.length == 0 || abi.decode(data, (bool))), 'TransferHelper: APPROVE_FAILED');
        if(!success || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferHelperApproveFailed();
    }

    /// @dev 安全调用 ERC20 transfer。
    /// @param token ERC20 地址。
    /// @param to 接收地址。
    /// @param value 转账数量。
    function safeTransfer(address token, address to, uint value) internal {
        // bytes4(keccak256(bytes('transfer(address,uint256)')));
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0xa9059cbb, to, value));
        // require(success && (data.length == 0 || abi.decode(data, (bool))), 'TransferHelper: TRANSFER_FAILED');
        if(!success || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferHelperTransferFailed();
    }

    /// @dev 安全调用 ERC20 transferFrom。
    /// @param token ERC20 地址。
    /// @param from 扣款地址。
    /// @param to 收款地址。
    /// @param value 转账数量。
    function safeTransferFrom(address token, address from, address to, uint value) internal {
        // bytes4(keccak256(bytes('transferFrom(address,address,uint256)')));
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x23b872dd, from, to, value));
        // require(success && (data.length == 0 || abi.decode(data, (bool))), 'TransferHelper: TRANSFER_FROM_FAILED');
        if(!success || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferHelperTransferFromFailed();
    }

    /// @dev 安全转出原生 ETH。
    /// @param to 接收地址。
    /// @param value 转账数量。
    function safeTransferETH(address to, uint value) internal {
        (bool success,) = to.call{value:value}(new bytes(0));
        // require(success, 'TransferHelper: ETH_TRANSFER_FAILED');
        if(!success) revert TransferHelperTransferETHFailed();
    }
}
