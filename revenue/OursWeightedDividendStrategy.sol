// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {RevenueBase} from "./base/RevenueBase.sol";
import {OursProjectRegistry} from "./OursProjectRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OursTokenWeights} from "../OursTokenWeights.sol";
import {OursRevenueTypes as T} from "./interfaces/IOursRevenue.sol";

contract OursWeightedDividendStrategy is RevenueBase {
    mapping(address => OursTokenWeights) public weightsOf;
    event WeightsCreated(address indexed project, address indexed weights);
    function requiresTokenObserver() external pure returns (bool) { return true; }
    function createTokenObserver(address[] calldata system) external returns (address) {
        address project = msg.sender;
        if (registry.weightedDividendOf(project) != address(this) || address(weightsOf[project]) != address(0)
            || IERC20(project).totalSupply() > type(uint128).max
            || IERC20(project).balanceOf(registry.curveOf(project)) != IERC20(project).totalSupply()) revert Invalid();
        OursTokenWeights weights = new OursTokenWeights(project, address(this), system);
        weightsOf[project] = weights;
        emit WeightsCreated(project, address(weights));
        return address(weights);
    }
    struct Distribution { uint256 amount; uint256 totalWeight; }
    mapping(address=>mapping(address=>mapping(uint64=>uint256))) public budget;
    mapping(address=>uint256) public rewardInventory;
    mapping(address=>uint256) public outstanding;
    mapping(address=>mapping(uint64=>Distribution)) public distributions;
    mapping(address=>mapping(address=>uint64)) public lastClaimedSnapshot;
    mapping(address=>mapping(address=>uint256)) public totalClaimed;
    event BudgetReceived(address indexed project,address indexed asset,uint64 version,uint256 amount);
    event RewardAcquired(address indexed project,uint256 spent,uint256 received);
    event DividendSnapshot(address indexed project,uint64 indexed id,uint256 amount,uint256 totalWeight);
    event DividendClaimed(address indexed project,address indexed account,uint64 throughSnapshot,uint256 amount);
    constructor(OursProjectRegistry r) RevenueBase(r,"OURS WeightedDividend") {}
    function requiresWeightedToken() external pure returns(bool) { return true; }
    // Requirement: retain signed execution/minOut, but no independent reference-price/cooldown guard for this strategy.
    function _requiresExecutionGuard() internal pure override returns(bool) { return false; }
    function validateConfig(address project,address,bytes calldata config) external view {
        if(config.length!=32) revert Invalid();
        address asset=abi.decode(config,(address));
        if(asset==project || !registry.allowedAssets(asset)) revert Invalid();
    }
    function rewardAsset(address project) public view returns(address) {
        return abi.decode(registry.strategyConfig(project,address(this)),(address));
    }
    // Anyone may move the fixed budget; _collectBudget still checks selection and pause state.
    function collectBudget(address project,uint64 version) external nonReentrant returns(uint256 amount) {
        address asset; (asset,amount)=_collectBudget(project,version);
        if(asset==rewardAsset(project)) rewardInventory[project]+=amount;
        else budget[project][asset][version]+=amount;
        emit BudgetReceived(project,asset,version,amount);
    }
    function acquireReward(T.ExecutionPlan calldata p,bytes calldata route,bytes calldata sig)
        external nonReentrant executor(p.project) returns(T.ExecutionResult memory r) {
        r=_swap(p,route,sig,T.ACQUIRE_DIVIDEND,registry.quoteAsset(p.project),rewardAsset(p.project),budget[p.project][p.assetIn][p.policyVersion]);
        budget[p.project][p.assetIn][p.policyVersion]-=r.actualSpent;
        rewardInventory[p.project]+=r.actualReceived;
        emit RewardAcquired(p.project,r.actualSpent,r.actualReceived);
    }
    function checkpoint(address project) external nonReentrant returns(uint64) {
        OursTokenWeights t=weightsOf[project];address caller=_revenueSender();
        if(IERC20(project).balanceOf(caller)==0 || t.excluded(caller)) revert Unauthorized();
        return _snapshot(project);
    }
    function _snapshot(address project) private returns(uint64 id) {
        if(registry.weightedDividendOf(project)!=address(this)) revert Invalid();
        OursTokenWeights t=weightsOf[project];
        if(t.revenue()!=address(this)) revert Invalid();
        if(rewardInventory[project]==0 || t.totalWeight()==0) return t.snapshotCount();
        uint256 amount=rewardInventory[project];rewardInventory[project]=0;outstanding[project]+=amount;
        uint256 weight;(id,weight)=t.snapshot();distributions[project][id]=Distribution(amount,weight);
        emit DividendSnapshot(project,id,amount,weight);
    }
    function claimable(address project,address account,uint64 maxSnapshots) public view returns(uint256 amount,uint64 end) {
        if(maxSnapshots==0 || maxSnapshots>100 || registry.weightedDividendOf(project)!=address(this)) revert Invalid();
        OursTokenWeights t=weightsOf[project];
        uint64 start=lastClaimedSnapshot[project][account];uint64 first=t.firstWeightSnapshot(account);
        if(first>start+1) start=first-1;
        end=t.snapshotCount();if(uint256(start)+maxSnapshots<end) end=start+maxSnapshots;
        for(uint64 id=start+1;id<=end;++id) {
            Distribution memory d=distributions[project][id];
            amount+=Math.mulDiv(d.amount,t.weightAt(account,id),d.totalWeight);
        }
    }
    function claim(address project,uint64 maxSnapshots) external nonReentrant returns(uint256 amount) {
        OursTokenWeights t=weightsOf[project];address caller=_revenueSender();
        if(IERC20(project).balanceOf(caller)!=0 && !t.excluded(caller)) _snapshot(project);
        uint64 end;(amount,end)=claimable(project,caller,maxSnapshots);
        lastClaimedSnapshot[project][caller]=end;
        if(amount!=0) { outstanding[project]-=amount;totalClaimed[project][caller]+=amount;_send(rewardAsset(project),caller,amount); }
        emit DividendClaimed(project,caller,end,amount);
    }
}
