// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {OursPlatformStrategyBase,IPlatformV4Manager,IPlatformBurnable} from "./OursPlatformStrategyBase.sol";
import {OursPlatformTreasury} from "./OursPlatformTreasury.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IV4Manager} from "../adapters/OursV4Adapter.sol";
import {OursExecutionGuard} from "../OursExecutionGuard.sol";
abstract contract OursPlatformGuardedStrategy is OursPlatformStrategyBase {
    constructor(address owner_,OursPlatformTreasury t,IPlatformV4Manager m,address token,address signer)
        OursPlatformStrategyBase(owner_,t,m,token,signer) {}
    OursExecutionGuard public executionGuard;
    event ExecutionGuardBound(address indexed guard);
    function bindExecutionGuard(OursExecutionGuard guard) external onlyOwner {
        if (address(executionGuard) != address(0) || address(guard).code.length == 0
            || guard.platformTreasury() != address(this) || guard.registry().feePool() != address(feePool)) revert Invalid();
        executionGuard = guard; emit ExecutionGuardBound(address(guard));
    }
    function _validateSwap(SwapPlan calldata p,address out) internal view override {
        if((purpose()==StrategyPurpose.RewardAcquire&&out!=platformToken)
            ||(purpose()==StrategyPurpose.LiquidityAcquire&&out!=platformToken&&!stockAssets[out])
            ||address(executionGuard)==address(0))revert BadPlan();
        executionGuard.validate(address(this),p.assetIn,out,p.maxAmountIn,p.minAmountOut,p.deadline);
    }
    function _afterSwap(SwapPlan calldata p,address out,uint256 spent,uint256 received) internal override {
        executionGuard.record(address(this),p.assetIn,out,spent,received);budget[out]+=received;
    }
}
