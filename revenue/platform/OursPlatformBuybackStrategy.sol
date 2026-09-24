// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {OursPlatformStrategyBase,IPlatformV4Manager,IPlatformBurnable} from "./OursPlatformStrategyBase.sol";
import {OursPlatformTreasury} from "./OursPlatformTreasury.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IV4Manager} from "../adapters/OursV4Adapter.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IBuybackUsdPriceSource} from "../OursCappedBuybackStrateg.sol";
contract OursPlatformBuybackStrategy is OursPlatformStrategyBase {
    event PlatformTokensBurned(uint256 amount);
    constructor(address owner_,OursPlatformTreasury t,IPlatformV4Manager m,address token,address signer)
        OursPlatformStrategyBase(owner_,t,m,token,signer) {}
    function purpose() public pure override returns(StrategyPurpose){return StrategyPurpose.BurnBuyback;}
    IBuybackUsdPriceSource public priceSource;
    uint256 public usdCap = 5000e18;
    uint64 public maxPriceAge = 3600;
    event BuybackConfigured(address indexed priceSource, uint256 usdCap, uint64 maxPriceAge);
    /// @notice Applies only to platform-token burn buybacks, not LP/reward acquisition.
    function configureBuyback(IBuybackUsdPriceSource source, uint256 cap, uint64 age) external onlyOwner {
        if(address(source).code.length == 0 || cap == 0 || age == 0) revert Invalid();
        priceSource = source; usdCap = cap; maxPriceAge = age;
        emit BuybackConfigured(address(source), cap, age);
    }
    function buybackExecutionLimit(address asset) public view returns(uint256) {
        if(address(priceSource) == address(0)) revert Invalid();
        (uint256 usd18, uint64 at) = priceSource.price(asset);
        if(usd18 == 0 || at == 0 || at > block.timestamp || block.timestamp - at > maxPriceAge) revert Invalid();
        uint8 decimals_ = asset == address(0) ? 18 : IERC20Metadata(asset).decimals();
        if(decimals_ > 18) revert Invalid();
        return Math.min(Math.min(budget[asset], batchCaps[asset]), Math.mulDiv(usdCap, 10 ** decimals_, usd18));
    }
    function burnPlatformTokens(uint256 amount) external executor running nonReentrant {
        if(amount==0||amount>budget[platformToken])revert Invalid();
        budget[platformToken]-=amount;
        uint256 bal=_balance(platformToken);uint256 supply=IERC20(platformToken).totalSupply();
        IPlatformBurnable(platformToken).burn(amount);
        if(_balance(platformToken)+amount!=bal||IERC20(platformToken).totalSupply()+amount!=supply)revert TransferMismatch();
        emit PlatformTokensBurned(amount);
    }
    function _validateSwap(SwapPlan calldata p,address out) internal view override {
        if(out!=platformToken||p.maxAmountIn!=buybackExecutionLimit(p.assetIn))revert BadPlan();
    }
    function _afterSwap(SwapPlan calldata,address,uint256,uint256 received) internal override {
        uint256 bal=_balance(platformToken);uint256 supply=IERC20(platformToken).totalSupply();
        IPlatformBurnable(platformToken).burn(received);
        if(_balance(platformToken)+received!=bal||IERC20(platformToken).totalSupply()+received!=supply)revert TransferMismatch();
        emit PlatformTokensBurned(received);
    }
}
