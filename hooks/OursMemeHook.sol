// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BaseHook} from "@uniswap/v4-hooks-public/src/base/BaseHook.sol";

import {FeePolicySnapshot, IOursFeeEscrow, IOursFeePolicy} from "../interfaces/ILaunchpad.sol";

import {OursFeeAccrual} from "../revenue/integration/OursFeeAccrual.sol";
import {OursProjectRegistry} from "../revenue/OursProjectRegistry.sol";
/// @notice V4 fee custody only. Conversion, allocation and burn happen in revenue pools.
/// @dev Adapter swaps pay the same Hook fee as user swaps; no caller-controlled exemptions.
contract OursMemeHook is BaseHook, Ownable2Step, OursFeeAccrual {
    error Invalid(); error NotFactory(); error AlreadySet(); error TransferMismatch();
    struct LaunchInfo { bool registered; address memecoin; address quoteToken; uint16 hookFeeBps; }
    mapping(PoolId => LaunchInfo) public launches;
    address public factory;
    address public protocolFeeRecipient;
    uint256 public hookFeeBps = 100;
    // Legacy policy ABI now describes only trade-fee snapshots and the launch-fee recipient.
    uint256 public constant protocolFeeShareBps = 3000;
    uint256 public constant buybackBurnBps = 0;
    uint256 public constant maxInternalPriceImpactBps = 1000;
    event PoolRegistered(PoolId indexed poolId,address indexed memecoin,address quoteToken);
    event HookFeeCollected(PoolId indexed poolId,address currency,uint256 fee,uint256 tax);
    event RevenueRegistrySet(address indexed registry);
    constructor(IPoolManager manager,address recipient,address owner_) BaseHook(manager) Ownable(owner_) OursFeeAccrual(OursProjectRegistry(address(0))) {
        if(recipient==address(0))revert Invalid();protocolFeeRecipient=recipient;
    }
    receive() external payable {}
    modifier onlyFactory(){if(msg.sender!=factory)revert NotFactory();_;}
    function setFactory(address f) external onlyOwner {if(factory!=address(0))revert AlreadySet();if(f.code.length==0)revert Invalid();factory=f;}
    function setRevenueRegistry(OursProjectRegistry r) external onlyOwner {
        if(address(revenueRegistry)!=address(0))revert AlreadySet();
        if(factory==address(0)||r.launchFactory()!=factory||r.feePool()==address(0))revert Invalid();
        _bindRevenueRegistry(r);emit RevenueRegistrySet(address(r));
    }
    function renounceOwnership() public pure override {revert Invalid();}
    function setHookFeeBps(uint256 bps) external onlyOwner {if(bps>1000)revert Invalid();hookFeeBps=bps;}
    function setProtocolFeeRecipient(address recipient) external onlyOwner {if(recipient==address(0))revert Invalid();protocolFeeRecipient=recipient;}
    function currentFeePolicy() external view returns(FeePolicySnapshot memory) {
        return FeePolicySnapshot(protocolFeeRecipient,3000,0,uint16(hookFeeBps),1000);
    }
    function registerPool(PoolKey calldata key,address meme,uint16 fee) external onlyFactory {
        PoolId id=key.toId();if(launches[id].registered||fee>1000||address(key.hooks)!=address(this))revert Invalid();
        address a=Currency.unwrap(key.currency0);address b=Currency.unwrap(key.currency1);
        if(a!=meme&&b!=meme)revert Invalid();address quote=a==meme?b:a;
        if(revenueRegistry.quoteAsset(meme)!=quote)revert Invalid();
        launches[id]=LaunchInfo(true,meme,quote,fee);emit PoolRegistered(id,meme,quote);
    }
    function _beforeInitialize(address sender,PoolKey calldata,uint160) internal view override returns(bytes4){
        if(sender!=factory)revert NotFactory();return IHooks.beforeInitialize.selector;
    }
    function _afterSwap(address,PoolKey calldata key,SwapParams calldata params,BalanceDelta delta,bytes calldata)
        internal override returns(bytes4,int128) {
        PoolId id=key.toId();LaunchInfo memory info=launches[id];
        if(!info.registered)revert Invalid();
        bool specified0=(params.amountSpecified<0)==params.zeroForOne;
        Currency currency=specified0?key.currency1:key.currency0;
        int256 amount=specified0?int256(delta.amount1()):int256(delta.amount0());if(amount<0)amount=-amount;
        uint256 fee=uint256(amount)*info.hookFeeBps/10000;
        if(fee==0)return(IHooks.afterSwap.selector,0);
        address asset=Currency.unwrap(currency);
        uint256 before_=asset==address(0)?address(this).balance:IERC20(asset).balanceOf(address(this));
        poolManager.take(currency,address(this),fee);
        uint256 after_=asset==address(0)?address(this).balance:IERC20(asset).balanceOf(address(this));
        if(after_!=before_+fee)revert TransferMismatch();
        _accrueRevenue(info.memecoin,asset,fee);
        emit HookFeeCollected(id,asset,fee,0);return(IHooks.afterSwap.selector,int128(int256(fee)));
    }
    function _beforeRevenueSweep(address,uint256) internal override {}
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}
