// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IGuardRegistry {
    function feePool() external view returns (address);
    function canSwap(address project, address caller) external view returns (bool);
    function quoteSigner() external view returns (address);
}
interface IGuardTreasury {
    function feePool() external view returns (address);
    function quoteSigner() external view returns (address);
}

/// @notice Fail-closed price and aggregate spending checks for protocol swaps.
/// @dev Reference rates are independently reported, NOT a trustless on-chain TWAP.
/// Reporter must derive an average from historical data, including fees in the allowed deviation.
contract OursExecutionGuard is Ownable2Step {
    error Invalid(); error Unauthorized(); error PriceUnavailable(); error UnsafePrice(); error LimitExceeded();
    struct Reference { uint256 rateX36; uint64 observedAt; uint64 window; uint64 publishedBlock; uint64 reporterEpoch; bytes32 evidence; }
    struct PriceRule { uint16 maxDeviationBps; uint32 maxAge; uint32 minWindow; }
    struct SpendRule { uint256 maxBatch; uint256 maxRollingDay; uint32 cooldown; }
    IGuardRegistry public immutable registry;
    address public reporter;
    uint64 public reporterEpoch;
    address public platformTreasury;
    uint256 public constant MAX_PLAN_LIFETIME = 300;
    mapping(bytes32 => Reference) public references;
    mapping(bytes32 => PriceRule) public priceRules;
    mapping(bytes32 => SpendRule) public spendRules;
    mapping(bytes32 => mapping(uint256 => uint256)) public hourlySpent;
    mapping(bytes32 => uint256) public lastExecution;
    event ReporterSet(address indexed reporter);
    event TreasuryBound(address indexed treasury);
    event ReferencePublished(bytes32 indexed pair, uint256 rateX36, uint64 observedAt, uint64 window, bytes32 evidence);
    event PriceRuleSet(bytes32 indexed pair, PriceRule rule);
    event SpendRuleSet(bytes32 indexed key, SpendRule rule);
    event SpendRecorded(bytes32 indexed key, uint256 spent, uint256 received);

    constructor(address governance, IGuardRegistry registry_) Ownable(governance) {
        if (address(registry_).code.length == 0) revert Invalid();
        registry = registry_;
    }
    function renounceOwnership() public override onlyOwner { revert Invalid(); }
    function bindTreasury(address treasury) external onlyOwner {
        if (platformTreasury != address(0) || treasury.code.length == 0
            || IGuardTreasury(treasury).feePool() != registry.feePool()) revert Invalid();
        platformTreasury = treasury; emit TreasuryBound(treasury);
    }
    function setReporter(address account) external onlyOwner {
        if (account == address(0) || account == registry.quoteSigner()
            || (platformTreasury != address(0) && account == IGuardTreasury(platformTreasury).quoteSigner())) revert Invalid();
        reporter = account; ++reporterEpoch; emit ReporterSet(account);
    }
    function pairId(address assetIn, address assetOut) public pure returns (bytes32) {
        return keccak256(abi.encode(assetIn, assetOut));
    }
    function spendId(address scope, address assetIn) public pure returns (bytes32) {
        return keccak256(abi.encode(scope, assetIn));
    }
    function setPriceRule(address assetIn, address assetOut, PriceRule calldata rule) external onlyOwner {
        if (assetIn == assetOut || rule.maxDeviationBps > 2000 || rule.maxAge == 0 || rule.maxAge > 3600
            || rule.minWindow < 300) revert Invalid();
        bytes32 id = pairId(assetIn, assetOut); priceRules[id] = rule; emit PriceRuleSet(id, rule);
    }
    function setSpendRule(address scope, address assetIn, SpendRule calldata rule) external onlyOwner {
        if (scope == address(0) || rule.maxBatch == 0 || rule.maxRollingDay < rule.maxBatch || rule.cooldown == 0) revert Invalid();
        bytes32 id = spendId(scope, assetIn); spendRules[id] = rule; emit SpendRuleSet(id, rule);
    }
    /// @param rateX36 Raw output units per raw input unit, scaled by 1e36. Directions are separate.
    function publishReference(address assetIn, address assetOut, uint256 rateX36,
        uint64 observedAt, uint64 window, bytes32 evidence) external {
        if (msg.sender != reporter || reporter == registry.quoteSigner()
            || (platformTreasury != address(0) && reporter == IGuardTreasury(platformTreasury).quoteSigner())) revert Unauthorized();
        bytes32 id = pairId(assetIn, assetOut); PriceRule memory rule = priceRules[id];
        if (rule.maxAge == 0 || rateX36 == 0 || observedAt >= block.timestamp || window < rule.minWindow
            || window > observedAt || block.timestamp - observedAt > rule.maxAge || evidence == 0
            || observedAt <= references[id].observedAt) revert Invalid();
        references[id] = Reference(rateX36, observedAt, window, uint64(block.number), reporterEpoch, evidence);
        emit ReferencePublished(id, rateX36, observedAt, window, evidence);
    }
    function minimumOutput(address assetIn, address assetOut, uint256 amount) public view returns (uint256) {
        bytes32 id = pairId(assetIn, assetOut); Reference memory ref = references[id]; PriceRule memory rule = priceRules[id];
        if (reporter == address(0) || reporter == registry.quoteSigner()
            || (platformTreasury != address(0) && reporter == IGuardTreasury(platformTreasury).quoteSigner())
            || ref.reporterEpoch != reporterEpoch || ref.rateX36 == 0 || ref.publishedBlock >= block.number || rule.maxAge == 0
            || ref.window < rule.minWindow || block.timestamp - ref.observedAt > rule.maxAge) revert PriceUnavailable();
        uint256 fair = Math.mulDiv(amount, ref.rateX36, 1e36, Math.Rounding.Ceil);
        return Math.mulDiv(fair, 10000 - rule.maxDeviationBps, 10000, Math.Rounding.Ceil);
    }
    /// @dev Current hour plus previous 24 hours: conservative rolling cap, never a midnight reset.
    function rollingSpent(address scope, address assetIn) public view returns (uint256 total) {
        bytes32 id = spendId(scope, assetIn); uint256 hour = block.timestamp / 1 hours;
        for (uint256 i; i <= 24 && i <= hour; ++i) total += hourlySpent[id][hour-i];
    }
    function validate(address scope, address assetIn, address assetOut, uint256 maximum,
        uint256 minimum, uint64 deadline) external view {
        if (deadline < block.timestamp || deadline > block.timestamp + MAX_PLAN_LIFETIME || maximum == 0
            || minimum < minimumOutput(assetIn, assetOut, maximum)) revert UnsafePrice();
        _checkSpend(scope, assetIn, maximum);
    }
    function _checkSpend(address scope, address assetIn, uint256 amount) private view {
        bytes32 id = spendId(scope, assetIn); SpendRule memory rule = spendRules[id];
        if (amount == 0 || amount > rule.maxBatch || rollingSpent(scope, assetIn) + amount > rule.maxRollingDay
            || (lastExecution[id] != 0 && block.timestamp < lastExecution[id] + rule.cooldown)) revert LimitExceeded();
    }
    function record(address scope, address assetIn, address assetOut, uint256 spent, uint256 received) external {
        bool projectPool = registry.canSwap(scope, msg.sender);
        if (!projectPool && (msg.sender != platformTreasury || scope != platformTreasury)) revert Unauthorized();
        if (received < minimumOutput(assetIn, assetOut, spent)) revert UnsafePrice();
        _checkSpend(scope, assetIn, spent);
        bytes32 id = spendId(scope, assetIn);
        hourlySpent[id][block.timestamp / 1 hours] += spent; lastExecution[id] = block.timestamp;
        emit SpendRecorded(id, spent, received);
    }
}
