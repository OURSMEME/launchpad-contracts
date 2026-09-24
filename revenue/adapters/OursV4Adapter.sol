// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {OursProjectRegistry} from "../OursProjectRegistry.sol";
import {OursRevenueTypes as T, IOursSwapAdapter} from "../interfaces/IOursRevenue.sol";

/// @dev ABI-compatible subset of Uniswap V4 PoolManager. Addresses encode Currency/IHooks.
interface IV4Manager {
    struct PoolKey { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }
    struct SwapParams { bool zeroForOne; int256 amountSpecified; uint160 sqrtPriceLimitX96; }
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey calldata key, SwapParams calldata params, bytes calldata hookData) external returns (int256 delta);
    function sync(address currency) external;
    function settle() external payable returns (uint256);
    function take(address currency, address to, uint256 amount) external;
}
/// @notice One-hop exact-input V4 adapter. No arbitrary router/calldata forwarding.
contract OursV4Adapter is Ownable2Step, ReentrancyGuard, IOursSwapAdapter {
    using SafeERC20 for IERC20;
    error Invalid();
    OursProjectRegistry public immutable registry;
    IV4Manager public immutable manager;
    mapping(bytes32 => bool) public allowedRewardPools;
    bytes32 private activeCallback;
    event RewardPoolSet(bytes32 indexed poolId, bool enabled);
    constructor(OursProjectRegistry r, IV4Manager m, address governance) Ownable(governance) {
        if (address(m).code.length == 0 || address(r).code.length == 0) revert Invalid(); registry = r; manager = m;
    }
    receive() external payable {}
    function setRewardPool(IV4Manager.PoolKey calldata key, bool enabled) external onlyOwner {
        if (key.currency0 >= key.currency1 || key.tickSpacing <= 0) revert Invalid();
        bytes32 id = keccak256(abi.encode(key)); allowedRewardPools[id] = enabled; emit RewardPoolSet(id, enabled);
    }
    /// @dev route = abi.encode(PoolKey, uint160 sqrtPriceLimitX96). Hook data is empty.
    function execute(address project, address assetIn, address assetOut, uint256 amount, uint256 minOut, bytes calldata route)
        external payable nonReentrant returns (T.ExecutionResult memory result) {
        if (!registry.canSwap(project, msg.sender)) revert Invalid();
        (IV4Manager.PoolKey memory key, uint160 limit) = abi.decode(route,(IV4Manager.PoolKey,uint160));
        if (key.currency0 >= key.currency1 || key.tickSpacing <= 0 || limit == 0 || amount == 0 || minOut == 0
            || amount > uint256(uint128(type(int128).max))
            || !((assetIn == key.currency0 && assetOut == key.currency1) || (assetIn == key.currency1 && assetOut == key.currency0))) revert Invalid();
        bytes32 id = keccak256(abi.encode(key));
        if (assetIn == project || assetOut == project) {
            (bytes32 canonical, address hook) = registry.poolOf(project);
            if (id != canonical || key.hooks != hook || canonical == 0) revert Invalid();
        } else if (!allowedRewardPools[id] || !registry.canExecuteStrategy(project, msg.sender)) revert Invalid();
        uint256 beforeIn = _balance(assetIn) - (assetIn == address(0) ? msg.value : 0);
        uint256 beforeOut = _balance(assetOut);
        if (assetIn == address(0)) { if (msg.value != amount) revert Invalid(); }
        else {
            if (msg.value != 0) revert Invalid(); IERC20(assetIn).safeTransferFrom(msg.sender, address(this), amount);
            if (_balance(assetIn) != beforeIn + amount) revert Invalid();
        }
        bytes memory callbackData = abi.encode(key,assetIn,assetOut,amount,limit);
        activeCallback = keccak256(callbackData); manager.unlock(callbackData);
        if (activeCallback != 0) revert Invalid();
        uint256 refund = _balance(assetIn)-beforeIn; if (refund > amount) revert Invalid();
        result = T.ExecutionResult(amount-refund,_balance(assetOut)-beforeOut);
        if (result.actualSpent == 0 || result.actualReceived < minOut) revert Invalid();
        _send(assetIn,msg.sender,refund); _send(assetOut,msg.sender,result.actualReceived);
    }
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager) || activeCallback == 0 || keccak256(data) != activeCallback) revert Invalid();
        activeCallback = 0;
        (IV4Manager.PoolKey memory key,address assetIn,address assetOut,uint256 amount,uint160 limit) =
            abi.decode(data,(IV4Manager.PoolKey,address,address,uint256,uint160));
        int256 packed = manager.swap(key, IV4Manager.SwapParams(assetIn == key.currency0,-int256(amount),limit), "");
        int128 delta0 = int128(packed >> 128); int128 delta1 = int128(packed);
        int128 inDelta = assetIn == key.currency0 ? delta0 : delta1;
        int128 outDelta = assetIn == key.currency0 ? delta1 : delta0;
        if (inDelta >= 0 || outDelta <= 0) revert Invalid();
        uint256 owed = uint256(-int256(inDelta)); if (owed > amount) revert Invalid();
        // V4 keeps the synced currency in transient storage. A hook can change it
        // during swap, so native settlement must reset it too before sending value.
        manager.sync(assetIn);
        if (assetIn == address(0)) { if (manager.settle{value:owed}() != owed) revert Invalid(); }
        else { IERC20(assetIn).safeTransfer(address(manager),owed); if (manager.settle() != owed) revert Invalid(); }
        manager.take(assetOut,address(this),uint256(uint128(outDelta)));
        return "";
    }
    function _balance(address a) private view returns (uint256) { return a == address(0) ? address(this).balance : IERC20(a).balanceOf(address(this)); }
    function _send(address a, address to, uint256 amount) private {
        if (amount == 0) return;
        if (a == address(0)) { (bool ok,) = to.call{value:amount}(""); if (!ok) revert Invalid(); }
        else IERC20(a).safeTransfer(to,amount);
    }
}

