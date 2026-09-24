// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OursRevenueTypes as T} from "../revenue/interfaces/IOursRevenue.sol";
contract WeightedRewardAdapter {
    function execute(address,address assetIn,address assetOut,uint256 maximum,uint256,bytes calldata route)
        external payable returns(T.ExecutionResult memory) {
        uint256 output=abi.decode(route,(uint256));
        if(assetIn==address(0)) require(msg.value==maximum);
        else IERC20(assetIn).transferFrom(msg.sender,address(this),maximum);
        IERC20(assetOut).transfer(msg.sender,output);
        return T.ExecutionResult(maximum,output);
    }
}
