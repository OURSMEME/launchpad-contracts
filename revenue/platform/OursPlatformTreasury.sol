// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IOursFeePool} from "../interfaces/IOursRevenue.sol";
import {OursPlatformFeeReceiver,IPlatformCredit} from "./OursPlatformFeeReceiver.sol";
interface IPlatformStrategyIdentity { function treasury() external view returns(address); }
/// @notice Non-upgradeable custody; versions and their allocations cannot be overwritten.
contract OursPlatformTreasury is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    error Invalid(); error Unauthorized(); error TransferMismatch();
    struct Allocation { address strategy; uint16 weightBps; }
    IOursFeePool public immutable feePool;
    mapping(bytes32 => address) public receivers;
    mapping(bytes32 => Allocation[]) private allocations;
    mapping(address => bytes32) public versionOfStrategy;
    mapping(address => bytes32) public strategyCodeHash;
    mapping(address => bool) public strategyPaused;
    mapping(bytes32 => mapping(address => uint256)) public grossFees;
    mapping(bytes32 => mapping(address => uint256)) public dust;
    mapping(address => mapping(address => uint256)) public allocated;
    mapping(address => mapping(address => uint256)) public budget;
    mapping(address => uint256) public totalLiability;
    event VersionRegistered(bytes32 indexed version,address indexed receiver);
    event BudgetAllocated(bytes32 indexed version,address indexed strategy,address indexed asset,uint256 amount);
    event BudgetClaimed(address indexed strategy,address indexed asset,uint256 amount);
    event StrategyPaused(address indexed strategy,bool paused);
    constructor(address governance,IOursFeePool pool) Ownable(governance) {
        if(address(pool).code.length==0)revert Invalid();feePool=pool;
    }
    receive() external payable {}
    function renounceOwnership() public override onlyOwner {revert Invalid();}
    function registerVersion(bytes32 version,Allocation[] calldata list) external onlyOwner returns(address receiver) {
        if(version==0||receivers[version]!=address(0)||list.length==0||list.length>16)revert Invalid();
        uint256 sum;
        for(uint256 i;i<list.length;++i){
            address strategy=list[i].strategy;
            if(strategy.code.length==0||list[i].weightBps==0||versionOfStrategy[strategy]!=0
                ||IPlatformStrategyIdentity(strategy).treasury()!=address(this))revert Invalid();
            sum+=list[i].weightBps;versionOfStrategy[strategy]=version;
            strategyCodeHash[strategy]=strategy.codehash;allocations[version].push(list[i]);
        }
        if(sum!=10000)revert Invalid();
        receiver=address(new OursPlatformFeeReceiver(IPlatformCredit(address(this)),feePool,version));
        receivers[version]=receiver;emit VersionRegistered(version,receiver);
    }
    function strategiesOf(bytes32 version) external view returns(Allocation[] memory){return allocations[version];}
    function setStrategyPaused(address strategy,bool paused) external onlyOwner {
        if(versionOfStrategy[strategy]==0)revert Invalid();strategyPaused[strategy]=paused;emit StrategyPaused(strategy,paused);
    }
    function credit(bytes32 version,address asset,uint256 amount) external payable nonReentrant {
        if(msg.sender!=receivers[version]||msg.sender==address(0)||amount==0)revert Unauthorized();
        if(asset==address(0)){if(msg.value!=amount)revert TransferMismatch();}
        else{
            if(msg.value!=0)revert Invalid();uint256 before_=IERC20(asset).balanceOf(address(this));
            IERC20(asset).safeTransferFrom(msg.sender,address(this),amount);
            if(IERC20(asset).balanceOf(address(this))!=before_+amount)revert TransferMismatch();
        }
        totalLiability[asset]+=amount;
        uint256 gross=grossFees[version][asset]+amount;grossFees[version][asset]=gross;
        uint256 sum;Allocation[] storage list=allocations[version];
        for(uint256 i;i<list.length;++i){
            uint256 target=Math.mulDiv(gross,list[i].weightBps,10000);
            uint256 added=target-allocated[list[i].strategy][asset];
            allocated[list[i].strategy][asset]=target;budget[list[i].strategy][asset]+=added;sum+=target;
            emit BudgetAllocated(version,list[i].strategy,asset,added);
        }
        dust[version][asset]=gross-sum;
    }
    /// @notice Only the selected strategy can pull its own allocation; destination cannot be supplied.
    function claimBudget(address asset) external nonReentrant returns(uint256 amount){
        if(versionOfStrategy[msg.sender]==0||strategyPaused[msg.sender]||msg.sender.codehash!=strategyCodeHash[msg.sender])revert Unauthorized();
        amount=budget[msg.sender][asset];if(amount==0)return 0;
        budget[msg.sender][asset]=0;totalLiability[asset]-=amount;
        if(asset==address(0)){(bool ok,)=msg.sender.call{value:amount}("");if(!ok)revert TransferMismatch();}
        else{uint256 before_=IERC20(asset).balanceOf(msg.sender);uint256 own=IERC20(asset).balanceOf(address(this));
            IERC20(asset).safeTransfer(msg.sender,amount);
            if(IERC20(asset).balanceOf(msg.sender)!=before_+amount||IERC20(asset).balanceOf(address(this))+amount!=own)revert TransferMismatch();}
        emit BudgetClaimed(msg.sender,asset,amount);
    }
}
