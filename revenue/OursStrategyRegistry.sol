// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IOursRevenueStrategy} from "./interfaces/IOursRevenue.sol";

/// @notice Append-only catalogue. Audit implementations before registering: a proxy's
/// code hash cannot prove that its implementation or external dependencies are immutable.
contract OursStrategyRegistry is Ownable2Step {
    error Invalid();
    struct Strategy { address implementation; bytes32 codeHash; bool selectable; bool paused; }
    address public immutable projectRegistry;
    mapping(bytes32 => Strategy) public strategies;
    mapping(address => bytes32) public idOf;
    mapping(address => bool) public weightedDividend;
    mapping(address => bool) public tokenObserverFactory;
    bytes32[] private ids;
    event StrategyRegistered(bytes32 indexed id, address indexed implementation, bytes32 codeHash);
    event StrategySelectable(bytes32 indexed id, bool selectable);
    event StrategyPaused(bytes32 indexed id, bool paused);
    constructor(address owner_, address registry_) Ownable(owner_) {
        if (registry_.code.length == 0) revert Invalid(); projectRegistry = registry_;
    }
    function registerStrategy(bytes32 id, address implementation) external onlyOwner {
        if (id == 0 || strategies[id].implementation != address(0) || implementation.code.length == 0
            || idOf[implementation] != 0 || IOursRevenueStrategy(implementation).registry() != projectRegistry) revert Invalid();
        strategies[id] = Strategy(implementation, implementation.codehash, true, false);
        (bool ok, bytes memory data) = implementation.staticcall(abi.encodeWithSignature("requiresWeightedToken()"));
        weightedDividend[implementation] = ok && data.length == 32 && abi.decode(data, (bool));
        (ok, data) = implementation.staticcall(abi.encodeWithSignature("requiresTokenObserver()"));
        tokenObserverFactory[implementation] = ok && data.length == 32 && abi.decode(data, (bool));
        idOf[implementation] = id; ids.push(id);
        emit StrategyRegistered(id, implementation, implementation.codehash);
    }
    function setSelectable(bytes32 id, bool selectable) external onlyOwner {
        if (strategies[id].implementation == address(0)) revert Invalid();
        strategies[id].selectable = selectable; emit StrategySelectable(id, selectable);
    }
    function setPaused(bytes32 id, bool paused) external onlyOwner {
        if (strategies[id].implementation == address(0)) revert Invalid();
        strategies[id].paused = paused; emit StrategyPaused(id, paused);
    }
    function resolve(bytes32 id) public view returns (address implementation) {
        Strategy memory s = strategies[id]; implementation = s.implementation;
        if (implementation == address(0) || implementation.codehash != s.codeHash) revert Invalid();
    }
    function resolveForLaunch(bytes32 id) external view returns (address) {
        if (!strategies[id].selectable || strategies[id].paused) revert Invalid(); return resolve(id);
    }
    function executable(address implementation) external view returns (bool) {
        bytes32 id = idOf[implementation]; Strategy memory s = strategies[id];
        return id != 0 && !s.paused && implementation.codehash == s.codeHash;
    }
    function strategyCount() external view returns (uint256) { return ids.length; }
    function strategyIdAt(uint256 index) external view returns (bytes32) { return ids[index]; }
}
