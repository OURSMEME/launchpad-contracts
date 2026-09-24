// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {RevenueBase} from "./base/RevenueBase.sol";
import {OursProjectRegistry} from "./OursProjectRegistry.sol";
import {OursRevenueTypes as T, IOursFeePool} from "./interfaces/IOursRevenue.sol";

/// @notice Custodies fees and allocates budgets without calling strategy code.
contract OursFeePool is RevenueBase, IOursFeePool {
    bytes32 public constant POOL_KIND = keccak256("OURS_FEE_POOL");
    struct Totals { uint256 gross; uint256 platform; uint256 strategies; uint256 dust; }
    mapping(address => mapping(address => mapping(uint64 => uint256))) public pendingFees;
    mapping(address => mapping(address => uint256)) public claimableIncome;
    mapping(address => mapping(uint64 => Totals)) public totals;
    mapping(address => mapping(address => uint256)) public strategyAllocated;
    mapping(address => mapping(address => mapping(address => uint256))) public strategyClaimable;
    constructor(OursProjectRegistry r) RevenueBase(r, "OURS FeePool") {}
    function creditFees(address project, address asset, uint64 version, uint256 amount) external payable nonReentrant {
        if (!registry.isFeeSource(project, msg.sender) || address(this) != registry.feePool()) revert Unauthorized();
        _policy(project, version);
        if (asset != project && asset != registry.quoteAsset(project)) revert Invalid();
        _receiveExact(asset, amount); pendingFees[project][asset][version] += amount;
        emit FeesCredited(project, asset, version, msg.sender, amount);
    }
    function normalizeFees(T.ExecutionPlan calldata p, bytes calldata route, bytes calldata sig)
        external nonReentrant executor(p.project) returns (T.ExecutionResult memory r) {
        r = _swap(p, route, sig, T.NORMALIZE_FEES, p.project, registry.quoteAsset(p.project), pendingFees[p.project][p.project][p.policyVersion]);
        pendingFees[p.project][p.project][p.policyVersion] -= r.actualSpent;
        pendingFees[p.project][p.assetOut][p.policyVersion] += r.actualReceived;
        emit FeesNormalized(p.project, p.policyVersion, p.assetIn, p.assetOut, r.actualSpent, r.actualReceived);
    }
    function distribute(address project, address asset, uint64 version) external nonReentrant {
        if (asset != registry.quoteAsset(project)) revert Invalid();
        T.PolicyVersion memory pv = _policy(project, version);
        uint256 amount = pendingFees[project][asset][version]; if (amount == 0) revert Insufficient();
        pendingFees[project][asset][version] = 0;
        Totals memory old = totals[project][version]; Totals memory n;
        n.gross = old.gross + amount; n.platform = Math.mulDiv(n.gross, pv.platformBps, 10_000);
        uint256 rest = n.gross - n.platform;
        address[] memory modules = registry.strategiesOf(project);
        for (uint256 i; i < modules.length; ++i) {
            uint256 target = Math.mulDiv(rest, pv.policy.strategies[i].weightBps, 10_000);
            uint256 added = target - strategyAllocated[project][modules[i]];
            strategyAllocated[project][modules[i]] = target;
            strategyClaimable[project][modules[i]][asset] += added; n.strategies += target;
            emit StrategyBudgetAllocated(project, modules[i], asset, added);
        }
        n.dust = rest - n.strategies; totals[project][version] = n;
        claimableIncome[pv.platformRecipient][asset] += n.platform - old.platform;
        emit FeesDistributed(project, asset, version, amount, n.platform-old.platform, n.strategies-old.strategies, n.dust);
    }
    function claimStrategyBudget(address project, address asset, uint64 version) external nonReentrant returns (uint256 amount) {
        _policy(project, version);
        if (!registry.canExecuteStrategy(project, msg.sender) || asset != registry.quoteAsset(project)) revert Unauthorized();
        amount = strategyClaimable[project][msg.sender][asset]; if (amount == 0) revert Insufficient();
        strategyClaimable[project][msg.sender][asset] = 0; _send(asset, msg.sender, amount);
        emit StrategyBudgetClaimed(project, msg.sender, asset, amount);
    }
    function claimIncome(address asset) external nonReentrant returns (uint256 amount) {
        amount = claimableIncome[msg.sender][asset]; if (amount == 0) revert Insufficient();
        claimableIncome[msg.sender][asset] = 0; _send(asset, msg.sender, amount); emit IncomeClaimed(msg.sender, asset, amount);
    }
}
