// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {RevenueBase} from "./base/RevenueBase.sol";
import {OursProjectRegistry} from "./OursProjectRegistry.sol";
import {OursRevenueTypes as T, IOursDividendPool} from "./interfaces/IOursRevenue.sol";

/// @notice Pull-only rewards: no iteration over holders and no mass airdrop.
/// @dev The independent reviewer attests off-chain holdings and root correctness.
contract OursDividendPool is RevenueBase, IOursDividendPool {
    bytes32 public constant POOL_KIND = keccak256("OURS_DIVIDEND_POOL");
    struct Snapshot { uint64 blockNumber; bytes32 blockHash; }
    uint64 public immutable reviewDelay;
    mapping(address => mapping(address => mapping(uint64 => uint256))) public budget;
    mapping(address => mapping(uint64 => uint256)) public rewardInventory;
    mapping(address => mapping(uint64 => mapping(uint64 => uint256))) public rewardByPeriod;
    mapping(address => mapping(uint64 => Snapshot)) public snapshots;
    mapping(bytes32 => T.Epoch) private epochs;
    mapping(bytes32 => mapping(address => uint256)) public claimed;
    constructor(OursProjectRegistry r, uint64 delay_) RevenueBase(r, "OURS DividendPool") {
        if (delay_ == 0) revert Invalid(); reviewDelay = delay_;
    }
    modifier reviewer() { if (msg.sender != registry.distributionReviewer()) revert Unauthorized(); _; }
    function fund(address project, address asset, uint64 version, uint256 amount) external payable nonReentrant {
        if (msg.sender != registry.feePool() || address(this) != registry.dividendPool()) revert Unauthorized();
        T.PolicyVersion memory pv = _policy(project, version);
        if (!pv.policy.enabled || pv.policy.dividendBps == 0 || asset != registry.quoteAsset(project)) revert Invalid();
        _receiveExact(asset, amount);
        if (asset == pv.policy.dividendAsset) _addInventory(project, version, amount);
        else budget[project][asset][version] += amount;
        emit BudgetReceived(project, asset, version, amount);
    }
    function acquireReward(T.ExecutionPlan calldata p, bytes calldata route, bytes calldata sig)
        external nonReentrant executor(p.project) returns (T.ExecutionResult memory r) {
        T.PolicyVersion memory pv = _policy(p.project, p.policyVersion);
        if (pv.policy.dividendBps == 0 || !pv.policy.enabled) revert Invalid();
        r = _swap(p, route, sig, T.Purpose.AcquireDividend, registry.quoteAsset(p.project), pv.policy.dividendAsset,
            budget[p.project][p.assetIn][p.policyVersion]);
        budget[p.project][p.assetIn][p.policyVersion] -= r.actualSpent;
        _addInventory(p.project, p.policyVersion, r.actualReceived);
        emit RewardAcquired(p.project, p.policyVersion, p.nonce, r.actualSpent, r.actualReceived);
    }
    function _addInventory(address project, uint64 version, uint256 amount) private {
        rewardInventory[project][version] += amount;
        uint64 period = uint64(block.timestamp / registry.periodLength());
        rewardByPeriod[project][version][period] += amount;
    }
    function _latestPeriod() private view returns (uint64) {
        uint256 p = block.timestamp / registry.periodLength(); if (p == 0 || p > type(uint64).max) revert Invalid(); return uint64(p-1);
    }
    function recordSnapshot(address project, uint64 period, uint64 number, bytes32 hash) external reviewer {
        registry.controllerOf(project);
        if (period > _latestPeriod() || number == 0 || number >= block.number || hash == 0
            || snapshots[project][period].blockHash != 0) revert Invalid();
        // Old blocks cannot be authenticated by BLOCKHASH: reviewer is the explicit trust boundary.
        if (block.number - number <= 256 && blockhash(number) != hash) revert Invalid();
        snapshots[project][period] = Snapshot(number, hash); emit SnapshotRecorded(project, period, number, hash);
    }
    function epochId(address project, uint64 version, uint64 period) public view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(this), project, version, period));
    }
    function fundEpoch(address project, uint64 version, uint64 period) external nonReentrant executor(project) returns (bytes32 id) {
        T.PolicyVersion memory pv = _policy(project, version);
        Snapshot memory snap = snapshots[project][period]; uint256 amount = rewardByPeriod[project][version][period];
        if (!pv.policy.enabled || pv.policy.dividendBps == 0 || period > _latestPeriod()
            || snap.blockHash == 0 || amount == 0) revert Invalid();
        id = epochId(project, version, period); if (epochs[id].status != T.EpochStatus.Unset) revert Invalid();
        rewardInventory[project][version] -= amount;
        rewardByPeriod[project][version][period] = 0;
        T.Epoch storage e = epochs[id];
        e.project = project; e.policyVersion = version; e.rewardAsset = pv.policy.dividendAsset;
        e.period = period; e.snapshotBlock = snap.blockNumber; e.snapshotBlockHash = snap.blockHash;
        e.minHolding = pv.policy.minHolding; e.fundedAmount = amount; e.status = T.EpochStatus.Funded;
        emit EpochFunded(id, project, version, amount, snap.blockNumber);
    }
    function rollEmptyEpoch(bytes32 id, bytes32 manifest) external nonReentrant reviewer {
        T.Epoch storage e = epochs[id]; if (e.status != T.EpochStatus.Funded || manifest == 0) revert Invalid();
        e.status = T.EpochStatus.Cancelled;
        _addInventory(e.project, e.policyVersion, e.fundedAmount);
        emit EmptyEpochRolled(id, manifest);
    }
    function proposeDistribution(bytes32 id, bytes32 root, bytes32 manifest, uint256 total) external reviewer {
        T.Epoch storage e = epochs[id];
        if (e.status != T.EpochStatus.Funded || root == 0 || manifest == 0 || total == 0 || total > e.fundedAmount) revert Invalid();
        e.merkleRoot = root; e.manifestHash = manifest; e.totalEntitlement = total;
        e.claimableAt = uint64(block.timestamp) + reviewDelay; e.status = T.EpochStatus.Proposed;
        emit DistributionProposed(id, root, manifest, total, e.claimableAt);
    }
    function cancelDistribution(bytes32 id) external reviewer {
        T.Epoch storage e = epochs[id];
        if (e.status != T.EpochStatus.Proposed || block.timestamp >= e.claimableAt) revert Invalid();
        e.status = T.EpochStatus.Funded; e.merkleRoot = 0; e.manifestHash = 0; e.totalEntitlement = 0; e.claimableAt = 0;
        emit DistributionCancelled(id);
    }
    function activateEpoch(bytes32 id) external {
        T.Epoch storage e = epochs[id];
        if (e.status != T.EpochStatus.Proposed || block.timestamp < e.claimableAt) revert Invalid();
        e.status = T.EpochStatus.Active; emit EpochActivated(id);
    }
    function leaf(bytes32 id, address account, uint256 entitlement) public view returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(block.chainid, address(this), id, account, entitlement))));
    }
    function claim(bytes32 id, uint256 entitlement, bytes32[] calldata proof) external nonReentrant returns (uint256 amount) {
        T.Epoch storage e = epochs[id];
        if (e.status != T.EpochStatus.Active || entitlement == 0 || claimed[id][msg.sender] != 0
            || !MerkleProof.verifyCalldata(proof, e.merkleRoot, leaf(id, msg.sender, entitlement))) revert Invalid();
        amount = entitlement;
        if (e.claimedAmount + amount > e.totalEntitlement) revert Insufficient();
        claimed[id][msg.sender] = amount; e.claimedAmount += amount;
        _send(e.rewardAsset, msg.sender, amount); emit DividendClaimed(id, msg.sender, amount);
    }
    function epoch(bytes32 id) external view returns (T.Epoch memory) { return epochs[id]; }
}

