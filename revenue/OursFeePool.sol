// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {RevenueBase} from "./base/RevenueBase.sol";
import {OursProjectRegistry} from "./OursProjectRegistry.sol";
import {OursRevenueTypes as T, IOursFeePool} from "./interfaces/IOursRevenue.sol";
interface IBudgetPool { function fund(address project, address asset, uint64 version, uint256 amount) external payable; }
contract OursFeePool is RevenueBase, IOursFeePool {
    bytes32 public constant POOL_KIND = keccak256("OURS_FEE_POOL");
    using SafeERC20 for IERC20;
    struct Totals { uint256 gross; uint256 platform; uint256 buyback; uint256 dividend; uint256 creator; uint256 dust; }
    mapping(address => mapping(address => mapping(uint64 => uint256))) public pendingFees;
    mapping(address => mapping(address => uint256)) public claimableIncome;
    mapping(address => mapping(uint64 => Totals)) public totals;
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
        r = _swap(p, route, sig, T.Purpose.NormalizeFees, p.project, registry.quoteAsset(p.project), pendingFees[p.project][p.project][p.policyVersion]);
        pendingFees[p.project][p.project][p.policyVersion] -= r.actualSpent;
        pendingFees[p.project][p.assetOut][p.policyVersion] += r.actualReceived;
        emit FeesNormalized(p.project, p.policyVersion, p.assetIn, p.assetOut, r.actualSpent, r.actualReceived);
    }
    function distribute(address project, address asset, uint64 version) external nonReentrant executor(project) {
        if (asset != registry.quoteAsset(project)) revert Invalid();
        T.PolicyVersion memory pv = _policy(project, version);
        uint256 amount = pendingFees[project][asset][version]; if (amount == 0) revert Insufficient();
        pendingFees[project][asset][version] = 0;
        Totals memory old = totals[project][version]; Totals memory n;
        n.gross = old.gross + amount;
        if (!pv.policy.enabled) n.platform = n.gross;
        else {
            n.platform = Math.mulDiv(n.gross, 3000, 10_000);
            uint256 rest = n.gross - n.platform;
            n.buyback = Math.mulDiv(rest, pv.policy.buybackBps, 10_000);
            n.dividend = Math.mulDiv(rest, pv.policy.dividendBps, 10_000);
            n.creator = Math.mulDiv(rest, pv.policy.creatorBps, 10_000);
            n.dust = rest - n.buyback - n.dividend - n.creator;
        }
        totals[project][version] = n;
        claimableIncome[pv.platformRecipient][asset] += n.platform - old.platform;
        claimableIncome[pv.policy.creatorRecipient][asset] += n.creator - old.creator;
        _fund(registry.buybackPool(), project, asset, version, n.buyback - old.buyback);
        _fund(registry.dividendPool(), project, asset, version, n.dividend - old.dividend);
        emit FeesDistributed(project, asset, version, amount, n.platform-old.platform, n.buyback-old.buyback,
            n.dividend-old.dividend, n.creator-old.creator, n.dust);
    }
    function claimIncome(address asset) external nonReentrant returns (uint256 amount) {
        amount = claimableIncome[msg.sender][asset]; if (amount == 0) revert Insufficient();
        claimableIncome[msg.sender][asset] = 0; _send(asset, msg.sender, amount); emit IncomeClaimed(msg.sender, asset, amount);
    }
    function _fund(address pool, address project, address asset, uint64 version, uint256 amount) private {
        if (amount == 0) return;
        if (pool == address(0)) revert Invalid();
        uint256 before_ = _balance(asset); totalLiability[asset] -= amount;
        if (asset != address(0)) IERC20(asset).forceApprove(pool, amount);
        IBudgetPool(pool).fund{value:asset == address(0) ? amount : 0}(project, asset, version, amount);
        if (asset != address(0)) IERC20(asset).forceApprove(pool, 0);
        if (_balance(asset) + amount != before_) revert TransferMismatch();
    }
}

