// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OursProjectRegistry} from "./OursProjectRegistry.sol";
import {OursFeePool} from "./OursFeePool.sol";
import {OursRevenueTypes as T} from "./interfaces/IOursRevenue.sol";

interface IPreviewModule { function registry() external view returns(address); }
interface IPreviewAccrual { function accruedRevenue(address,address,uint64) external view returns(uint256); }
interface IPreviewCreator { function claimableIncome(address,address) external view returns(uint256); }
interface IPreviewDividend {
    function rewardAsset(address) external view returns(address);
    function rewardInventory(address) external view returns(uint256);
    function budget(address,address,uint64) external view returns(uint256);
    function weightsOf(address) external view returns(address);
    function claimable(address,address,uint64) external view returns(uint256,uint64);
    function lastClaimedSnapshot(address,address) external view returns(uint64);
}
interface IPreviewWeights {
    function token() external view returns(address);
    function revenue() external view returns(address);
    function excluded(address) external view returns(bool);
    function snapshotCount() external view returns(uint64);
    function firstWeightSnapshot(address) external view returns(uint64);
    function currentWeight(address) external view returns(uint256);
    function totalWeight() external view returns(uint256);
}

/// @notice Read-only estimate of default settlement, without swaps or gas deductions.
/// Does not bind to the launch stack, hold funds, or grant any execution permissions.
contract OursRevenuePreview is Ownable2Step {
    error Invalid();
    // Explicitly reviewed implementations, never guess custom strategy semantics from selectors.
    enum Kind { Unknown, Creator, WeightedDividend, Buyback }
    struct Implementation { address strategy; Kind kind; }
    struct Income {
        address strategy;
        Kind kind;
        bool supported;
        bool readSuccess;
        address asset;
        uint256 alreadyClaimable;
        uint256 estimatedAdditional;
        uint256 estimatedTotal;
        uint256 projectCollectableQuote;
        uint256 projectPendingConversionQuote;
        bool collectionPaused;
        bool hasMoreSnapshots;
    }
    struct Preview {
        uint256 blockNumber;
        uint256 timestamp;
        address quoteAsset;
        uint256 pendingQuoteFees;
        uint256 unconvertedMemeFees;
        bool complete;
        Income[] incomes;
    }
    OursProjectRegistry public immutable registry;
    mapping(address=>Kind) public kinds;
    mapping(address=>bytes32) public codeHashes;
    event ImplementationSet(address indexed strategy, Kind kind, bytes32 codeHash);
    event ImplementationRemoved(address indexed strategy);
    constructor(OursProjectRegistry r,Implementation[] memory implementations) Ownable(msg.sender) {
        if(address(r).code.length==0) revert Invalid();
        registry=r;
        for(uint256 i;i<implementations.length;++i) {
            if(kinds[implementations[i].strategy]!=Kind.Unknown) revert Invalid();
            _setImplementation(implementations[i]);
        }
    }
    function previewManagementVersion() external pure returns(uint256) { return 2; }
    /// @notice Update estimation metadata only. No execution permission or custody is granted.
    function setImplementations(Implementation[] calldata implementations) external onlyOwner {
        if(implementations.length==0 || implementations.length>64) revert Invalid();
        for(uint256 i;i<implementations.length;++i) _setImplementation(implementations[i]);
    }
    function removeImplementation(address strategy) external onlyOwner {
        if(kinds[strategy]==Kind.Unknown) revert Invalid();
        delete kinds[strategy]; delete codeHashes[strategy];
        emit ImplementationRemoved(strategy);
    }
    function _setImplementation(Implementation memory entry) private {
        if(entry.kind==Kind.Unknown || entry.strategy.code.length==0
            || IPreviewModule(entry.strategy).registry()!=address(registry)) revert Invalid();
        kinds[entry.strategy]=entry.kind; codeHashes[entry.strategy]=entry.strategy.codehash;
        emit ImplementationSet(entry.strategy,entry.kind,entry.strategy.codehash);
    }
    function preview(address project,address account,uint64 maxSnapshots) external view returns(Preview memory out) {
        if(account==address(0) || maxSnapshots==0 || maxSnapshots>100) revert Invalid();
        uint64 version=registry.currentVersion(project);
        out.blockNumber=block.number;out.timestamp=block.timestamp;out.quoteAsset=registry.quoteAsset(project);out.complete=true;
        OursFeePool fee=OursFeePool(payable(registry.feePool()));
        out.pendingQuoteFees=fee.pendingFees(project,out.quoteAsset,version);
        out.unconvertedMemeFees=fee.pendingFees(project,project,version);
        (uint256 accrued,bool ok)=_accrued(registry.curveOf(project),project,out.quoteAsset,version);
        out.pendingQuoteFees+=accrued;out.complete=ok;
        (,address hook)=registry.poolOf(project);
        if(hook!=address(0)) {
            (accrued,ok)=_accrued(hook,project,out.quoteAsset,version);
            out.pendingQuoteFees+=accrued;out.complete=out.complete&&ok;
            (accrued,ok)=_accrued(hook,project,project,version);
            out.unconvertedMemeFees+=accrued;out.complete=out.complete&&ok;
        }
        T.PolicyVersion memory pv=registry.policyAt(project,version);
        (uint256 gross,,,)=fee.totals(project,version);
        gross+=out.pendingQuoteFees;
        uint256 rest=gross-Math.mulDiv(gross,pv.platformBps,10_000);
        address[] memory modules=registry.strategiesOf(project);
        out.incomes=new Income[](modules.length);
        for(uint256 i;i<modules.length;++i) {
            uint256 projected=fee.strategyClaimable(project,modules[i],out.quoteAsset)
                +Math.mulDiv(rest,pv.policy.strategies[i].weightBps,10_000)-fee.strategyAllocated(project,modules[i]);
            try this.previewStrategy{gas:3_000_000}(project,account,modules[i],projected,maxSnapshots) returns(Income memory row) {
                out.incomes[i]=row;
                if(!row.supported || !row.readSuccess) out.complete=false;
            } catch {
                out.incomes[i].strategy=modules[i];out.incomes[i].kind=kinds[modules[i]];out.complete=false;
            }
        }
    }
    function _accrued(address source,address project,address asset,uint64 version) private view returns(uint256,bool) {
        try IPreviewAccrual(source).accruedRevenue{gas:100_000}(project,asset,version) returns(uint256 amount) { return(amount,true); }
        catch { return(0,false); }
    }
    /// @dev Self-only to isolate incompatible or failing modules during the public preview.
    function previewStrategy(address project,address account,address module,uint256 projected,uint64 maxSnapshots)
        external view returns(Income memory row) {
        if(msg.sender!=address(this)) revert Invalid();
        row.strategy=module;row.kind=kinds[module];
        if(row.kind==Kind.Unknown || module.codehash!=codeHashes[module]) return row;
        row.supported=true;
        row.collectionPaused=!registry.canExecuteStrategy(project,module);
        row.projectCollectableQuote=row.collectionPaused?0:projected;
        address quote=registry.quoteAsset(project);row.asset=quote;
        if(row.kind==Kind.Creator) {
            // Creator income is aggregated by wallet+asset across projects in this module, just like claimIncome.
            row.alreadyClaimable=IPreviewCreator(module).claimableIncome(account,quote);
            address recipient=abi.decode(registry.strategyConfig(project,module),(address));
            if(recipient==account) row.estimatedAdditional=row.projectCollectableQuote;
        } else if(row.kind==Kind.WeightedDividend) {
            if(registry.weightedDividendOf(project)!=module) revert Invalid();
            IPreviewDividend dividend=IPreviewDividend(module);
            row.asset=dividend.rewardAsset(project);
            (row.alreadyClaimable,)=dividend.claimable(project,account,maxSnapshots);
            uint256 inventory=dividend.rewardInventory(project);
            if(row.asset==quote) inventory+=row.projectCollectableQuote;
            else row.projectPendingConversionQuote=dividend.budget(project,quote,registry.currentVersion(project))+row.projectCollectableQuote;
            IPreviewWeights weights=IPreviewWeights(dividend.weightsOf(project));
            if(weights.token()!=project || weights.revenue()!=module) revert Invalid();
            uint256 last=weights.snapshotCount();
            uint256 start=dividend.lastClaimedSnapshot(project,account);
            uint256 first=weights.firstWeightSnapshot(account);
            if(first>start+1) start=first-1;
            uint256 total=weights.totalWeight();
            bool newSnapshot=inventory!=0 && total!=0 && IERC20(project).balanceOf(account)!=0 && !weights.excluded(account);
            if(newSnapshot) {
                ++last;
                if(start+maxSnapshots>=last) row.estimatedAdditional=Math.mulDiv(inventory,weights.currentWeight(account),total);
            }
            row.hasMoreSnapshots=start+maxSnapshots<last;
        }
        // Buyback budgets are project funds, never personal income.
        row.estimatedTotal=row.alreadyClaimable+row.estimatedAdditional;row.readSuccess=true;
    }
}
