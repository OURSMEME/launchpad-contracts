// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {OursStrategyRegistry} from "./OursStrategyRegistry.sol";
import {IOursRevenueStrategy} from "./interfaces/IOursRevenue.sol";
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
    error Unauthorized(); error Invalid(); error UnknownProject();
    struct Project {
        address curve; address quote; address controller; address pendingController;
        address hook; bytes32 poolId; uint64 active;
    }
    address public immutable launchFactory;
    uint64 public immutable periodLength;
    address public platformRecipient;
    address public quoteSigner;
    uint64 public signerEpoch = 1;
    address public distributionReviewer;
    address public feePool;
    OursStrategyRegistry public strategyRegistry;
    uint16 public constant PLATFORM_BPS = 3000;
    uint256 public constant MAX_STRATEGIES = 8;
    mapping(address => mapping(address => bool)) public selectedStrategy;
    mapping(address => mapping(address => bytes)) private strategyConfigs;
    mapping(address => address[]) private projectStrategies;
    mapping(address => Project) private projects;
    mapping(address => mapping(uint64 => T.PolicyVersion)) private policies;
    mapping(address => bool) public operators;
    mapping(address => bool) public allowedAssets;
    mapping(address => bool) public allowedAdapters;
    mapping(address => uint256) public maxBatchInput;
    mapping(address => bool) public executionPaused;
    mapping(address => uint64) public registeredAt;
    event FeePoolBound(address fee);
    event StrategyRegistryBound(address catalogue);
    event OperatorSet(address indexed account, bool enabled);
    event AssetSet(address indexed asset, bool enabled, uint256 maxBatchInput);
    event AdapterSet(address indexed adapter, bool enabled);
    event QuoteSignerSet(address indexed signer, uint64 epoch);
    event ReviewerSet(address indexed reviewer);
    event PlatformRecipientSet(address indexed recipient);
    event ExecutionPaused(address indexed project, bool paused);

    constructor(address governance, address factory_, address treasury, address signer, address reviewer,
        uint64 period_) Ownable(governance) {
        if (factory_ == address(0) || treasury == address(0) || signer == address(0) || reviewer == address(0)
            || period_ == 0) revert Invalid();
        launchFactory = factory_; platformRecipient = treasury; quoteSigner = signer;
        distributionReviewer = reviewer; periodLength = period_;
    }
    address public executionGuard;
    event ExecutionGuardBound(address indexed guard);
    function bindExecutionGuard(address guard) external onlyOwner {
        if (executionGuard != address(0) || guard.code.length == 0) revert Invalid();
        (bool ok, bytes memory data) = guard.staticcall(abi.encodeWithSignature("registry()"));
        if (!ok || data.length != 32 || abi.decode(data, (address)) != address(this)) revert Invalid();
        executionGuard = guard; emit ExecutionGuardBound(guard);
    }
    function bindFeePool(address fee) external onlyOwner {
        if (feePool != address(0) || fee.code.length == 0) revert Invalid();
        _checkPool(fee, keccak256("OURS_FEE_POOL")); feePool = fee; emit FeePoolBound(fee);
    }
    function bindStrategyRegistry(OursStrategyRegistry catalogue) external onlyOwner {
        if (address(strategyRegistry) != address(0) || address(catalogue).code.length == 0
            || catalogue.projectRegistry() != address(this)) revert Invalid();
        strategyRegistry = catalogue; emit StrategyRegistryBound(address(catalogue));
    }
    mapping(address => address) public weightedDividendOf;
    address public settlementRouter;
    uint256 public constant SETTLEMENT_ROUTER_CONFIG_VERSION = 1;
    event SettlementRouterSet(address indexed previousRouter, address indexed newRouter);
    /// @notice Replaces the trusted caller-forwarding entrypoint for ALL projects in this Registry.
    /// Governance must review the new router: registry() alone does not prove safe behavior.
    function setSettlementRouter(address router) external onlyOwner {
        _setSettlementRouter(router);
    }
    function _setSettlementRouter(address router) private {
        if (router.code.length == 0) revert Invalid();
        (bool ok, bytes memory data) = router.staticcall(abi.encodeWithSignature("registry()"));
        if (!ok || data.length != 32 || abi.decode(data, (address)) != address(this)) revert Invalid();
        address previous = settlementRouter;
        settlementRouter = router;
        emit SettlementRouterSet(previous, router);
    }
    function strategyConfig(address project, address module) external view returns (bytes memory) {
        if (!selectedStrategy[project][module]) revert Invalid(); return strategyConfigs[project][module];
    }
    function strategiesOf(address project) external view returns (address[] memory) {
        _project(project); return projectStrategies[project];
    }
    /// @notice Generic extension factories; launch contracts know no strategy implementation.
    function tokenObserverFactoriesOf(address project) external view returns (address[] memory result) {
        _project(project);
        address[] storage modules = projectStrategies[project];
        uint256 count;
        for (uint256 i; i < modules.length; ++i) if (strategyRegistry.tokenObserverFactory(modules[i])) ++count;
        result = new address[](count);
        uint256 next;
        for (uint256 i; i < modules.length; ++i) if (strategyRegistry.tokenObserverFactory(modules[i])) result[next++] = modules[i];
    }
    function canExecuteStrategy(address project, address module) public view returns (bool) {
        return selectedStrategy[project][module] && !executionPaused[project] && strategyRegistry.executable(module);
    }
    function canSwap(address project, address caller) external view returns (bool) {
        return projects[project].active != 0 && !executionPaused[project]
            && (caller == feePool || canExecuteStrategy(project, caller));
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
        _validateAndStore(initialPolicy, project, quote);
        projects[project] = Project(curve, quote, controller, address(0), address(0), 0, 1);
        registeredAt[project] = uint64(block.timestamp);
        policies[project][1] = T.PolicyVersion(initialPolicy, uint64(block.timestamp), platformRecipient, PLATFORM_BPS);
        emit ProjectRegistered(project, curve, controller);
        emit PolicyLocked(project, 1, keccak256(abi.encode(initialPolicy, platformRecipient, PLATFORM_BPS)));
    }
    function bindGraduatedPool(address project, bytes32 poolId, address hook) external {
        if (msg.sender != launchFactory) revert Unauthorized();
        Project storage p = _project(project);
        if (p.hook != address(0) || hook.code.length == 0 || poolId == 0 || !IRegisteredCurve(p.curve).graduated()) revert Invalid();
        p.hook = hook; p.poolId = poolId; emit PoolBound(project, poolId, hook);
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
    function currentVersion(address project) public view returns (uint64) { _project(project); return 1; }
    function policyAt(address project, uint64 v) external view returns (T.PolicyVersion memory) {
        _project(project); if (v != 1) revert Invalid(); return policies[project][v];
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
    function _validateAndStore(T.Policy calldata policy, address project, address quote) private {
        uint256 count = policy.strategies.length;
        if (address(strategyRegistry) == address(0) || count == 0 || count > MAX_STRATEGIES) revert Invalid();
        uint256 total;
        for (uint256 i; i < count; ++i) {
            T.StrategyAllocation calldata item = policy.strategies[i];
            address module = strategyRegistry.resolveForLaunch(item.strategyId);
            if (item.weightBps == 0 || item.config.length > 2048 || selectedStrategy[project][module]) revert Invalid();
            IOursRevenueStrategy(module).validateConfig(project, quote, item.config);
            if (strategyRegistry.weightedDividend(module)) {
                if (weightedDividendOf[project] != address(0)) revert Invalid();
                weightedDividendOf[project] = module;
            }
            selectedStrategy[project][module] = true; strategyConfigs[project][module] = item.config;
            projectStrategies[project].push(module); total += item.weightBps;
        }
        if (total != 10_000) revert Invalid();
    }
}
