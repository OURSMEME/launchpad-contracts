// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
/// @notice MANUAL TEST price source. Not a production oracle or TWAP. New strategy deployments can use another source.
contract OursTestUsdPriceSource is Ownable2Step {
    error Invalid();
    struct Quote { uint256 usd18; uint64 updatedAt; }
    mapping(address => Quote) public price;
    event PriceSet(address indexed asset, uint256 usd18, uint64 observedAt);
    constructor(address governance) Ownable(governance) {}
    function setPrice(address asset, uint256 usd18, uint64 observedAt) external onlyOwner {
        if (usd18 == 0 || observedAt == 0 || observedAt > block.timestamp || observedAt < price[asset].updatedAt) revert Invalid();
        price[asset] = Quote(usd18, observedAt); emit PriceSet(asset, usd18, observedAt);
    }
}
