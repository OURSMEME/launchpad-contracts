// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {OursProjectRegistry} from "../OursProjectRegistry.sol";
import {OursRevenueTypes as T, IOursSwapAdapter} from "../interfaces/IOursRevenue.sol";
interface IOursCurveTrading {
    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient) external payable returns (uint256);
    function sell(uint256 tokensIn, uint256 minQuoteOut, address recipient) external returns (uint256);
}
/// @notice Restricted Ours curve calls. Handles crossing-buy refunds.
contract OursCurveAdapter is ReentrancyGuard, IOursSwapAdapter {
    using SafeERC20 for IERC20;
    error Invalid();
    OursProjectRegistry public immutable registry;
    constructor(OursProjectRegistry r) { registry = r; }
    receive() external payable {}
    function execute(address project, address assetIn, address assetOut, uint256 amount, uint256 minOut, bytes calldata route)
        external payable nonReentrant returns (T.ExecutionResult memory result) {
        if (msg.sender != registry.feePool() && msg.sender != registry.buybackPool() && msg.sender != registry.dividendPool()) revert Invalid();
        (bytes32 poolId,) = registry.poolOf(project);
        address quote = registry.quoteAsset(project);
        if (poolId != 0 || !registry.isTrading(project) || route.length != 0 || amount == 0 || minOut == 0
            || !((assetIn == quote && assetOut == project) || (assetIn == project && assetOut == quote))) revert Invalid();
        uint256 inBefore = _balance(assetIn) - (assetIn == address(0) ? msg.value : 0);
        uint256 outBefore = _balance(assetOut);
        if (assetIn == address(0)) { if (msg.value != amount) revert Invalid(); }
        else {
            if (msg.value != 0) revert Invalid(); IERC20(assetIn).safeTransferFrom(msg.sender, address(this), amount);
            if (_balance(assetIn) != inBefore + amount) revert Invalid();
        }
        address curve = registry.curveOf(project);
        if (assetIn != address(0)) IERC20(assetIn).forceApprove(curve, amount);
        if (assetIn == quote) IOursCurveTrading(curve).buy{value:assetIn == address(0) ? amount : 0}(amount, minOut, address(this));
        else IOursCurveTrading(curve).sell(amount, minOut, address(this));
        if (assetIn != address(0)) IERC20(assetIn).forceApprove(curve, 0);
        uint256 refund = _balance(assetIn) - inBefore;
        if (refund > amount) revert Invalid();
        result = T.ExecutionResult(amount - refund, _balance(assetOut) - outBefore);
        if (result.actualSpent == 0 || result.actualReceived < minOut) revert Invalid();
        _send(assetIn, msg.sender, refund); _send(assetOut, msg.sender, result.actualReceived);
    }
    function _balance(address a) private view returns (uint256) { return a == address(0) ? address(this).balance : IERC20(a).balanceOf(address(this)); }
    function _send(address a, address to, uint256 n) private {
        if (n == 0) return;
        if (a == address(0)) { (bool ok,) = to.call{value:n}(""); if (!ok) revert Invalid(); }
        else IERC20(a).safeTransfer(to,n);
    }
}

