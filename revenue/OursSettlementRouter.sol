// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {OursProjectRegistry} from "./OursProjectRegistry.sol";
import {OursFeePool} from "./OursFeePool.sol";
import {OursRevenueTypes as T} from "./interfaces/IOursRevenue.sol";
interface ISettlementSource {
    function accruedRevenue(address,address,uint64) external view returns(uint256);
    function sweepRevenue(address,address,uint64) external;
}
interface ISettlementModule {
    function collectBudget(address,uint64) external returns(uint256);
    function executeBuyback(T.ExecutionPlan calldata,bytes calldata,bytes calldata) external returns(T.ExecutionResult memory);
    function acquireReward(T.ExecutionPlan calldata,bytes calldata,bytes calldata) external returns(T.ExecutionResult memory);
    function claimIncome(address) external returns(uint256);
    function claim(address,uint64) external returns(uint256);
    function checkpoint(address) external returns(uint64);
}
/// @notice Atomic permissionless settlement; every requested action must succeed.
/// No arbitrary targets, approvals, delegatecall or custody. Registry owner may replace this entrypoint; do NOT grant it operator permissions.
contract OursSettlementRouter is ReentrancyGuard {
    error Invalid(); error Unauthorized();
    // stage: 0 = source sweep, 1 = distribution, 2 = supplied action. Action indexes are zero-based.
    error SettlementStepFailed(uint8 stage, uint256 index, address target, address asset, bytes reason, uint256 fullReasonSize);
    error InsufficientStepGas(uint8 stage, uint256 index, address target, uint256 required, uint256 available);
    error TargetCallFailed(bytes reason, uint256 fullReasonSize);
    uint256 public constant ATOMIC_SETTLEMENT_VERSION = 2;
    OursProjectRegistry public immutable registry;
    struct Action { address target; bytes data; }
    // Reserve for bounded error encoding, never a cap on a successful step.
    uint256 private constant ERROR_GAS_RESERVE = 40_000;
    event ActionResult(address indexed project,address indexed caller,uint256 indexed index,bool success);
    event Settled(address indexed project,address indexed caller,uint64 version);
    constructor(OursProjectRegistry r) { if(address(r).code.length==0) revert Invalid(); registry=r; }
    function settle(address project,Action[] calldata actions) external nonReentrant {
        if(registry.settlementRouter()!=address(this) || actions.length>16) revert Invalid();
        uint64 version=registry.currentVersion(project);address quote=registry.quoteAsset(project);
        _sweep(project,registry.curveOf(project),quote,version);
        (,address hook)=registry.poolOf(project);
        if(hook!=address(0)) { _sweep(project,hook,quote,version);_sweep(project,hook,project,version); }
        _distribute(project,quote,version);
        for(uint256 i;i<actions.length;++i) {
            Action calldata action = actions[i];
            _step(2, i, action.target, quote,
                abi.encodeCall(this.runAction, (project, version, msg.sender, action)));
            emit ActionResult(project,msg.sender,i,true);
        }
        emit Settled(project,msg.sender,version);
    }
    function _distribute(address project,address quote,uint64 version) private {
        _step(1, 0, registry.feePool(), quote,
            abi.encodeCall(this.distributeSource, (project, quote, version)));
    }
    function _step(uint8 stage,uint256 index,address target,address asset,bytes memory data) private {
        uint256 available = gasleft();
        uint256 required = ERROR_GAS_RESERVE + 5_000;
        if(available < required) revert InsufficientStepGas(stage,index,target,required,available);
        bool ok;
        // Do not let an untrusted return-data bomb consume the outer error-reporting reserve.
        address self = address(this);
        assembly ("memory-safe") { ok := call(sub(gas(),ERROR_GAS_RESERVE),self,0,add(data,32),mload(data),0,0) }
        if(!ok) {
            (bytes memory reason,uint256 size) = _failureData(4096);
            revert SettlementStepFailed(stage,index,target,asset,reason,size);
        }
    }
    function _failureData(uint256 cap) private pure returns(bytes memory reason,uint256 size) {
        assembly ("memory-safe") { size := returndatasize() }
        uint256 length = size > cap ? cap : size;
        reason = new bytes(length);
        assembly ("memory-safe") { returndatacopy(add(reason,32),0,length) }
    }
    function distributeSource(address project,address quote,uint64 version) external {
        if(msg.sender!=address(this)) revert Unauthorized();
        OursFeePool fee=OursFeePool(payable(registry.feePool()));
        if(fee.pendingFees(project,quote,version)>0) fee.distribute(project,quote,version);
    }
    function _sweep(address project,address source,address asset,uint64 version) private {
        _step(0, 0, source, asset,
            abi.encodeCall(this.sweepSource, (project, source, asset, version)));
    }
    function sweepSource(address project,address source,address asset,uint64 version) external {
        if(msg.sender!=address(this)) revert Unauthorized();
        if(ISettlementSource(source).accruedRevenue(project,asset,version)>0)
            ISettlementSource(source).sweepRevenue(project,asset,version);
    }
    function runAction(address project,uint64 version,address caller,Action calldata action) external {
        if(msg.sender!=address(this)) revert Unauthorized();
        if(action.data.length<4) revert Invalid();
        bytes4 selector=bytes4(action.data[:4]);bool normalization;
        if(action.target==registry.feePool() && selector==OursFeePool.normalizeFees.selector) {
            normalization=true;
            (T.ExecutionPlan memory p,,)=abi.decode(action.data[4:],(T.ExecutionPlan,bytes,bytes));
            if(p.project!=project || p.policyVersion!=version || !registry.canExecute(project,caller)) revert Unauthorized();
        } else {
            if(!registry.selectedStrategy(project,action.target)) revert Invalid();
            if(selector==ISettlementModule.collectBudget.selector) {
                (address p,uint64 v)=abi.decode(action.data[4:],(address,uint64));
                if(p!=project || v!=version) revert Invalid();
            } else if(selector==ISettlementModule.executeBuyback.selector || selector==ISettlementModule.acquireReward.selector) {
                (T.ExecutionPlan memory p,,)=abi.decode(action.data[4:],(T.ExecutionPlan,bytes,bytes));
                if(p.project!=project || p.policyVersion!=version || !registry.canExecute(project,caller)) revert Unauthorized();
            } else if(selector==ISettlementModule.claimIncome.selector) {
                if(abi.decode(action.data[4:],(address))!=registry.quoteAsset(project)) revert Invalid();
            } else if(selector==ISettlementModule.claim.selector) {
                (address p,)=abi.decode(action.data[4:],(address,uint64));
                if(p!=project || registry.weightedDividendOf(project)!=action.target) revert Invalid();
            } else if(selector==ISettlementModule.checkpoint.selector) {
                if(abi.decode(action.data[4:],(address))!=project || registry.weightedDividendOf(project)!=action.target) revert Invalid();
            } else revert Invalid();
        }
        // Bound failed return data; preserve enough gas to report the original custom error.
        bytes memory data=abi.encodePacked(action.data,caller);address target=action.target;bool ok;
        if(gasleft() < 15_000) revert Invalid();
        assembly ("memory-safe") { ok := call(sub(gas(),10000),target,0,add(data,32),mload(data),0,0) }
        if(!ok) {
            (bytes memory reason,uint256 size) = _failureData(2048);
            revert TargetCallFailed(reason,size);
        }
        if(normalization) _distribute(project,registry.quoteAsset(project),version);
    }
}
