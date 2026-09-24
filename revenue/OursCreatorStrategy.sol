// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {RevenueBase} from "./base/RevenueBase.sol";
import {OursProjectRegistry} from "./OursProjectRegistry.sol";

/// @notice Fixed per-project recipient; only that wallet can claim its income.
contract OursCreatorStrategy is RevenueBase {
    mapping(address => mapping(address => uint256)) public claimableIncome;
    event BudgetCollected(address indexed project, address indexed asset, address indexed recipient, uint256 amount);
    event IncomeClaimed(address indexed recipient, address indexed asset, uint256 amount);
    constructor(OursProjectRegistry r) RevenueBase(r, "OURS CreatorStrategy") {}
    function validateConfig(address, address, bytes calldata config) external pure {
        if (config.length != 32 || abi.decode(config, (address)) == address(0)) revert Invalid();
    }
    // Anyone may move the fixed budget; _collectBudget still checks selection and pause state.
    function collectBudget(address project, uint64 version) external nonReentrant returns (uint256 amount) {
        address asset; (asset, amount) = _collectBudget(project, version);
        address recipient = abi.decode(registry.strategyConfig(project, address(this)), (address));
        claimableIncome[recipient][asset] += amount; emit BudgetCollected(project, asset, recipient, amount);
    }
    function claimIncome(address asset) external nonReentrant returns (uint256 amount) {
        address recipient = _revenueSender();
        amount = claimableIncome[recipient][asset]; if (amount == 0) revert Insufficient();
        claimableIncome[recipient][asset] = 0; _send(asset, recipient, amount);
        emit IncomeClaimed(recipient, asset, amount);
    }
}
