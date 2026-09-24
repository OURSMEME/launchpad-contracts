// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {OursPlatformTreasury} from "./OursPlatformTreasury.sol";
contract OursPlatformOperatingStrategy is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    error Invalid();
    OursPlatformTreasury public immutable treasury;
    address public recipient;
    mapping(address=>uint256) public budget;
    event OperatingClaimed(address indexed asset,uint256 amount);
    event RecipientUpdated(address indexed previousRecipient,address indexed newRecipient);
    constructor(OursPlatformTreasury t,address payee) Ownable(msg.sender) {
        if(address(t).code.length==0||payee==address(0)||payee==address(this)||payee==address(t))revert Invalid();
        treasury=t;recipient=payee;
    }
    /// @notice Changes where all currently unpaid and future operating income of this version is sent.
    function setRecipient(address payee) external onlyOwner nonReentrant {
        if(payee==address(0)||payee==address(this)||payee==address(treasury))revert Invalid();
        address previous=recipient;if(previous==payee)return;
        recipient=payee;emit RecipientUpdated(previous,payee);
    }
    function renounceOwnership() public override onlyOwner {revert Invalid();}
    receive() external payable {}
    function collectBudget(address asset) external nonReentrant returns(uint256 amount){
        uint256 before_=_balance(asset);amount=treasury.claimBudget(asset);
        if(_balance(asset)!=before_+amount)revert Invalid();budget[asset]+=amount;
    }
    function claimOperating(address asset) external nonReentrant {
        if(treasury.strategyPaused(address(this)))revert Invalid();uint256 amount=budget[asset];if(amount==0)return;budget[asset]=0;
        address payee=recipient;
        if(asset==address(0)){(bool ok,)=payee.call{value:amount}("");if(!ok)revert Invalid();}
        else{uint256 before_=IERC20(asset).balanceOf(payee);uint256 own=IERC20(asset).balanceOf(address(this));IERC20(asset).safeTransfer(payee,amount);
            if(IERC20(asset).balanceOf(payee)!=before_+amount||IERC20(asset).balanceOf(address(this))+amount!=own)revert Invalid();}
        emit OperatingClaimed(asset,amount);
    }
    function _balance(address asset) private view returns(uint256){return asset==address(0)?address(this).balance:IERC20(asset).balanceOf(address(this));}
}
