// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {OursProjectRegistry} from "../OursProjectRegistry.sol";
import {IOursFeePool} from "../interfaces/IOursRevenue.sol";

/// @notice Integration mixin for a modified Curve or shared Hook. No public accrual entry.
/// @dev Call _accrueRevenue at the actual trade; accounting never reads a new policy at sweep time.
abstract contract OursFeeAccrual is ReentrancyGuard {
    using SafeERC20 for IERC20;
    error RevenueUnauthorized(); error RevenueInvalid();
    OursProjectRegistry public revenueRegistry;
    mapping(address => mapping(address => mapping(uint64 => uint256))) public accruedRevenue;
    mapping(address => uint256) public reservedRevenue;
    event RevenueAccrued(address indexed project,address indexed asset,uint64 indexed version,uint256 amount);
    event RevenueSwept(address indexed project,address indexed asset,uint64 indexed version,uint256 amount);
    constructor(OursProjectRegistry r) { revenueRegistry = r; }
    // Hook is deployed before Factory/Registry. Its owner exposes this one-time binding;
    // Curve receives a nonzero Registry in its constructor and cannot rebind.
    function _bindRevenueRegistry(OursProjectRegistry r) internal {
        if(address(revenueRegistry)!=address(0)||address(r).code.length==0)revert RevenueInvalid();
        revenueRegistry=r;
    }
    function _accrueRevenue(address project,address asset,uint256 amount) internal {
        if (!revenueRegistry.isFeeSource(project,address(this)) || (asset != project && asset != revenueRegistry.quoteAsset(project))) revert RevenueInvalid();
        uint64 v = revenueRegistry.currentVersion(project);
        accruedRevenue[project][asset][v] += amount; reservedRevenue[asset] += amount;
        emit RevenueAccrued(project,asset,v,amount);
    }
    /// @dev Callable after graduation too; no iteration over versions or projects.
    function sweepRevenue(address project,address asset,uint64 version) external nonReentrant {
        uint256 amount=accruedRevenue[project][asset][version]; if(amount==0)revert RevenueInvalid();
        accruedRevenue[project][asset][version]=0;reservedRevenue[asset]-=amount;
        _beforeRevenueSweep(asset,amount);
        address pool=revenueRegistry.feePool();
        if(asset!=address(0))IERC20(asset).forceApprove(pool,amount);
        IOursFeePool(pool).creditFees{value:asset==address(0)?amount:0}(project,asset,version,amount);
        if(asset!=address(0))IERC20(asset).forceApprove(pool,0);
        emit RevenueSwept(project,asset,version,amount);
    }
    /// @dev Curve adjusts its tracked balances here; shared Hook may use a no-op.
    function _beforeRevenueSweep(address asset,uint256 amount) internal virtual;
}

