// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

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

/// @notice Separate platform treasury. Only platform-owned fee income is collected here.
/// @dev V4 positions are owned directly by this contract: they are not transferable ERC721 LPs.
contract OursPlatformTreasury is Ownable2Step, ReentrancyGuard, EIP712 {
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
    uint256 public constant BURN_BPS = 5000;
    uint256 public constant LIQUIDITY_BPS = 2000;
    uint256 public constant REWARD_BPS = 1000;
    uint256 public constant OPERATING_BPS = 2000;
    IOursFeePool public immutable feePool;
    IPlatformV4Manager public immutable manager;
    address public immutable platformToken;
    address public immutable treasuryRecipient;
    address public immutable rewardDistributor;
    uint64 public immutable governanceDelay;
    address public quoteSigner;
    uint64 public signerEpoch = 1;
    bool public paused;
    mapping(address => bool) public operators;
    mapping(address => bool) public feeAssets;
    mapping(address => bool) public stockAssets;
    mapping(address => uint256) public batchCaps;
    mapping(bytes32 => IV4Manager.PoolKey) private pools;
    mapping(bytes32 => bool) public swapPools;
    mapping(bytes32 => bool) public liquidityPools;
    mapping(address => uint256) public grossPlatformFees;
    mapping(address => uint256) public burnAllocated;
    mapping(address => uint256) public liquidityAllocated;
    mapping(address => uint256) public rewardAllocated;
    mapping(address => uint256) public operatingAllocated;
    /// @notice Unallocated minimum units; never spendable until cumulative targets release them.
    mapping(address => uint256) public unallocatedDust;
    mapping(address => uint256) public burnBalance;
    mapping(address => uint256) public liquidityBalance;
    mapping(address => uint256) public rewardBalance;
    mapping(address => uint256) public operatingBalance;
    mapping(bytes32 => uint128) public positionLiquidity;
    mapping(bytes32 => bool) public usedNonces;
    mapping(bytes32 => uint256) public queuedAt;
    mapping(bytes32 => bool) public completedActions;
    bytes32 private activeCallback;

    event FeesCollected(address indexed asset, uint256 amount, uint256 burnAmount, uint256 liquidityAmount, uint256 rewardAmount, uint256 operatingAmount);
    event RevenueDustUpdated(address indexed asset, uint256 previousDust, uint256 newDust);
    event OperatingClaimed(address indexed asset, uint256 amount);
    event AssetConfigured(address indexed asset, bool feeAsset, bool stockAsset, uint256 cap);
    event PoolConfigured(bytes32 indexed poolId, bool swapEnabled, bool liquidityEnabled);
    event OperatorSet(address indexed operator, bool enabled);
    event SignerSet(address indexed signer, uint64 epoch);
    event PauseSet(bool paused);
    event Swapped(bytes32 indexed poolId, address indexed assetIn, address indexed assetOut, uint256 spent, uint256 received, StrategyPurpose purpose);
    event PlatformTokensBurned(uint256 amount);
    event RewardsReleased(uint256 amount);
    event LiquidityChanged(bytes32 indexed positionId, bool added, uint128 liquidity);
    event LiquidityFeesHarvested(bytes32 indexed positionId,uint256 amount0,uint256 amount1);
    event ActionQueued(bytes32 indexed action, uint256 executableAt);
    event ActionCancelled(bytes32 indexed action);
    event ActionExecuted(bytes32 indexed action);

    constructor(address governance, IOursFeePool feePool_, IPlatformV4Manager manager_, address token_,
        address treasury_, address rewards_, address signer_, uint64 delay_)
        Ownable(governance) EIP712("OURS PlatformTreasury", "1") {
        if(address(feePool_).code.length==0 || address(manager_).code.length==0 || token_.code.length==0
            || treasury_==address(0) || treasury_==address(this) || rewards_.code.length==0
            || signer_==address(0) || delay_==0) revert Invalid();
        feePool=feePool_;manager=manager_;platformToken=token_;treasuryRecipient=treasury_;
        rewardDistributor=rewards_;quoteSigner=signer_;governanceDelay=delay_;
    }
    /// @notice Custody exits require governance; rotate ownership with the two-step transfer instead.
    function renounceOwnership() public override onlyOwner { revert Invalid(); }
    receive() external payable {}
    modifier executor(){if(msg.sender!=owner()&&!operators[msg.sender])revert Unauthorized();_;}
    modifier running(){if(paused)revert BadPlan();_;}
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
    function _knownAsset(address a) private view returns(bool){return a==platformToken||feeAssets[a]||stockAssets[a];}
    function poolKey(bytes32 id) external view returns(IV4Manager.PoolKey memory){return pools[id];}
    function accountedBalance(address asset) public view returns(uint256){
        return burnBalance[asset]+liquidityBalance[asset]+rewardBalance[asset]+operatingBalance[asset]+unallocatedDust[asset];
    }
    function strategyAllocated(address asset) external view returns(uint256){return burnAllocated[asset]+liquidityAllocated[asset]+rewardAllocated[asset];}
    function strategyBalance(address asset) external view returns(uint256){return burnBalance[asset]+liquidityBalance[asset]+rewardBalance[asset];}
    /// @notice FeePool pays only msg.sender's entitlement; no project budget can be pulled.
    function collectFees(address asset) external nonReentrant {
        if(!feeAssets[asset])revert Invalid();uint256 before_=_balance(asset);
        uint256 reported=feePool.claimIncome(asset);uint256 amount=_balance(asset)-before_;
        if(amount==0||amount!=reported)revert TransferMismatch();_allocate(asset,amount);
    }
    /// @notice Governance may deposit already-received historical platform fees.
    function depositPlatformFees(address asset,uint256 amount) external payable onlyOwner nonReentrant {
        if(!feeAssets[asset]||amount==0)revert Invalid();
        if(asset==address(0)){if(msg.value!=amount)revert TransferMismatch();}
        else {if(msg.value!=0)revert Invalid();uint256 before_=_balance(asset);IERC20(asset).safeTransferFrom(msg.sender,address(this),amount);if(_balance(asset)!=before_+amount)revert TransferMismatch();}
        _allocate(asset,amount);
    }
    function _allocate(address asset,uint256 amount) private {
        grossPlatformFees[asset]+=amount;
        uint256 gross=grossPlatformFees[asset];
        uint256 burnTotal=Math.mulDiv(gross,BURN_BPS,10000);
        uint256 operatingTotal=Math.mulDiv(gross,OPERATING_BPS,10000);
        uint256 liquidityTotal=Math.mulDiv(gross,LIQUIDITY_BPS,10000);
        uint256 rewardTotal=Math.mulDiv(gross,REWARD_BPS,10000);
        // Independent cumulative targets are monotone. New allocations may use old dust.
        uint256 dust=gross-burnTotal-liquidityTotal-rewardTotal-operatingTotal;
        emit RevenueDustUpdated(asset,unallocatedDust[asset],dust);
        unallocatedDust[asset]=dust;
        uint256 burn=burnTotal-burnAllocated[asset];
        uint256 liquidity=liquidityTotal-liquidityAllocated[asset];
        uint256 reward=rewardTotal-rewardAllocated[asset];
        uint256 operating=operatingTotal-operatingAllocated[asset];
        burnAllocated[asset]=burnTotal;liquidityAllocated[asset]=liquidityTotal;rewardAllocated[asset]=rewardTotal;operatingAllocated[asset]=operatingTotal;
        burnBalance[asset]+=burn;liquidityBalance[asset]+=liquidity;rewardBalance[asset]+=reward;
        operatingBalance[asset]+=operating;
        emit FeesCollected(asset,amount,burn,liquidity,reward,operating);
    }
    /// @notice Permissionless trigger; the 20% always goes to the immutable platform recipient.
    function claimOperating(address asset) external nonReentrant {
        uint256 amount=operatingBalance[asset];if(amount==0)revert Invalid();operatingBalance[asset]=0;
        _sendExact(asset,treasuryRecipient,amount);emit OperatingClaimed(asset,amount);
    }
    /// @notice Burn platform-token fees directly without routing through a pool.
    function burnPlatformTokens(uint256 amount) external executor nonReentrant {
        if(amount==0||amount>burnBalance[platformToken])revert Invalid();
        burnBalance[platformToken]-=amount;
        uint256 bal=_balance(platformToken);uint256 supply=IERC20(platformToken).totalSupply();
        IPlatformBurnable(platformToken).burn(amount);
        if(_balance(platformToken)+amount!=bal||IERC20(platformToken).totalSupply()+amount!=supply)revert TransferMismatch();
        emit PlatformTokensBurned(amount);
    }
    function swapDigest(SwapPlan calldata p) public view returns(bytes32){return _hashTypedDataV4(keccak256(abi.encode(SWAP_TYPEHASH,p)));}
    function liquidityDigest(LiquidityPlan calldata p) public view returns(bytes32){return _hashTypedDataV4(keccak256(abi.encode(LIQUIDITY_TYPEHASH,p)));}
    function _authorize(bytes32 digest,uint64 deadline,uint256 nonce,uint64 epoch,bytes calldata sig) private {
        bytes32 id=keccak256(abi.encode(epoch,nonce));
        if(deadline<block.timestamp||epoch!=signerEpoch||usedNonces[id])revert BadPlan();
        bool valid;
        if(quoteSigner.code.length==0){(address a,ECDSA.RecoverError e,)=ECDSA.tryRecover(digest,sig);valid=e==ECDSA.RecoverError.NoError&&a==quoteSigner;}
        else{(bool ok,bytes memory out)=quoteSigner.staticcall(abi.encodeCall(IERC1271.isValidSignature,(digest,sig)));valid=ok&&out.length>=32&&abi.decode(out,(bytes4))==IERC1271.isValidSignature.selector;}
        if(!valid)revert BadPlan();usedNonces[id]=true;
    }
    /// @notice Buy platform tokens or stock tokens with the platform's 80% budget.
    function executeSwap(SwapPlan calldata p,bytes calldata signature) external executor running nonReentrant {
        IV4Manager.PoolKey memory key=pools[p.poolId];
        if(!swapPools[p.poolId]||(p.assetIn!=key.currency0&&p.assetIn!=key.currency1)||!feeAssets[p.assetIn])revert BadPlan();
        address assetOut=p.assetIn==key.currency0?key.currency1:key.currency0;
        uint256 available=p.purpose==StrategyPurpose.BurnBuyback?burnBalance[p.assetIn]
            :p.purpose==StrategyPurpose.LiquidityAcquire?liquidityBalance[p.assetIn]:rewardBalance[p.assetIn];
        if((p.purpose==StrategyPurpose.BurnBuyback&&assetOut!=platformToken)
            ||(p.purpose==StrategyPurpose.LiquidityAcquire&&assetOut!=platformToken&&!stockAssets[assetOut])
            ||(p.purpose==StrategyPurpose.RewardAcquire&&assetOut!=platformToken)
            ||p.maxAmountIn==0||p.maxAmountIn>available||p.maxAmountIn>batchCaps[p.assetIn]
            ||p.maxAmountIn>uint256(uint128(type(int128).max))||p.minAmountOut==0||p.sqrtPriceLimitX96==0)revert BadPlan();
        _authorize(swapDigest(p),p.deadline,p.nonce,p.signerEpoch,signature);
        uint256 beforeIn=_balance(p.assetIn);uint256 beforeOut=_balance(assetOut);
        Callback memory c;c.key=key;c.swapParams=IV4Manager.SwapParams(p.assetIn==key.currency0,-int256(p.maxAmountIn),p.sqrtPriceLimitX96);
        if(p.assetIn==key.currency0)c.max0=p.maxAmountIn;else c.max1=p.maxAmountIn;
        _unlock(c);
        uint256 spent=beforeIn-_balance(p.assetIn);uint256 received=_balance(assetOut)-beforeOut;
        if(spent==0||spent>p.maxAmountIn||received<p.minAmountOut)revert TransferMismatch();
        if(p.purpose==StrategyPurpose.BurnBuyback){
            burnBalance[p.assetIn]-=spent;
            uint256 bal=_balance(platformToken);uint256 supply=IERC20(platformToken).totalSupply();
            IPlatformBurnable(platformToken).burn(received);
            if(_balance(platformToken)+received!=bal||IERC20(platformToken).totalSupply()+received!=supply)revert TransferMismatch();
            emit PlatformTokensBurned(received);
        }else if(p.purpose==StrategyPurpose.LiquidityAcquire){
            liquidityBalance[p.assetIn]-=spent;liquidityBalance[assetOut]+=received;
        }else{
            rewardBalance[p.assetIn]-=spent;rewardBalance[assetOut]+=received;
        }
        emit Swapped(p.poolId,p.assetIn,assetOut,spent,received,p.purpose);
    }
    function releaseRewards(uint256 amount) external nonReentrant {
        if(msg.sender!=rewardDistributor||amount==0||amount>rewardBalance[platformToken])revert Unauthorized();
        rewardBalance[platformToken]-=amount;_sendExact(platformToken,rewardDistributor,amount);emit RewardsReleased(amount);
    }
    function positionId(bytes32 poolId,int24 lower,int24 upper,bytes32 salt) public pure returns(bytes32){return keccak256(abi.encode(poolId,lower,upper,salt));}
    function addLiquidity(LiquidityPlan calldata p,bytes calldata signature) external executor running nonReentrant {
        IV4Manager.PoolKey memory key=pools[p.poolId];
        if(!liquidityPools[p.poolId]||!_knownAsset(key.currency0)||!_knownAsset(key.currency1)
            ||(!stockAssets[key.currency0]&&!stockAssets[key.currency1])
            ||p.maxAmount0>liquidityBalance[key.currency0]||p.maxAmount1>liquidityBalance[key.currency1]
            ||p.maxAmount0+p.maxAmount1==0||p.minAmount0!=0||p.minAmount1!=0)revert BadPlan();
        _authorize(liquidityDigest(p),p.deadline,p.nonce,p.signerEpoch,signature);_modify(p,true);
    }
    /// @notice Collect position fees without changing liquidity or paying the executor.
    function harvestLiquidityFees(bytes32 poolId,int24 lower,int24 upper,bytes32 salt) external executor nonReentrant {
        bytes32 id=positionId(poolId,lower,upper,salt);if(positionLiquidity[id]==0)revert Invalid();
        IV4Manager.PoolKey memory key=pools[poolId];
        uint256 before0=_balance(key.currency0);uint256 before1=_balance(key.currency1);
        Callback memory c;c.kind=1;c.key=key;
        c.liquidityParams=IPlatformV4Manager.ModifyLiquidityParams(lower,upper,0,salt);_unlock(c);
        _reconcile(key.currency0,before0,0,0);_reconcile(key.currency1,before1,0,0);
        emit LiquidityFeesHarvested(id,_balance(key.currency0)-before0,_balance(key.currency1)-before1);
    }
    function removalAction(LiquidityPlan calldata p) public view returns(bytes32){return keccak256(abi.encode(block.chainid,address(this),"REMOVE_LIQUIDITY",p));}
    /// @notice Governance queues an exact LP removal; strategy and reward funds have no treasury withdrawal path.
    function queueAction(bytes32 action) external onlyOwner {
        if(action==0||queuedAt[action]!=0||completedActions[action])revert Invalid();
        queuedAt[action]=block.timestamp+governanceDelay;emit ActionQueued(action,queuedAt[action]);
    }
    function cancelAction(bytes32 action) external onlyOwner {
        if(queuedAt[action]==0)revert Invalid();delete queuedAt[action];emit ActionCancelled(action);
    }
    function _consumeAction(bytes32 action) private {
        if(queuedAt[action]==0||block.timestamp<queuedAt[action])revert TooEarly();
        delete queuedAt[action];completedActions[action]=true;emit ActionExecuted(action);
    }
    /// @notice Withdrawn LP assets return to this treasury, never to the caller.
    function removeLiquidity(LiquidityPlan calldata p) external nonReentrant {
        if(p.deadline<block.timestamp||p.maxAmount0!=0||p.maxAmount1!=0||(p.minAmount0==0&&p.minAmount1==0))revert BadPlan();
        _consumeAction(removalAction(p));_modify(p,false);
    }
    function _modify(LiquidityPlan calldata p,bool add) private {
        IV4Manager.PoolKey memory key=pools[p.poolId];
        if(key.tickSpacing<=0||keccak256(abi.encode(key))!=p.poolId||p.liquidity==0||p.liquidity>uint128(type(int128).max)
            ||p.tickLower>=p.tickUpper||p.tickLower%key.tickSpacing!=0||p.tickUpper%key.tickSpacing!=0)revert BadPlan();
        bytes32 id=positionId(p.poolId,p.tickLower,p.tickUpper,p.salt);
        if(add)positionLiquidity[id]+=p.liquidity;else positionLiquidity[id]-=p.liquidity;
        uint256 before0=_balance(key.currency0);uint256 before1=_balance(key.currency1);
        Callback memory c;c.kind=1;c.key=key;c.max0=p.maxAmount0;c.max1=p.maxAmount1;
        c.liquidityParams=IPlatformV4Manager.ModifyLiquidityParams(p.tickLower,p.tickUpper,add?int256(uint256(p.liquidity)):-int256(uint256(p.liquidity)),p.salt);
        _unlock(c);
        _reconcile(key.currency0,before0,p.maxAmount0,p.minAmount0);
        _reconcile(key.currency1,before1,p.maxAmount1,p.minAmount1);
        emit LiquidityChanged(id,add,p.liquidity);
    }
    function _reconcile(address asset,uint256 before_,uint256 maxSpend,uint256 minReceive) private {
        uint256 after_=_balance(asset);
        if(after_<before_){uint256 spent=before_-after_;if(spent>maxSpend||minReceive!=0)revert TransferMismatch();liquidityBalance[asset]-=spent;}
        else{uint256 received=after_-before_;if(received<minReceive)revert TransferMismatch();liquidityBalance[asset]+=received;}
    }
    function _unlock(Callback memory c) private {
        bytes memory data=abi.encode(c);activeCallback=keccak256(data);manager.unlock(data);if(activeCallback!=0)revert Invalid();
    }
    function unlockCallback(bytes calldata data) external returns(bytes memory){
        if(msg.sender!=address(manager)||activeCallback==0||keccak256(data)!=activeCallback)revert Unauthorized();activeCallback=0;
        Callback memory c=abi.decode(data,(Callback));int256 delta;
        if(c.kind==0){delta=manager.swap(c.key,c.swapParams,"");int128 input=c.swapParams.zeroForOne?int128(delta>>128):int128(delta);int128 output=c.swapParams.zeroForOne?int128(delta):int128(delta>>128);if(input>=0||output<=0)revert TransferMismatch();}
        else{(delta,)=manager.modifyLiquidity(c.key,c.liquidityParams,"");}
        _settle(c.key.currency0,int128(delta>>128),c.max0);_settle(c.key.currency1,int128(delta),c.max1);return "";
    }
    function _settle(address asset,int128 delta,uint256 maximum) private {
        uint256 before_=_balance(asset);
        if(delta<0){uint256 amount=uint256(-int256(delta));if(amount>maximum)revert BadPlan();
            manager.sync(asset); // Explicitly reset synced currency before native settlement too.
            if(asset==address(0)){if(manager.settle{value:amount}()!=amount)revert TransferMismatch();}
            else{IERC20(asset).safeTransfer(address(manager),amount);if(manager.settle()!=amount)revert TransferMismatch();}
            if(_balance(asset)+amount!=before_)revert TransferMismatch();
        }else if(delta>0){uint256 amount=uint256(uint128(delta));manager.take(asset,address(this),amount);if(_balance(asset)!=before_+amount)revert TransferMismatch();}
    }
    function _balance(address asset) private view returns(uint256){return asset==address(0)?address(this).balance:IERC20(asset).balanceOf(address(this));}
    function _sendExact(address asset,address to,uint256 amount) private {
        uint256 before_=_balance(asset);
        if(asset==address(0)){(bool ok,)=to.call{value:amount}("");if(!ok)revert TransferMismatch();}
        else{uint256 receiverBefore=IERC20(asset).balanceOf(to);IERC20(asset).safeTransfer(to,amount);if(IERC20(asset).balanceOf(to)!=receiverBefore+amount)revert TransferMismatch();}
        if(_balance(asset)+amount!=before_)revert TransferMismatch();
    }
}

