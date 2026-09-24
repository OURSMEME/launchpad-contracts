// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
contract PlatformFeePoolStub {
    using SafeERC20 for IERC20;
    mapping(address=>mapping(address=>uint256)) public claimableIncome;
    function seed(address receiver,address asset,uint256 amount) external payable {
        if(asset==address(0))require(msg.value==amount);else IERC20(asset).safeTransferFrom(msg.sender,address(this),amount);
        claimableIncome[receiver][asset]+=amount;
    }
    function claimIncome(address asset) external returns(uint256 amount){
        amount=claimableIncome[msg.sender][asset];require(amount>0);claimableIncome[msg.sender][asset]=0;
        if(asset==address(0)){(bool ok,)=msg.sender.call{value:amount}("");require(ok);}else IERC20(asset).safeTransfer(msg.sender,amount);
    }
}
