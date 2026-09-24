// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {OursPlatformStrategyBase,IPlatformV4Manager,IPlatformBurnable} from "./OursPlatformStrategyBase.sol";
import {OursPlatformTreasury} from "./OursPlatformTreasury.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IV4Manager} from "../adapters/OursV4Adapter.sol";
import {OursPlatformGuardedStrategy} from "./OursPlatformGuardedStrategy.sol";
contract OursPlatformRewardStrategy is OursPlatformGuardedStrategy {
    address public immutable rewardDistributor;
    event RewardsReleased(uint256 amount);
    constructor(address owner_,OursPlatformTreasury t,IPlatformV4Manager m,address token,address signer,address distributor)
        OursPlatformGuardedStrategy(owner_,t,m,token,signer) {if(distributor.code.length==0)revert Invalid();rewardDistributor=distributor;}
    function purpose() public pure override returns(StrategyPurpose){return StrategyPurpose.RewardAcquire;}
    function releaseRewards(uint256 amount) external running nonReentrant {
        if(msg.sender!=rewardDistributor||amount==0||amount>budget[platformToken])revert Unauthorized();
        budget[platformToken]-=amount;_sendExact(platformToken,rewardDistributor,amount);emit RewardsReleased(amount);
    }
}
