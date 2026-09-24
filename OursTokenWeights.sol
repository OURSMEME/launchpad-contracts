// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {IOursTokenObserver} from "./interfaces/IOursTokenObserver.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Non-transferable holding age; same rules as the weighted-dividend reference module.
contract OursTokenWeights is IOursTokenObserver {
    address public immutable token;
    error InvalidWeightSnapshot();
    struct Weight { uint256 value; uint256 balance; uint64 at; }
    struct Checkpoint { uint64 snapshot; Weight weight; }
    struct Snapshot { uint64 at; uint256 totalWeight; }
    address public revenue;
    mapping(address => bool) public excluded;
    mapping(address => Weight) private weights;
    mapping(address => Checkpoint[]) private history;
    mapping(uint64 => Snapshot) public snapshots;
    uint64 public snapshotCount;
    uint256 private globalWeight;
    uint256 public eligibleSupply;
    uint64 private globalAt;
    event WeightSnapshot(uint64 indexed id, uint64 at, uint256 totalWeight);
    function firstWeightSnapshot(address account) external view returns(uint64) {
        return history[account].length == 0 ? snapshotCount + 1 : history[account][0].snapshot;
    }
    constructor(address token_, address module,address[] memory system) {
        token = token_;
        revenue=module; globalAt=uint64(block.timestamp);
        excluded[address(0)]=true; excluded[address(0xdead)]=true; excluded[address(this)]=true; excluded[token_]=true;
        for(uint256 i; i<system.length; ++i) excluded[system[i]]=true;
    }
    function currentWeight(address account) public view returns (uint256) {
        if (excluded[account]) return 0;
        Weight memory w = weights[account];
        return w.value + w.balance * (block.timestamp - w.at);
    }
    function totalWeight() public view returns (uint256) {
        return globalWeight + eligibleSupply * (block.timestamp - globalAt);
    }
    function snapshot() external returns (uint64 id, uint256 total) {
        if (msg.sender != revenue) revert InvalidWeightSnapshot();
        total = totalWeight(); if (total == 0) revert InvalidWeightSnapshot();
        id = ++snapshotCount; snapshots[id] = Snapshot(uint64(block.timestamp), total);
        emit WeightSnapshot(id, uint64(block.timestamp), total);
    }
    function weightAt(address account, uint64 id) external view returns (uint256) {
        if (id == 0 || id > snapshotCount) revert InvalidWeightSnapshot();
        Checkpoint[] storage h = history[account];
        uint256 lo; uint256 hi = h.length;
        while (lo < hi) { uint256 mid = (lo + hi) / 2; if (h[mid].snapshot <= id) lo = mid + 1; else hi = mid; }
        if (lo == 0) return 0;
        Weight memory w = h[lo - 1].weight;
        return w.value + w.balance * (snapshots[id].at - w.at);
    }
    function _checkpoint(address account) private {
        Checkpoint[] storage h = history[account]; uint64 next = snapshotCount + 1;
        Weight memory w = weights[account];
        if (h.length != 0 && h[h.length-1].snapshot == next) h[h.length-1].weight = w;
        else h.push(Checkpoint(next, w));
    }
    function onBalanceChange(address from, address to, uint256 amount) external returns (bytes4) {
        if (msg.sender != token) revert InvalidWeightSnapshot();
        if (from == to || amount == 0) return IOursTokenObserver.onBalanceChange.selector;
        globalWeight = totalWeight(); globalAt = uint64(block.timestamp);
        if (!excluded[from]) {
            Weight storage w = weights[from]; uint256 beforeWeight = currentWeight(from);
            uint256 remaining = w.balance - amount;
            uint256 kept = remaining == 0 ? 0 : Math.mulDiv(beforeWeight, remaining, w.balance);
            globalWeight -= beforeWeight - kept; eligibleSupply -= amount;
            w.value = kept; w.balance = remaining; w.at = globalAt; _checkpoint(from);
        }
        if (!excluded[to]) {
            Weight storage w = weights[to]; w.value = currentWeight(to);
            w.balance += amount; w.at = globalAt; eligibleSupply += amount; _checkpoint(to);
        }
        return IOursTokenObserver.onBalanceChange.selector;
    }
}
