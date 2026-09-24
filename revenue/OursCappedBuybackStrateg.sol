// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {RevenueBase} from "./base/RevenueBase.sol";
import {OursProjectRegistry} from "./OursProjectRegistry.sol";
import {OursRevenueTypes as T, IOursCappedBuybackStrateg} from "./interfaces/IOursRevenue.sol";
interface IBuybackUsdPriceSource { function price(address asset) external view returns(uint256 usd18, uint64 updatedAt); }
interface ICappedBurnable { function burn(uint256 amount) external; }
/// @notice Composable adaptation of upstream OursCappedBuybackPool. Buys and burns the project Meme.
contract OursCappedBuybackStrateg is RevenueBase, IOursCappedBuybackStrateg, Ownable2Step {
    bytes32 public constant POOL_KIND = keccak256("OURS_BUYBACK_POOL");
    uint256 public usdCap = 5000e18;
    event UsdCapUpdated(uint256 previousCap, uint256 newCap);
    IBuybackUsdPriceSource public priceSource;
    event PriceSourceUpdated(address indexed previousSource, address indexed newSource);
    uint64 public maxPriceAge;
    event MaxPriceAgeUpdated(uint64 previousAge, uint64 newAge);
    mapping(address => mapping(address => mapping(uint64 => uint256))) public budget;
    mapping(address => uint256) public totalBuybackSpent;
    mapping(address => uint256) public totalBuybackBurned;
    constructor(OursProjectRegistry r, IBuybackUsdPriceSource source, uint64 age) RevenueBase(r, "OURS BuybackPool") Ownable(msg.sender) {
        if (address(source).code.length == 0 || age == 0) revert Invalid();
        priceSource = source; maxPriceAge = age;
    }
    /// @notice Global per-execution cap for every project selecting this strategy, in USD with 18 decimals.
    function setUsdCap(uint256 newCap) external onlyOwner {
        if (newCap == 0) revert Invalid();
        uint256 previous = usdCap; usdCap = newCap;
        emit UsdCapUpdated(previous, newCap);
    }
    /// @notice Maximum USD quote age in seconds, shared by all projects using this strategy.
    function setMaxPriceAge(uint64 newAge) external onlyOwner {
        if (newAge == 0) revert Invalid();
        uint64 previous = maxPriceAge; maxPriceAge = newAge;
        emit MaxPriceAgeUpdated(previous, newAge);
    }
    /// @notice Owner-managed USD oracle adapter shared by all projects selecting this strategy.
    function setPriceSource(IBuybackUsdPriceSource newSource) external onlyOwner {
        if (address(newSource).code.length == 0) revert Invalid();
        address previous = address(priceSource); priceSource = newSource;
        emit PriceSourceUpdated(previous, address(newSource));
    }
    // USD spending cap replaces the project's historical pair-price guard. Signature/minOut remain mandatory.
    function _requiresExecutionGuard() internal pure override returns(bool) { return false; }
    // Empty config means outer-pool-only. Explicit abi.encode(bool) fixes the choice at launch.
    function validateConfig(address, address, bytes calldata config) external pure {
        if (config.length == 0) return;
        if (config.length != 32) revert Invalid();
        abi.decode(config, (bool));
    }
    function innerBuybackEnabled(address project) public view returns(bool) {
        bytes memory config = registry.strategyConfig(project, address(this));
        return config.length != 0 && abi.decode(config, (bool));
    }
    function collectBudget(address project, uint64 version) external nonReentrant returns(uint256 amount) {
        address asset; (asset, amount) = _collectBudget(project, version);
        budget[project][asset][version] += amount;
        emit BudgetReceived(project, asset, version, amount);
    }
    function executionLimit(address project, uint64 version) public view returns(uint256) {
        address asset = registry.quoteAsset(project);
        (uint256 usd18, uint64 at) = priceSource.price(asset);
        if (usd18 == 0 || at == 0 || at > block.timestamp || block.timestamp - at > maxPriceAge) revert Invalid();
        uint8 decimals_ = asset == address(0) ? 18 : IERC20Metadata(asset).decimals();
        if (decimals_ > 18) revert Invalid();
        return Math.min(budget[project][asset][version], Math.mulDiv(usdCap, 10 ** decimals_, usd18));
    }
    function executeBuyback(T.ExecutionPlan calldata p, bytes calldata route, bytes calldata sig)
        external nonReentrant executor(p.project) returns(T.ExecutionResult memory r) {
        (bytes32 pool,) = registry.poolOf(p.project);
        if (pool == 0 && !innerBuybackEnabled(p.project)) revert Invalid();
        // Match upstream: full bounded budget is requested; adapters may refund unused input.
        // Registry.maxBatchInput still applies in _swap and must accommodate this amount.
        if (p.maxAmountIn != executionLimit(p.project, p.policyVersion)) revert BadPlan();
        r = _swap(p, route, sig, T.BUYBACK, registry.quoteAsset(p.project), p.project, budget[p.project][p.assetIn][p.policyVersion]);
        budget[p.project][p.assetIn][p.policyVersion] -= r.actualSpent;
        uint256 balance = _balance(p.project); uint256 supply = IERC20(p.project).totalSupply();
        ICappedBurnable(p.project).burn(r.actualReceived);
        if (_balance(p.project) + r.actualReceived != balance || IERC20(p.project).totalSupply() + r.actualReceived != supply) revert TransferMismatch();
        totalLiability[p.project] -= r.actualReceived;
        totalBuybackSpent[p.project] += r.actualSpent;
        totalBuybackBurned[p.project] += r.actualReceived;
        emit BuybackExecuted(p.project, p.policyVersion, p.nonce, r.actualSpent, r.actualReceived);
    }
}
