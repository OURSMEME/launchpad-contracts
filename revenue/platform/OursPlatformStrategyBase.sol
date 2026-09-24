// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {OursPlatformTreasury} from "./OursPlatformTreasury.sol";
import {OursExecutionGuard} from "../OursExecutionGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IOursFeePool} from "../interfaces/IOursRevenue.sol";
import {IV4Manager} from "../adapters/OursV4Adapter.sol";

interface IPlatformV4Manager is IV4Manager {
    function initialize(PoolKey calldata key,uint160 sqrtPriceX96) external returns(int24 tick);
    struct ModifyLiquidityParams { int24 tickLower; int24 tickUpper; int256 liquidityDelta; bytes32 salt; }
    function modifyLiquidity(PoolKey calldata key, ModifyLiquidityParams calldata params, bytes calldata hookData)
        external returns (int256 callerDelta, int256 feesAccrued);
}
interface IPlatformBurnable { function burn(uint256 amount) external; }

abstract contract OursPlatformStrategyBase is Ownable2Step,ReentrancyGuard,EIP712 {
    using SafeERC20 for IERC20;
    error Invalid(); error Unauthorized(); error BadPlan(); error TransferMismatch(); error TooEarly();
    enum StrategyPurpose { BurnBuyback, LiquidityAcquire, RewardAcquire }
    struct SwapPlan {
        bytes32 poolId; address assetIn; uint256 maxAmountIn; uint256 minAmountOut;
        uint160 sqrtPriceLimitX96; StrategyPurpose purpose; uint64 deadline; uint256 nonce; uint64 signerEpoch;
    }
    struct LiquidityPlan {
        bytes32 poolId; int24 tickLower; int24 tickUpper; bytes32 salt; uint128 liquidity;
        uint256 maxAmount0; uint256 maxAmount1; uint256 minAmount0; uint256 minAmount1;
        uint64 deadline; uint256 nonce; uint64 signerEpoch;
    }
    struct Callback {
        uint8 kind; IV4Manager.PoolKey key; IV4Manager.SwapParams swapParams;
        IPlatformV4Manager.ModifyLiquidityParams liquidityParams; uint256 max0; uint256 max1;
    }
    bytes32 public constant SWAP_TYPEHASH = keccak256("SwapPlan(bytes32 poolId,address assetIn,uint256 maxAmountIn,uint256 minAmountOut,uint160 sqrtPriceLimitX96,uint8 purpose,uint64 deadline,uint256 nonce,uint64 signerEpoch)");
    bytes32 public constant LIQUIDITY_TYPEHASH = keccak256("LiquidityPlan(bytes32 poolId,int24 tickLower,int24 tickUpper,bytes32 salt,uint128 liquidity,uint256 maxAmount0,uint256 maxAmount1,uint256 minAmount0,uint256 minAmount1,uint64 deadline,uint256 nonce,uint64 signerEpoch)");
    OursPlatformTreasury public immutable treasury;
    IOursFeePool public immutable feePool;
    IPlatformV4Manager public immutable manager;
    address public immutable platformToken;
    address public quoteSigner; uint64 public signerEpoch=1; bool public paused;
    mapping(address=>bool) public operators;
    mapping(address=>bool) public feeAssets;
    mapping(address=>bool) public stockAssets;
    mapping(address=>uint256) public batchCaps;
    mapping(address=>uint256) public budget;
    mapping(bytes32=>IV4Manager.PoolKey) internal pools;
    mapping(bytes32=>bool) public swapPools;
    mapping(bytes32=>bool) public liquidityPools;
    mapping(bytes32=>bool) public usedNonces;
    bytes32 private activeCallback;
    event BudgetCollected(address indexed asset,uint256 amount);
    event AssetConfigured(address indexed asset,bool feeAsset,bool stockAsset,uint256 cap);
    event PoolConfigured(bytes32 indexed poolId,bool swapEnabled,bool liquidityEnabled);
    event OperatorSet(address indexed operator,bool enabled);
    event SignerSet(address indexed signer,uint64 epoch);
    event PauseSet(bool paused);
    event Swapped(bytes32 indexed poolId,address indexed assetIn,address indexed assetOut,uint256 spent,uint256 received,StrategyPurpose purpose);
    constructor(address governance,OursPlatformTreasury t,IPlatformV4Manager m,address token,address signer)
        Ownable(governance) EIP712("OURS PlatformStrategy","1") {
        if(address(t).code.length==0||address(m).code.length==0||token.code.length==0||signer==address(0)) revert Invalid();
        treasury=t;feePool=t.feePool();manager=m;platformToken=token;quoteSigner=signer;
    }
    receive() external payable {}
    modifier executor(){if(msg.sender!=owner()&&!operators[msg.sender])revert Unauthorized();_;}
    modifier running(){if(paused || treasury.strategyPaused(address(this)))revert BadPlan();_;}
    function renounceOwnership() public override onlyOwner {revert Invalid();}
    function collectBudget(address asset) external nonReentrant returns(uint256 amount) {
        uint256 before_=_balance(asset); amount=treasury.claimBudget(asset);
        if(_balance(asset)!=before_+amount) revert TransferMismatch(); budget[asset]+=amount;emit BudgetCollected(asset,amount);
    }
    function purpose() public pure virtual returns(StrategyPurpose);
    function _validateSwap(SwapPlan calldata p,address assetOut) internal view virtual;
    function _afterSwap(SwapPlan calldata p,address assetOut,uint256 spent,uint256 received) internal virtual;
    function setOperator(address account,bool enabled) external onlyOwner {
        if(account==address(0))revert Invalid();operators[account]=enabled;emit OperatorSet(account,enabled);
    }
    function setQuoteSigner(address signer) external onlyOwner {
        if(signer==address(0))revert Invalid();quoteSigner=signer;++signerEpoch;emit SignerSet(signer,signerEpoch);
    }
    function setPaused(bool value) external onlyOwner {paused=value;emit PauseSet(value);}
    function configureAsset(address asset,bool feeAsset,bool stockAsset,uint256 cap) external onlyOwner {
        if((feeAsset||stockAsset)&&(cap==0||(asset!=address(0)&&asset.code.length==0)))revert Invalid();
        if(stockAsset&&(asset==address(0)||asset==platformToken))revert Invalid();
        feeAssets[asset]=feeAsset;stockAssets[asset]=stockAsset;batchCaps[asset]=cap;
        emit AssetConfigured(asset,feeAsset,stockAsset,cap);
    }
    function configurePool(IV4Manager.PoolKey calldata key,bool forSwap,bool forLiquidity) external onlyOwner {
        if(key.currency0>=key.currency1||key.tickSpacing<=0)revert Invalid();
        if(forSwap||forLiquidity){if(!_knownAsset(key.currency0)||!_knownAsset(key.currency1))revert Invalid();}
        // LP pairing is an explicit whitelist: supports platform/stock or quote/stock.
        if(forLiquidity&&!stockAssets[key.currency0]&&!stockAssets[key.currency1])revert Invalid();
        bytes32 id=keccak256(abi.encode(key));pools[id]=key;swapPools[id]=forSwap;liquidityPools[id]=forLiquidity;
        emit PoolConfigured(id,forSwap,forLiquidity);
    }
    function initializePool(bytes32 id,uint160 sqrtPriceX96) external onlyOwner nonReentrant {
        if((!swapPools[id]&&!liquidityPools[id])||sqrtPriceX96==0)revert Invalid();
        manager.initialize(pools[id],sqrtPriceX96);
    }
    function _knownAsset(address a) internal view returns(bool){return a==platformToken||feeAssets[a]||stockAssets[a];}
    function poolKey(bytes32 id) external view returns(IV4Manager.PoolKey memory){return pools[id];}
    function swapDigest(SwapPlan calldata p) public view returns(bytes32){return _hashTypedDataV4(keccak256(abi.encode(SWAP_TYPEHASH,p)));}
    function liquidityDigest(LiquidityPlan calldata p) public view returns(bytes32){return _hashTypedDataV4(keccak256(abi.encode(LIQUIDITY_TYPEHASH,p)));}
    function _authorize(bytes32 digest,uint64 deadline,uint256 nonce,uint64 epoch,bytes calldata sig) internal {
        bytes32 id=keccak256(abi.encode(epoch,nonce));
        if(deadline<block.timestamp||epoch!=signerEpoch||usedNonces[id])revert BadPlan();
        bool valid;
        if(quoteSigner.code.length==0){(address a,ECDSA.RecoverError e,)=ECDSA.tryRecover(digest,sig);valid=e==ECDSA.RecoverError.NoError&&a==quoteSigner;}
        else{(bool ok,bytes memory out)=quoteSigner.staticcall(abi.encodeCall(IERC1271.isValidSignature,(digest,sig)));valid=ok&&out.length>=32&&abi.decode(out,(bytes4))==IERC1271.isValidSignature.selector;}
        if(!valid)revert BadPlan();usedNonces[id]=true;
    }
    function executeSwap(SwapPlan calldata p,bytes calldata signature) external executor running nonReentrant returns(uint256 spent,uint256 received) {
        IV4Manager.PoolKey memory key=pools[p.poolId];
        if(p.purpose!=purpose()||!swapPools[p.poolId]||(p.assetIn!=key.currency0&&p.assetIn!=key.currency1)||!feeAssets[p.assetIn])revert BadPlan();
        address assetOut=p.assetIn==key.currency0?key.currency1:key.currency0;
        if(p.maxAmountIn==0||p.maxAmountIn>budget[p.assetIn]||p.maxAmountIn>batchCaps[p.assetIn]
            ||p.maxAmountIn>uint256(uint128(type(int128).max))||p.minAmountOut==0||p.sqrtPriceLimitX96==0) revert BadPlan();
        _validateSwap(p,assetOut);_authorize(swapDigest(p),p.deadline,p.nonce,p.signerEpoch,signature);
        uint256 beforeIn=_balance(p.assetIn);uint256 beforeOut=_balance(assetOut);
        Callback memory c;c.key=key;c.swapParams=IV4Manager.SwapParams(p.assetIn==key.currency0,-int256(p.maxAmountIn),p.sqrtPriceLimitX96);
        if(p.assetIn==key.currency0)c.max0=p.maxAmountIn;else c.max1=p.maxAmountIn;
        _unlock(c);spent=beforeIn-_balance(p.assetIn);received=_balance(assetOut)-beforeOut;
        if(spent==0||spent>p.maxAmountIn||received<p.minAmountOut)revert TransferMismatch();
        budget[p.assetIn]-=spent;_afterSwap(p,assetOut,spent,received);
        emit Swapped(p.poolId,p.assetIn,assetOut,spent,received,p.purpose);
    }
    function _unlock(Callback memory c) internal {
        bytes memory data=abi.encode(c);activeCallback=keccak256(data);manager.unlock(data);if(activeCallback!=0)revert Invalid();
    }
    function unlockCallback(bytes calldata data) external returns(bytes memory){
        if(msg.sender!=address(manager)||activeCallback==0||keccak256(data)!=activeCallback)revert Unauthorized();activeCallback=0;
        Callback memory c=abi.decode(data,(Callback));int256 delta;
        if(c.kind==0){delta=manager.swap(c.key,c.swapParams,"");int128 input=c.swapParams.zeroForOne?int128(delta>>128):int128(delta);int128 output=c.swapParams.zeroForOne?int128(delta):int128(delta>>128);if(input>=0||output<=0)revert TransferMismatch();}
        else{(delta,)=manager.modifyLiquidity(c.key,c.liquidityParams,"");}
        _settle(c.key.currency0,int128(delta>>128),c.max0);_settle(c.key.currency1,int128(delta),c.max1);return "";
    }
    function _settle(address asset,int128 delta,uint256 maximum) internal {
        uint256 before_=_balance(asset);
        if(delta<0){uint256 amount=uint256(-int256(delta));if(amount>maximum)revert BadPlan();
            manager.sync(asset); // Explicitly reset synced currency before native settlement too.
            if(asset==address(0)){if(manager.settle{value:amount}()!=amount)revert TransferMismatch();}
            else{IERC20(asset).safeTransfer(address(manager),amount);if(manager.settle()!=amount)revert TransferMismatch();}
            if(_balance(asset)+amount!=before_)revert TransferMismatch();
        }else if(delta>0){uint256 amount=uint256(uint128(delta));manager.take(asset,address(this),amount);if(_balance(asset)!=before_+amount)revert TransferMismatch();}
    }
    function _balance(address asset) internal view returns(uint256){return asset==address(0)?address(this).balance:IERC20(asset).balanceOf(address(this));}
    function _sendExact(address asset,address to,uint256 amount) internal {
        uint256 before_=_balance(asset);
        if(asset==address(0)){(bool ok,)=to.call{value:amount}("");if(!ok)revert TransferMismatch();}
        else{uint256 receiverBefore=IERC20(asset).balanceOf(to);IERC20(asset).safeTransfer(to,amount);if(IERC20(asset).balanceOf(to)!=receiverBefore+amount)revert TransferMismatch();}
        if(_balance(asset)+amount!=before_)revert TransferMismatch();
    }
}
