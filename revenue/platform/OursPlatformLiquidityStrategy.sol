// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {OursPlatformStrategyBase,IPlatformV4Manager,IPlatformBurnable} from "./OursPlatformStrategyBase.sol";
import {OursPlatformTreasury} from "./OursPlatformTreasury.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IV4Manager} from "../adapters/OursV4Adapter.sol";
import {OursPlatformGuardedStrategy} from "./OursPlatformGuardedStrategy.sol";
contract OursPlatformLiquidityStrategy is OursPlatformGuardedStrategy {
    uint64 public immutable governanceDelay;
    mapping(bytes32=>uint128) public positionLiquidity;
    mapping(bytes32=>uint256) public queuedAt;
    mapping(bytes32=>bool) public completedActions;
    event LiquidityChanged(bytes32 indexed positionId,bool added,uint128 liquidity);
    event LiquidityFeesHarvested(bytes32 indexed positionId,uint256 amount0,uint256 amount1);
    event ActionQueued(bytes32 indexed action,uint256 executableAt);
    event ActionCancelled(bytes32 indexed action);
    event ActionExecuted(bytes32 indexed action);
    constructor(address owner_,OursPlatformTreasury t,IPlatformV4Manager m,address token,address signer,uint64 delay_)
        OursPlatformGuardedStrategy(owner_,t,m,token,signer) {if(delay_==0)revert Invalid();governanceDelay=delay_;}
    function purpose() public pure override returns(StrategyPurpose){return StrategyPurpose.LiquidityAcquire;}
    function positionId(bytes32 poolId,int24 lower,int24 upper,bytes32 salt) public pure returns(bytes32){return keccak256(abi.encode(poolId,lower,upper,salt));}
    function addLiquidity(LiquidityPlan calldata p,bytes calldata signature) external executor running nonReentrant {
        IV4Manager.PoolKey memory key=pools[p.poolId];
        if(!liquidityPools[p.poolId]||!_knownAsset(key.currency0)||!_knownAsset(key.currency1)
            ||(!stockAssets[key.currency0]&&!stockAssets[key.currency1])
            ||p.maxAmount0>budget[key.currency0]||p.maxAmount1>budget[key.currency1]
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
        if(after_<before_){uint256 spent=before_-after_;if(spent>maxSpend||minReceive!=0)revert TransferMismatch();budget[asset]-=spent;}
        else{uint256 received=after_-before_;if(received<minReceive)revert TransferMismatch();budget[asset]+=received;}
    }
}
