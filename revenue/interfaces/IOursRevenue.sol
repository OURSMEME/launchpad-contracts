// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Revenue system ABI; implementations live beside this file.
/// @dev On each chain project = registered meme token address; never its symbol.
library OursRevenueTypes {
    enum Purpose { NormalizeFees, Buyback, AcquireDividend }
    enum EpochStatus { Unset, Funded, Proposed, Active, Cancelled }

    struct Policy {
        bool enabled;
        uint16 buybackBps;
        uint16 dividendBps;
        uint16 creatorBps;
        address creatorRecipient;
        address dividendAsset;
        uint256 minHolding; // Raw meme token units at the scheduled snapshot.
    }

    struct PolicyVersion {
        Policy policy;
        uint64 effectiveAt;
        address platformRecipient; // Historical fees keep their original payee.
    }

    /// @dev EIP-712 domain also binds chainId and the receiving pool address.
    struct ExecutionPlan {
        address project;
        uint64 policyVersion;
        Purpose purpose;
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

    struct Epoch {
        address project;
        uint64 policyVersion;
        address rewardAsset;
        uint64 period;
        uint64 snapshotBlock;
        bytes32 snapshotBlockHash;
        uint256 minHolding;
        uint256 fundedAmount;
        uint256 totalEntitlement;
        uint256 claimedAmount;
        bytes32 merkleRoot;
        bytes32 manifestHash;
        uint64 claimableAt;
        EpochStatus status;
    }
}

interface IOursProjectRegistry {
    event ProjectRegistered(address indexed project, address indexed curve, address indexed controller);
    event PolicyScheduled(address indexed project, uint64 indexed version, uint64 effectiveAt, bytes32 policyHash);
    event PolicyCancelled(address indexed project, uint64 indexed version);
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
    function schedulePolicy(address project, OursRevenueTypes.Policy calldata policy) external returns (uint64 version);
    function cancelPendingPolicy(address project) external;
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
    event FeesDistributed(
        address indexed project, address indexed asset, uint64 indexed version,
        uint256 gross, uint256 platformAmount, uint256 buybackAmount,
        uint256 dividendAmount, uint256 creatorAmount, uint256 roundingReserve
    );
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

interface IOursBuybackPool {
    event BudgetReceived(address indexed project, address indexed asset, uint64 indexed version, uint256 amount);
    event BuybackExecuted(address indexed project, uint64 indexed version, uint256 indexed nonce, uint256 spent, uint256 burned);

    /// @dev Only immutable FeePool; pull exact funding, no public bookkeeping credit.
    function fund(address project, address asset, uint64 version, uint256 amount) external payable;
    /// @dev Proposed v1 disposal is burn(), not a transfer to a label/address.
    function executeBuyback(OursRevenueTypes.ExecutionPlan calldata plan, bytes calldata route, bytes calldata signature)
        external returns (OursRevenueTypes.ExecutionResult memory);
    function budget(address project, address asset, uint64 version) external view returns (uint256);
}

interface IOursDividendPool {
    event BudgetReceived(address indexed project, address indexed asset, uint64 indexed version, uint256 amount);
    event RewardAcquired(address indexed project, uint64 indexed version, uint256 indexed nonce, uint256 spent, uint256 received);
    event EpochFunded(bytes32 indexed epochId, address indexed project, uint64 indexed version, uint256 amount, uint64 snapshotBlock);
    event DistributionProposed(bytes32 indexed epochId, bytes32 root, bytes32 manifestHash, uint256 totalEntitlement, uint64 claimableAt);
    event EpochActivated(bytes32 indexed epochId);
    event SnapshotRecorded(address indexed project, uint64 indexed period, uint64 blockNumber, bytes32 blockHash);
    event EmptyEpochRolled(bytes32 indexed epochId, bytes32 eligibilityManifestHash);
    event DistributionCancelled(bytes32 indexed epochId);
    event DividendClaimed(bytes32 indexed epochId, address indexed account, uint256 amount);

    function fund(address project, address asset, uint64 version, uint256 amount) external payable;
    function acquireReward(OursRevenueTypes.ExecutionPlan calldata plan, bytes calldata route, bytes calldata signature)
        external returns (OursRevenueTypes.ExecutionResult memory);
    /// @dev Distribution reviewer only; once per project/period, public schedule.
    function recordSnapshot(address project, uint64 period, uint64 blockNumber, bytes32 blockHash) external;
    /// @dev Reviewer only; no live root/claims, funds return to same version inventory.
    function rollEmptyEpoch(bytes32 epochId, bytes32 eligibilityManifestHash) external;
    /// @dev Derive period/snapshot from immutable schedule, not caller preference.
    /// Locks this period's acquired rewards; new-period arrivals never delay old claims.
    function fundEpoch(address project, uint64 version, uint64 period) external returns (bytes32 epochId);
    /// @dev Separate distribution-review multisig only; no creator/operator role.
    function proposeDistribution(bytes32 epochId, bytes32 root, bytes32 manifestHash, uint256 totalEntitlement) external;
    /// @dev Review multisig only, before activation. Funds stay reserved for epoch.
    function cancelDistribution(bytes32 epochId) external;
    /// @dev Permissionless after review delay and subject to epoch validity.
    function activateEpoch(bytes32 epochId) external;
    /// @dev Caller == beneficiary. No arbitrary recipient argument.
    function claim(bytes32 epochId, uint256 entitlement, bytes32[] calldata proof) external returns (uint256 amount);
    function epoch(bytes32 epochId) external view returns (OursRevenueTypes.Epoch memory);
    function claimed(bytes32 epochId, address account) external view returns (uint256);
    function rewardInventory(address project, uint64 version) external view returns (uint256);
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

