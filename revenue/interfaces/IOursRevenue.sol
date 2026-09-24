// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Revenue system ABI; implementations live beside this file.
/// @dev On each chain project = registered meme token address; never its symbol.
library OursRevenueTypes {
    uint8 internal constant NORMALIZE_FEES = 0;
    uint8 internal constant BUYBACK = 1;
    uint8 internal constant ACQUIRE_DIVIDEND = 2;

    struct StrategyAllocation {
        bytes32 strategyId;
        uint16 weightBps;
        bytes config;
    }

    struct Policy { StrategyAllocation[] strategies; }

    struct PolicyVersion {
        Policy policy;
        uint64 effectiveAt;
        address platformRecipient; // Snapshotted at launch.
        uint16 platformBps;
    }

    /// @dev EIP-712 domain also binds chainId and the receiving pool address.
    struct ExecutionPlan {
        address project;
        uint64 policyVersion;
        uint8 purpose;
        address adapter;
        bytes32 routeHash;
        address assetIn;
        address assetOut;
        uint256 maxAmountIn;
        uint256 minAmountOut;
        uint64 deadline;
        uint256 nonce;
        uint64 signerEpoch;
    }

    struct ExecutionResult {
        uint256 actualSpent;
        uint256 actualReceived;
    }


}

interface IOursProjectRegistry {
    event ProjectRegistered(address indexed project, address indexed curve, address indexed controller);
    event PolicyLocked(address indexed project, uint64 indexed version, bytes32 policyHash);
    event ControllerTransferProposed(address indexed project, address indexed nextController);
    event ControllerTransferred(address indexed project, address previousController, address nextController);
    event PoolBound(address indexed project, bytes32 indexed poolId, address indexed hook);

    /// @dev Only immutable trusted launch factory; verifies canonical token/curve.
    function registerProject(
        address project, address curve, address controller,
        OursRevenueTypes.Policy calldata initialPolicy
    ) external;
    /// @dev Only registered factory; exact canonical PoolKey must be verified.
    function bindGraduatedPool(address project, bytes32 poolId, address hook) external;
    function proposeController(address project, address nextController) external;
    function acceptController(address project) external;
    function currentVersion(address project) external view returns (uint64);
    function policyAt(address project, uint64 version) external view returns (OursRevenueTypes.PolicyVersion memory);
    function controllerOf(address project) external view returns (address);
    function canExecute(address project, address caller) external view returns (bool);
    function isFeeSource(address project, address source) external view returns (bool);
}

interface IOursFeePool {
    event FeesCredited(address indexed project, address indexed asset, uint64 indexed version, address source, uint256 amount);
    event FeesDistributed(address indexed project, address indexed asset, uint64 indexed version,
        uint256 gross, uint256 platformAmount, uint256 strategyAmount, uint256 roundingReserve);
    event StrategyBudgetAllocated(address indexed project, address indexed strategy, address indexed asset, uint256 amount);
    event StrategyBudgetClaimed(address indexed project, address indexed strategy, address indexed asset, uint256 amount);
    function claimStrategyBudget(address project, address asset, uint64 version) external returns (uint256);
    event IncomeClaimed(address indexed recipient, address indexed asset, uint256 amount);
    event FeesNormalized(address indexed project, uint64 indexed version, address assetIn, address assetOut, uint256 spent, uint256 received);

    /// @dev Only registered source; source supplies its historical accrual version.
    /// Pool pulls ERC20 or validates exact msg.value. Source is modified Curve/Hook.
    function creditFees(address project, address asset, uint64 version, uint256 amount) external payable;
    /// @dev Includes only normalized project quote asset. No AMM calls.
    function distribute(address project, address quoteAsset, uint64 version) external;
    /// @dev Converts raw Hook meme fees; retains same version. No allocation here.
    function normalizeFees(OursRevenueTypes.ExecutionPlan calldata plan, bytes calldata route, bytes calldata signature)
        external returns (OursRevenueTypes.ExecutionResult memory);
    /// @dev msg.sender's entire available income, sent only to msg.sender.
    function claimIncome(address asset) external returns (uint256 amount);
    function pendingFees(address project, address asset, uint64 version) external view returns (uint256);
    function claimableIncome(address recipient, address asset) external view returns (uint256);
}

interface IOursCappedBuybackStrateg {
    event BudgetReceived(address indexed project, address indexed asset, uint64 indexed version, uint256 amount);
    event BuybackExecuted(address indexed project, uint64 indexed version, uint256 indexed nonce, uint256 spent, uint256 burned);

    /// @dev Controller/operator triggers this module to pull its own FeePool budget.
    function collectBudget(address project, uint64 version) external returns (uint256 amount);
    /// @dev Proposed v1 disposal is burn(), not a transfer to a label/address.
    function executeBuyback(OursRevenueTypes.ExecutionPlan calldata plan, bytes calldata route, bytes calldata signature)
        external returns (OursRevenueTypes.ExecutionResult memory);
    function budget(address project, address asset, uint64 version) external view returns (uint256);
}

interface IOursWeightedDividendStrategy {
    function collectBudget(address project,uint64 version) external returns(uint256);
    function acquireReward(OursRevenueTypes.ExecutionPlan calldata plan,bytes calldata route,bytes calldata signature) external returns(OursRevenueTypes.ExecutionResult memory);
    function checkpoint(address project) external returns(uint64);
    function claim(address project,uint64 maxSnapshots) external returns(uint256);
    function claimable(address project,address account,uint64 maxSnapshots) external view returns(uint256,uint64);
}

interface IOursSwapAdapter {
    /// @dev Only bound pool callers, fixed recipient = msg.sender. Never delegatecall.
    /// Pulls at most maxAmountIn, delivers output/refund before returning.
    /// Pools independently measure balances; return values are not accounting proof.
    function execute(
        address project, address assetIn, address assetOut,
        uint256 maxAmountIn, uint256 minAmountOut, bytes calldata route
    ) external payable returns (OursRevenueTypes.ExecutionResult memory);
}


interface IOursRevenueStrategy {
    function registry() external view returns (address);
    function validateConfig(address project, address quote, bytes calldata config) external view;
    function collectBudget(address project, uint64 version) external returns (uint256 amount);
}
