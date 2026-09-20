// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IOursProjectRegistry, OursRevenueTypes as T} from "./interfaces/IOursRevenue.sol";

interface IRevenuePoolIdentity {
    function registry() external view returns (address);
    function POOL_KIND() external view returns (bytes32);
}

interface IRegisteredCurve {
    function token() external view returns (address);
    function factory() external view returns (address);
    function pairToken() external view returns (address);
    function graduated() external view returns (bool);
    function readyToGraduate() external view returns (bool);
}

/// @notice Canonical launch identity and append-only fee policies.
contract OursProjectRegistry is Ownable2Step, IOursProjectRegistry {
    error Unauthorized(); error Invalid(); error UnknownProject(); error PendingPolicy();
    struct Project {
        address curve; address quote; address controller; address pendingController;
        address hook; bytes32 poolId; uint64 active; uint64 pending; uint64 next;
    }
    address public immutable launchFactory;
    uint64 public immutable policyDelay;
    uint64 public immutable periodLength;
    address public platformRecipient;
    address public quoteSigner;
    uint64 public signerEpoch = 1;
    address public distributionReviewer;
    address public feePool;
    address public buybackPool;
    address public dividendPool;
    mapping(address => Project) private projects;
    mapping(address => mapping(uint64 => T.PolicyVersion)) private policies;
    mapping(address => mapping(uint64 => bool)) public cancelled;
    mapping(address => bool) public operators;
    mapping(address => bool) public allowedAssets;
    mapping(address => bool) public allowedAdapters;
    mapping(address => uint256) public maxBatchInput;
    mapping(address => bool) public executionPaused;
    mapping(address => uint64) public registeredAt;
    event PoolsBound(address fee, address buyback, address dividend);
    event OperatorSet(address indexed account, bool enabled);
    event AssetSet(address indexed asset, bool enabled, uint256 maxBatchInput);
    event AdapterSet(address indexed adapter, bool enabled);
    event QuoteSignerSet(address indexed signer, uint64 epoch);
    event ReviewerSet(address indexed reviewer);
    event PlatformRecipientSet(address indexed recipient);
    event ExecutionPaused(address indexed project, bool paused);

    constructor(address governance, address factory_, address treasury, address signer, address reviewer,
        uint64 delay_, uint64 period_) Ownable(governance) {
        if (factory_ == address(0) || treasury == address(0) || signer == address(0) || reviewer == address(0)
            || delay_ == 0 || period_ == 0) revert Invalid();
        launchFactory = factory_; platformRecipient = treasury; quoteSigner = signer;
        distributionReviewer = reviewer; policyDelay = delay_; periodLength = period_;
    }
    function bindPools(address fee, address buyback, address dividend) external onlyOwner {
        if (feePool != address(0) || fee.code.length == 0 || buyback.code.length == 0 || dividend.code.length == 0
            || fee == buyback || fee == dividend || buyback == dividend) revert Invalid();
        _checkPool(fee, keccak256("OURS_FEE_POOL"));
        _checkPool(buyback, keccak256("OURS_BUYBACK_POOL"));
        _checkPool(dividend, keccak256("OURS_DIVIDEND_POOL"));
        feePool = fee; buybackPool = buyback; dividendPool = dividend;
        emit PoolsBound(fee, buyback, dividend);
    }
    function _checkPool(address pool, bytes32 kind) private view {
        if (IRevenuePoolIdentity(pool).registry() != address(this)
            || IRevenuePoolIdentity(pool).POOL_KIND() != kind) revert Invalid();
    }
    function setOperator(address account, bool enabled) external onlyOwner {
        if (account == address(0)) revert Invalid(); operators[account] = enabled; emit OperatorSet(account, enabled);
    }
    function setAsset(address asset, bool enabled, uint256 cap) external onlyOwner {
        if (enabled && (cap == 0 || (asset != address(0) && asset.code.length == 0))) revert Invalid();
        allowedAssets[asset] = enabled; maxBatchInput[asset] = cap; emit AssetSet(asset, enabled, cap);
    }
    function setAdapter(address adapter, bool enabled) external onlyOwner {
        if (enabled && adapter.code.length == 0) revert Invalid();
        allowedAdapters[adapter] = enabled; emit AdapterSet(adapter, enabled);
    }
    function setQuoteSigner(address signer) external onlyOwner {
        if (signer == address(0)) revert Invalid(); quoteSigner = signer; ++signerEpoch;
        emit QuoteSignerSet(signer, signerEpoch);
    }
    function setReviewer(address reviewer) external onlyOwner {
        if (reviewer == address(0)) revert Invalid(); distributionReviewer = reviewer; emit ReviewerSet(reviewer);
    }
    function setPlatformRecipient(address recipient) external onlyOwner {
        if (recipient == address(0)) revert Invalid(); platformRecipient = recipient; emit PlatformRecipientSet(recipient);
    }
    function setExecutionPaused(address project, bool paused) external onlyOwner {
        _project(project); executionPaused[project] = paused; emit ExecutionPaused(project, paused);
    }
    function registerProject(address project, address curve, address controller, T.Policy calldata initialPolicy) external {
        if (msg.sender != launchFactory) revert Unauthorized();
        if (feePool == address(0) || project.code.length == 0 || curve.code.length == 0
            || controller == address(0) || projects[project].active != 0) revert Invalid();
        if (IRegisteredCurve(curve).token() != project || IRegisteredCurve(curve).factory() != launchFactory) revert Invalid();
        address quote = IRegisteredCurve(curve).pairToken();
        if (quote == project || !allowedAssets[quote]) revert Invalid();
        _validate(initialPolicy, project);
        projects[project] = Project(curve, quote, controller, address(0), address(0), 0, 1, 0, 2);
        registeredAt[project] = uint64(block.timestamp);
        policies[project][1] = T.PolicyVersion(initialPolicy, uint64(block.timestamp), platformRecipient);
        emit ProjectRegistered(project, curve, controller);
        emit PolicyScheduled(project, 1, uint64(block.timestamp), keccak256(abi.encode(initialPolicy, platformRecipient)));
    }
    function bindGraduatedPool(address project, bytes32 poolId, address hook) external {
        if (msg.sender != launchFactory) revert Unauthorized();
        Project storage p = _project(project);
        if (p.hook != address(0) || hook.code.length == 0 || poolId == 0 || !IRegisteredCurve(p.curve).graduated()) revert Invalid();
        p.hook = hook; p.poolId = poolId; emit PoolBound(project, poolId, hook);
    }
    function schedulePolicy(address project, T.Policy calldata policy) external returns (uint64 v) {
        Project storage p = _project(project); if (msg.sender != p.controller) revert Unauthorized();
        _advance(project, p); if (p.pending != 0) revert PendingPolicy(); _validate(policy, project);
        v = p.next++;
        uint256 boundary = ((block.timestamp + policyDelay) / periodLength + 1) * periodLength;
        if (boundary > type(uint64).max) revert Invalid();
        policies[project][v] = T.PolicyVersion(policy, uint64(boundary), platformRecipient); p.pending = v;
        emit PolicyScheduled(project, v, uint64(boundary), keccak256(abi.encode(policy, platformRecipient)));
    }
    function cancelPendingPolicy(address project) external {
        Project storage p = _project(project); if (msg.sender != p.controller) revert Unauthorized();
        if (p.pending == 0 || block.timestamp >= policies[project][p.pending].effectiveAt) revert Invalid();
        uint64 v = p.pending; cancelled[project][v] = true; p.pending = 0; emit PolicyCancelled(project, v);
    }
    function proposeController(address project, address nextController) external {
        Project storage p = _project(project); if (msg.sender != p.controller) revert Unauthorized();
        if (nextController == address(0)) revert Invalid(); p.pendingController = nextController;
        emit ControllerTransferProposed(project, nextController);
    }
    function acceptController(address project) external {
        Project storage p = _project(project); if (msg.sender != p.pendingController) revert Unauthorized();
        address prev = p.controller; p.controller = msg.sender; p.pendingController = address(0);
        emit ControllerTransferred(project, prev, msg.sender);
    }
    function currentVersion(address project) public view returns (uint64) {
        Project storage p = _project(project);
        return p.pending != 0 && block.timestamp >= policies[project][p.pending].effectiveAt ? p.pending : p.active;
    }
    function policyAt(address project, uint64 v) external view returns (T.PolicyVersion memory) {
        _project(project); T.PolicyVersion memory pv = policies[project][v];
        if (pv.effectiveAt == 0 || cancelled[project][v]) revert Invalid(); return pv;
    }
    function controllerOf(address project) external view returns (address) { return _project(project).controller; }
    function canExecute(address project, address caller) external view returns (bool) {
        return projects[project].active != 0 && (operators[caller] || projects[project].controller == caller);
    }
    function isFeeSource(address project, address source) external view returns (bool) {
        Project storage p = projects[project];
        return p.active != 0 && source != address(0) && (source == p.curve || source == p.hook);
    }
    function quoteAsset(address project) external view returns (address) { return _project(project).quote; }
    function curveOf(address project) external view returns (address) { return _project(project).curve; }
    function poolOf(address project) external view returns (bytes32, address) { Project storage p = _project(project); return (p.poolId, p.hook); }
    function isTrading(address project) external view returns (bool) {
        Project storage p = _project(project);
        if (p.hook != address(0)) return true;
        return !IRegisteredCurve(p.curve).graduated() && !IRegisteredCurve(p.curve).readyToGraduate();
    }
    function _project(address project) private view returns (Project storage p) {
        p = projects[project]; if (p.active == 0) revert UnknownProject();
    }
    function _advance(address project, Project storage p) private {
        if (p.pending != 0 && block.timestamp >= policies[project][p.pending].effectiveAt) { p.active = p.pending; p.pending = 0; }
    }
    function _validate(T.Policy calldata p, address project) private view {
        if (uint256(p.buybackBps) + p.dividendBps + p.creatorBps != 10_000 || p.creatorRecipient == address(0)) revert Invalid();
        if (p.dividendBps != 0 && (p.dividendAsset == address(0) || p.dividendAsset == project || !allowedAssets[p.dividendAsset])) revert Invalid();
    }
}

