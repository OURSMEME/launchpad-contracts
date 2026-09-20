// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RevenueBase} from "./base/RevenueBase.sol";
import {OursProjectRegistry} from "./OursProjectRegistry.sol";
import {OursRevenueTypes as T, IOursBuybackPool} from "./interfaces/IOursRevenue.sol";
interface IBurnable { function burn(uint256 amount) external; }
contract OursBuybackPool is RevenueBase, IOursBuybackPool {
    bytes32 public constant POOL_KIND = keccak256("OURS_BUYBACK_POOL");
    mapping(address => mapping(address => mapping(uint64 => uint256))) public budget;
    constructor(OursProjectRegistry r) RevenueBase(r, "OURS BuybackPool") {}
    function fund(address project, address asset, uint64 version, uint256 amount) external payable nonReentrant {
        if (msg.sender != registry.feePool() || address(this) != registry.buybackPool()) revert Unauthorized();
        T.PolicyVersion memory pv = _policy(project, version);
        if (!pv.policy.enabled || pv.policy.buybackBps == 0 || asset != registry.quoteAsset(project)) revert Invalid();
        _receiveExact(asset, amount); budget[project][asset][version] += amount; emit BudgetReceived(project, asset, version, amount);
    }
    function executeBuyback(T.ExecutionPlan calldata p, bytes calldata route, bytes calldata sig)
        external nonReentrant executor(p.project) returns (T.ExecutionResult memory r) {
        r = _swap(p, route, sig, T.Purpose.Buyback, registry.quoteAsset(p.project), p.project, budget[p.project][p.assetIn][p.policyVersion]);
        budget[p.project][p.assetIn][p.policyVersion] -= r.actualSpent;
        uint256 bal = _balance(p.project); uint256 supply = IERC20(p.project).totalSupply();
        IBurnable(p.project).burn(r.actualReceived);
        if (_balance(p.project) + r.actualReceived != bal || IERC20(p.project).totalSupply() + r.actualReceived != supply) revert TransferMismatch();
        totalLiability[p.project] -= r.actualReceived;
        emit BuybackExecuted(p.project, p.policyVersion, p.nonce, r.actualSpent, r.actualReceived);
    }
}

