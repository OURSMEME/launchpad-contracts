// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {OursProjectRegistry} from "../OursProjectRegistry.sol";
import {OursRevenueTypes as T, IOursSwapAdapter} from "../interfaces/IOursRevenue.sol";

abstract contract RevenueBase is ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;
    error Unauthorized(); error Invalid(); error Insufficient(); error TransferMismatch(); error BadPlan();
    OursProjectRegistry public immutable registry;
    mapping(address => uint256) public totalLiability;
    mapping(bytes32 => bool) public usedNonces;
    bytes32 public constant PLAN_TYPEHASH = keccak256("ExecutionPlan(address project,uint64 policyVersion,uint8 purpose,address adapter,bytes32 routeHash,address assetIn,address assetOut,uint256 maxAmountIn,uint256 minAmountOut,uint64 deadline,uint256 nonce,uint64 signerEpoch)");
    constructor(OursProjectRegistry r, string memory name) EIP712(name, "1") {
        if (address(r).code.length == 0) revert Invalid(); registry = r;
    }
    receive() external payable {}
    modifier executor(address project) { if (!registry.canExecute(project, msg.sender)) revert Unauthorized(); _; }
    function _policy(address project, uint64 version) internal view returns (T.PolicyVersion memory p) {
        p = registry.policyAt(project, version); if (p.effectiveAt > block.timestamp) revert Invalid();
    }
    function _balance(address asset) internal view returns (uint256) { return asset == address(0) ? address(this).balance : IERC20(asset).balanceOf(address(this)); }
    function _receiveExact(address asset, uint256 amount) internal {
        if (amount == 0) revert Invalid();
        if (asset == address(0)) { if (msg.value != amount) revert TransferMismatch(); }
        else {
            if (msg.value != 0) revert TransferMismatch(); uint256 before_ = _balance(asset);
            IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
            if (_balance(asset) != before_ + amount) revert TransferMismatch();
        }
        totalLiability[asset] += amount;
    }
    function _send(address asset, address to, uint256 amount) internal {
        if (amount == 0) return; totalLiability[asset] -= amount;
        if (asset == address(0)) { (bool ok,) = to.call{value:amount}(""); if (!ok) revert TransferMismatch(); }
        else {
            uint256 beforeSelf = _balance(asset); uint256 beforeTo = IERC20(asset).balanceOf(to);
            IERC20(asset).safeTransfer(to, amount);
            if (_balance(asset) + amount != beforeSelf || IERC20(asset).balanceOf(to) != beforeTo + amount) revert TransferMismatch();
        }
    }
    function planDigest(T.ExecutionPlan calldata p) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(PLAN_TYPEHASH, p.project, p.policyVersion, uint8(p.purpose),
            p.adapter, p.routeHash, p.assetIn, p.assetOut, p.maxAmountIn, p.minAmountOut, p.deadline, p.nonce, p.signerEpoch)));
    }
    function _validSignature(address signer, bytes32 digest, bytes calldata sig) private view returns (bool) {
        if (signer.code.length == 0) {
            (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, sig);
            return err == ECDSA.RecoverError.NoError && recovered == signer;
        }
        (bool ok, bytes memory result) = signer.staticcall(abi.encodeCall(IERC1271.isValidSignature, (digest, sig)));
        return ok && result.length >= 32 && abi.decode(result, (bytes4)) == IERC1271.isValidSignature.selector;
    }
    function _swap(T.ExecutionPlan calldata p, bytes calldata route, bytes calldata sig, T.Purpose purpose,
        address expectedIn, address expectedOut, uint256 available) internal returns (T.ExecutionResult memory result) {
        _policy(p.project, p.policyVersion);
        if (registry.executionPaused(p.project)
            || ((expectedIn == p.project || expectedOut == p.project) && !registry.isTrading(p.project))
            || p.purpose != purpose
            || p.assetIn != expectedIn || p.assetOut != expectedOut || expectedIn == expectedOut
            || p.maxAmountIn == 0 || p.maxAmountIn > available || p.minAmountOut == 0
            || p.deadline < block.timestamp || p.signerEpoch != registry.signerEpoch()
            || p.routeHash != keccak256(route) || !registry.allowedAdapters(p.adapter)) revert BadPlan();
        // Meme itself is registered by its factory; all other assets must be whitelisted.
        if ((expectedIn != p.project && !registry.allowedAssets(expectedIn))
            || (expectedOut != p.project && !registry.allowedAssets(expectedOut))) revert BadPlan();
        // Meme normalization is capped by the signed plan; governance quote caps apply to budget spends.
        if (expectedIn != p.project && p.maxAmountIn > registry.maxBatchInput(expectedIn)) revert BadPlan();
        bytes32 nonceKey = keccak256(abi.encode(p.project, p.nonce, p.signerEpoch));
        if (usedNonces[nonceKey] || !_validSignature(registry.quoteSigner(), planDigest(p), sig)) revert BadPlan();
        usedNonces[nonceKey] = true;
        uint256 beforeIn = _balance(expectedIn); uint256 beforeOut = _balance(expectedOut);
        if (expectedIn != address(0)) IERC20(expectedIn).forceApprove(p.adapter, p.maxAmountIn);
        IOursSwapAdapter(p.adapter).execute{value: expectedIn == address(0) ? p.maxAmountIn : 0}(
            p.project, expectedIn, expectedOut, p.maxAmountIn, p.minAmountOut, route);
        if (expectedIn != address(0)) IERC20(expectedIn).forceApprove(p.adapter, 0);
        uint256 afterIn = _balance(expectedIn); uint256 afterOut = _balance(expectedOut);
        if (afterIn > beforeIn || afterOut < beforeOut) revert TransferMismatch();
        result = T.ExecutionResult(beforeIn - afterIn, afterOut - beforeOut);
        if (result.actualSpent == 0 || result.actualSpent > p.maxAmountIn || result.actualReceived < p.minAmountOut) revert BadPlan();
        totalLiability[expectedIn] -= result.actualSpent; totalLiability[expectedOut] += result.actualReceived;
    }
}

