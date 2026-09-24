// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {RevenueBase} from "../revenue/base/RevenueBase.sol";
import {OursProjectRegistry} from "../revenue/OursProjectRegistry.sol";
import {IOursFeePool} from "../revenue/interfaces/IOursRevenue.sol";

contract FailingRevenueStrategy is RevenueBase {
    constructor(OursProjectRegistry r) RevenueBase(r, "Failing strategy") {}
    function validateConfig(address, address, bytes calldata config) external pure { require(config.length == 0); }
    function collectBudget(address project, uint64 version) external nonReentrant executor(project) returns (uint256) {
        _collectBudget(project, version); revert("STRATEGY_FAILURE");
    }
}
contract ReentrantRevenueStrategy {
    OursProjectRegistry public immutable registry;
    address private project_; uint64 private version_;
    constructor(OursProjectRegistry r) { registry = r; }
    function validateConfig(address, address, bytes calldata config) external pure { require(config.length == 0); }
    function collectBudget(address project, uint64 version) external returns (uint256) {
        require(registry.canExecute(project, msg.sender)); project_ = project; version_ = version;
        return IOursFeePool(registry.feePool()).claimStrategyBudget(project, address(0), version);
    }
    receive() external payable {
        IOursFeePool(registry.feePool()).claimStrategyBudget(project_, address(0), version_);
    }
}
