// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IOursFeePool} from "../interfaces/IOursRevenue.sol";
interface IPlatformCredit {function credit(bytes32 version,address asset,uint256 amount) external payable;}
/// @notice Fixed per-version recipient pinned by the existing project policy at launch.
contract OursPlatformFeeReceiver is ReentrancyGuard {
    using SafeERC20 for IERC20;
    error TransferMismatch();
    IPlatformCredit public immutable treasury;
    IOursFeePool public immutable feePool;
    bytes32 public immutable version;
    constructor(IPlatformCredit t,IOursFeePool pool,bytes32 v){treasury=t;feePool=pool;version=v;}
    receive() external payable {}
    function collectFees(address asset) external nonReentrant returns(uint256 amount){
        uint256 before_=asset==address(0)?address(this).balance:IERC20(asset).balanceOf(address(this));
        amount=feePool.claimIncome(asset);
        uint256 after_=asset==address(0)?address(this).balance:IERC20(asset).balanceOf(address(this));
        if(amount==0||after_-before_!=amount)revert TransferMismatch();
        if(asset==address(0))treasury.credit{value:amount}(version,asset,amount);
        else{IERC20(asset).forceApprove(address(treasury),amount);treasury.credit(version,asset,amount);IERC20(asset).forceApprove(address(treasury),0);}
        if((asset==address(0)?address(this).balance:IERC20(asset).balanceOf(address(this)))!=before_)revert TransferMismatch();
    }
}
