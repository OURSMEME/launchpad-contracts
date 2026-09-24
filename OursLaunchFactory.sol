// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
           
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {OursLauncherToken} from "./OursLauncherToken.sol";
import {OursBondingCurve} from "./OursBondingCurve.sol";
import {OursProjectRegistry} from "./revenue/OursProjectRegistry.sol";
import {OursRevenueTypes as T} from "./revenue/interfaces/IOursRevenue.sol";
import {OursLaunchLocker} from "./OursLaunchLocker.sol";
import {OursMemeHook} from "./hooks/OursMemeHook.sol";
import {OursGraduationExecutor} from "./OursGraduationExecutor.sol";
import {LaunchDeployment, OursLaunchDeployer} from "./OursLaunchDeployer.sol";
import {OursGraduationGuard} from "./OursGraduationGuard.sol";
import {OursGraduationMath} from "./libraries/OursGraduationMath.sol";
import {OursBondingCurveMath} from "./libraries/OursBondingCurveMath.sol";
import {
    FeePolicySnapshot,
    GraduationPhase,
    IOursFeeEscrow,
    IOursLaunchFactory
} from "./interfaces/ILaunchpad.sol";

/**
 * @title OursLaunchFactory
 * @notice Deploys a bonding curve and its launch token for every Ours
 * launch, then graduates the curve into a permanently locked, full-range
 * Uniswap V4 position governed by the shared OursMemeHook.
 *
 * Each curve already trades in the quote asset its pool will use, so
 * graduation never converts between assets and therefore needs no router and
 * no price oracle. It stays split into two permissionless phases so a failed
 * pool seed cannot strand a curve's reserves:
 * - `graduate`: drains the curve's own reserves into this factory. Purely
 *   internal bookkeeping, so it is safe to call automatically from within
 *   the crossing buy itself.
 * - `createGraduatedPool`: seeds the new V4 pool with those reserves, and
 *   stays retryable until it succeeds.
 */
contract OursLaunchFactory is Ownable2Step, ReentrancyGuard, IOursLaunchFactory {
    using SafeERC20 for IERC20;

    uint256 private constant BASIS_POINTS = 10_000;
    uint256 private constant MAX_CURVE_FEE_BPS = 1_000; // 10%
    uint256 private constant MAX_CREATOR_TAX_CEILING_BPS = 1_000; // 10%
    uint256 private constant MAX_TOTAL_TRADE_FEE_BPS = 2_000; // 20%
    // Ceiling on the launch-second snipe tax. Held below 100% so a taxed
    // buy always nets the buyer something even before the curve applies its
    // own combined-fee bound.
    uint256 private constant MAX_SNIPE_TAX_START_BPS = 9_900; // 99%
    // Ceiling on the snipe tax decay window. Long enough to cover several
    // blocks of sniper activity on any chain this deploys to, short enough
    // that a misconfiguration cannot leave a launch effectively closed to
    // the public for minutes.
    uint256 private constant MAX_SNIPE_TAX_SECONDS = 60;
    // Bound on the creator-declared exemption list, so a launch cannot be
    // made unaffordable to itself by an unbounded loop of exemption writes.
    uint256 private constant MAX_SNIPE_TAX_EXEMPTIONS = 32;
    uint8 private constant MIN_PAIR_TOKEN_DECIMALS = 6;
    // Smallest supply a launch may declare, and the reference supply the
    // quotability check assumes when it runs before any config is known.
    uint256 private constant MIN_LAUNCH_SUPPLY = 1 ether;
    // The quotability check prices a buy of one millionth of the phantom
    // reserve. Expressing the reference trade as a fraction of the reserve
    // rather than a fixed amount keeps it meaningful across quote assets of
    // different decimals, where a wei-denominated constant would be either
    // trivial or unreachable.
    uint256 private constant REFERENCE_BUY_DIVISOR = 1e6;
    // Widest ticks usable at any tick spacing, matching v4-core's own MIN/MAX_TICK.
    int24 private constant MIN_USABLE_TICK = -887272;
    int24 private constant MAX_USABLE_TICK = 887272;
    // Largest tick spacing v4-core's PoolManager will accept; a launch config
    // above this would deploy a curve and token but then revert forever at
    // pool creation, stranding the swept reserves.
    int24 private constant MAX_TICK_SPACING = 32767;
    // Largest amount either side of a seed may carry. V4 settles pool balance
    // changes through a BalanceDelta of two int128 halves, so the signed
    // maximum binds even though the PositionManager's ABI accepts a uint128.
    // Mirrors OursGraduationGuard's own ceiling.
    uint256 private constant MAX_SEED_AMOUNT = uint256(uint128(type(int128).max));
    // How long a launch must sit in Swept before its reserves may be released
    // manually. Seeding is permissionless and retryable, so this window is
    // what separates a genuinely unseedable launch from one that merely hit a
    // transient failure, and it denies the owner a same-block escape hatch.
    uint256 public constant GRADUATION_RESCUE_DELAY = 7 days;

    OursProjectRegistry public revenueRegistry;
    event RevenueRegistrySet(address indexed registry);
    function setRevenueRegistry(OursProjectRegistry registry) external onlyOwner {
        if(address(revenueRegistry)!=address(0)||registry.launchFactory()!=address(this)||registry.feePool()==address(0)||address(registry.strategyRegistry())==address(0)||address(memeHook.revenueRegistry())!=address(registry))revert LaunchDependenciesNotWired();
        revenueRegistry=registry;emit RevenueRegistrySet(address(registry));
    }

    struct TokenParams {
        T.Policy revenuePolicy;
        string name;
        string symbol;
        string logo;
        string description;
        OursLauncherToken.Socials socials;
        address creatorFeeRecipient;
        // Additional trade tax the creator charges on top of the launch
        // config's base curveFeeBps, capped by maxCreatorTaxBps at launch
        // time. Paid entirely to the creator, never split with the protocol.
        uint16 creatorTaxBps;
        // The creator chooses the initial per-launch buyback-and-lock state.
        // Both the current creator recipient and protocol owner may update it.
        bool buybackEnabled;
        // Optional guard on the economics this launch will lock in. Zero
        // waives the check. Set it to the terms quoted at signing time so an
        // owner re-peg can never land underneath an in-flight launch.
        //
        // Call previewLaunchEconomics(launchConfigId, pairToken) to obtain
        // this value rather than encoding it by hand. See _economicsDigest for
        // curve/pool terms, Registry platform payee, launch fee and snipe settings.
        // The explicitly supplied revenuePolicy is also part of launch calldata.
        bytes32 expectedEconomics;
        // Raw CREATE2 salt, globally unique for this LaunchDeployer. Token address
        // depends only on deployer address, this salt and fixed Token creation code.
        bytes32 salt;
    }

    /**
     * @notice Native-quote launch economics. `phantomQuote` and
     * `graduationThreshold` are in wei here; a launch against an approved
     * ERC-20 quote asset takes both from that asset's own PairTokenEconomics
     * instead, since neither figure is meaningful across decimals.
     */
    struct LaunchConfig {
        uint256 supply;
        uint256 curveFeeBps;
        uint256 phantomQuote;
        uint256 graduationThreshold;
        uint24 poolFee;
        int24 tickSpacing;
        bool enabled;
    }

    /**
     * @notice Curve economics for one approved ERC-20 quote asset, in that
     * asset's own decimals. Required before the asset may be approved,
     * because a wei-denominated phantom reserve applied to a 6-decimal
     * stablecoin would misprice the curve by twelve orders of magnitude.
     *
     * Both figures are sized off chain from a target native-quote value at a
     * chosen rate. Scaling the pair by one rate leaves the curve's shape
     * untouched, since only threshold / (threshold + phantomQuote) determines
     * the fraction of supply that reaches the graduated pool, so a custom
     * quote asset trades identically to a native launch of the same size.
     */
    struct PairTokenEconomics {
        uint256 phantomQuote;
        uint256 graduationThreshold;
        uint8 decimals;
    }


    error InvalidLaunchConfigId();
    error LaunchConfigDisabled();
    error InvalidBasisPoints();
    error ExemptionListTooLong();
    error InvalidSnipeTaxWindow();
    error CurveFeeTooHigh();
    error CreatorTaxTooHigh();
    error CombinedFeeTooHigh();
    error SupplyTooLow();
    error InvalidTickSpacing();
    error LaunchFeeNotPaid();
    error NotWhitelisted();
    error FeeTransferFailed();
    error ZeroAddress();
    error AlreadySet();
    error OwnershipCannotBeRenounced();
    error InvalidTokenParams();
    error TokenNotFound();
    error NotLaunchCurve();
    error WrongGraduationPhase();
    error GraduationStillViable();
    error NothingToGraduate();
    error SqrtPriceOutOfBounds();
    error GraduationExecutorNotSet();
    error LaunchDeployerNotSet();
    error NotLaunchForwarder();
    error NotCreatorFeeRecipient();
    error NoPendingChange();
    error TimelockNotElapsed(uint256 effectiveAt);
    error TimelockExpired(uint256 expiresAt);
    error LaunchDependenciesNotWired();
    error PairTokenNotApproved();
    error PairTokenValidationFailed();
    error NotBuybackController();
    error CoreLpFeeMustBeZero();
    error InvalidGraduationThreshold();
    error InvalidPhantomQuote();
    error CurveNotQuotable();
    error PairTokenEconomicsInvalid();
    error PairTokenDecimalsMismatch(uint8 expected, uint8 actual);
    error PairTokenDecimalsUnavailable();
    error LaunchEconomicsMismatch(bytes32 expected, bytes32 actual);
    error InexactTransfer(address token, uint256 expected, uint256 received);
    error GraduationSeedNotViable();
    error SupplyTooHigh();
    error GraduationRescueTooEarly(uint256 availableAt);

    event TokenLaunched(
        address indexed token,
        address indexed curve,
        address indexed deployer,
        address pairToken,
        uint256 launchConfigId,
        uint256 graduationThreshold
    );
    event LaunchSwept(address indexed token, uint256 quoteOut, uint256 tokenOut);
    event LaunchAutoGraduationFailed(address indexed token, address indexed curve, uint256 gasRemaining);
    event LaunchForceSwept(address indexed token);
    event PoolGraduated(address indexed token, uint256 positionId, uint256 tokenAmount, uint256 pairTokenAmount);
    event LaunchConfigAdded(uint256 indexed id);
    event LaunchConfigUpdated(uint256 indexed id);
    event LaunchFeeUpdated(uint256 launchFee);
    event LaunchEnabledUpdated(bool enabled);
    event WhitelistedLauncherUpdated(address indexed launcher, bool enabled);
    event SnipeTaxStartBpsUpdated(uint256 bps);
    event SnipeTaxSecondsUpdated(uint256 secondsWindow);
    event GraduationExecutorSet(address executor);
    event LaunchDeployerSet(address deployer);
    event LaunchForwarderSet(address forwarder);
    event PairTokenApprovalUpdated(address indexed pairToken, bool approved);
    event PairTokenEconomicsUpdated(
        address indexed pairToken, uint256 phantomQuote, uint256 graduationThreshold, uint8 decimals
    );
    event BuybackEnabledUpdated(address indexed token, bool enabled, address indexed controller);
    event GraduationTokensPermanentlyLocked(address indexed token, uint256 amount);
    event LaunchGraduationRescued(
        address indexed token, address indexed recipient, uint256 quoteAmount, uint256 tokenAmount
    );

    IPoolManager public immutable poolManager;
    IPositionManager public immutable positionManager;
    IAllowanceTransfer public immutable permit2;
    OursLaunchLocker public immutable locker;
    OursMemeHook public immutable memeHook;

    // Not immutable: each helper's constructor needs this factory's
    // already-deployed address, so they are deployed afterward and wired once.
    OursGraduationExecutor public graduationExecutor;
    OursLaunchDeployer public launchDeployer;
    address public launchForwarder;
    OursGraduationGuard public immutable graduationGuard;

    // Ceiling on the creator-chosen trade tax, mirroring MAX_CURVE_FEE_BPS's
    // existing pattern for the protocol's own base fee.
    uint256 public constant maxCreatorTaxBps = 0; // 10%

    // Anti-snipe tax terms every new launch snapshots at creation: the tax
    // charged in the launch second, in basis points of a buy's quote leg,
    // and the window across which each curve decays it exponentially to
    // zero. Snapshotted rather than read live so retuning here governs
    // launches from that moment on while a curve already trading keeps the
    // terms it launched under. A zero starting tax disables the mechanism
    // for launches created while it is zero.
    uint256 public snipeTaxStartBps = 9_900; // 99%
    uint256 public snipeTaxSeconds = 15;

    uint256 public launchFee;
    bool public launchEnabled;

    mapping(address launcher => bool enabled) public whitelistedLaunchers;
    mapping(address pairToken => bool approved) public approvedPairTokens;
    mapping(address pairToken => PairTokenEconomics economics) public pairTokenEconomics;
    mapping(address token => FeePolicySnapshot policy) private _launchFeePolicies;
    mapping(address token => LaunchedToken launched) private _launchedTokens;
    LaunchConfig[] private _launchConfigs;

    constructor(
        address initialOwner,
        IPoolManager poolManager_,
        IPositionManager positionManager_,
        IAllowanceTransfer permit2_,
        OursLaunchLocker locker_,
        OursMemeHook memeHook_,
        uint256 initialLaunchFee
    ) Ownable(initialOwner) {
        if (address(poolManager_) == address(0) || address(positionManager_) == address(0)) {
            revert ZeroAddress();
        }
        if (address(permit2_) == address(0) || address(locker_) == address(0)) revert ZeroAddress();
        if (address(memeHook_) == address(0)) revert ZeroAddress();
        // The factory initializes pools on `poolManager_` but mints their
        // liquidity through `positionManager_`. If the two point at different
        // singletons every graduation reverts, so the mismatch is caught here
        // rather than once per launch: both are immutable, so one check at
        // construction covers the contract's whole lifetime.
        if (address(positionManager_.poolManager()) != address(poolManager_)) {
            revert LaunchDependenciesNotWired();
        }

        poolManager = poolManager_;
        positionManager = positionManager_;
        permit2 = permit2_;
        locker = locker_;
        memeHook = memeHook_;
        graduationGuard = new OursGraduationGuard();
        launchFee = initialLaunchFee;
    }

    /**
     * @notice Returns the number of launch configurations.
     */
    function launchConfigCount() external view returns (uint256) {
        return _launchConfigs.length;
    }

    /**
     * @notice Returns one token launch configuration.
     */
    function getLaunchConfig(uint256 id) external view returns (LaunchConfig memory) {
        if (id >= _launchConfigs.length) revert InvalidLaunchConfigId();
        return _launchConfigs[id];
    }

    /**
     * @notice Returns the immutable record for a token created by this factory.
     */
    function getLaunchedToken(address token) external view override returns (LaunchedToken memory) {
        return _launchedTokens[token];
    }

    /**
     * @notice Returns the fee policy frozen for a launch.
     */
    function getLaunchFeePolicy(address token) external view returns (FeePolicySnapshot memory) {
        return _launchFeePolicies[token];
    }

    // ---------------------------------------------------------------------
    // Owner-only configuration
    // ---------------------------------------------------------------------

    /**
     * @notice Adds a launch configuration new tokens can be deployed against.
     */
    function addLaunchConfig(LaunchConfig calldata config) external onlyOwner returns (uint256 id) {
        _validateLaunchConfig(config);
        id = _launchConfigs.length;
        _launchConfigs.push(config);
        emit LaunchConfigAdded(id);
    }

    /**
     * @notice Replaces an existing launch configuration. Already-launched
     * tokens are unaffected since their pool parameters were snapshotted.
     */
    function updateLaunchConfig(uint256 id, LaunchConfig calldata config) external onlyOwner {
        if (id >= _launchConfigs.length) revert InvalidLaunchConfigId();
        _validateLaunchConfig(config);
        _launchConfigs[id] = config;
        emit LaunchConfigUpdated(id);
    }

    /**
     * @notice Changes the fixed native launch fee.
     */
    function setLaunchFee(uint256 newLaunchFee) external onlyOwner {
        launchFee = newLaunchFee;
        emit LaunchFeeUpdated(newLaunchFee);
    }

    /**
     * @notice Opens or closes launches to non-whitelisted callers.
     */
    function setLaunchEnabled(bool enabled) external onlyOwner {
        launchEnabled = enabled;
        emit LaunchEnabledUpdated(enabled);
    }

    /**
     * @notice Grants or revokes permission to launch while the public gate is closed.
     */
    function setWhitelistedLauncher(address launcher, bool enabled) external onlyOwner {
        if (launcher == address(0)) revert ZeroAddress();
        whitelistedLaunchers[launcher] = enabled;
        emit WhitelistedLauncherUpdated(launcher, enabled);
    }

    /**
     * @notice Whether `launcher` may launch right now: true while the public
     * gate is open, and true for whitelisted addresses while it is closed.
     * The same predicate `launchToken` enforces on its caller, exposed so
     * routers like OursLaunchAndBuy can hold their own callers to this
     * single list instead of maintaining a second one.
     */
    function canLaunch(address launcher) public view returns (bool) {
        return launchEnabled || whitelistedLaunchers[launcher];
    }

    /**
     * @notice Sets the curve economics a quote asset's launches use, in that
     * asset's own decimals. Required before the asset may be approved, and
     * updatable afterwards so the peg to a target native-quote value can be
     * refreshed as rates move. Existing launches are unaffected: each curve
     * receives both figures as constructor immutables, so this only governs
     * launches created after it.
     * @param expectedDecimals The scale the caller sized both figures against,
     * checked against the asset's own report. This is the one guard against
     * reusing an 18-decimal configuration on a 6-decimal asset, which would
     * otherwise misprice silently by twelve orders of magnitude.
     */
    function setPairTokenEconomics(
        address pairToken,
        uint256 phantomQuote,
        uint256 graduationThreshold,
        uint8 expectedDecimals
    ) external onlyOwner {
        if (pairToken == address(0) || phantomQuote == 0 || graduationThreshold == 0) {
            revert PairTokenEconomicsInvalid();
        }
        // Curve fees are integer basis points of the quote leg, so on a
        // coarse asset every trade below BASIS_POINTS / feeBps base units
        // rounds its fee to zero and a trader can split an order into
        // fee-free pieces. Six decimals is the floor at which that band is
        // dust, and matches the least granular asset worth quoting in.
        if (expectedDecimals < MIN_PAIR_TOKEN_DECIMALS) revert PairTokenEconomicsInvalid();
        // A launch against this asset takes its phantom reserve from here but
        // its supply from whichever config it selects, so the strictest case
        // is the smallest supply any config may declare paired with the
        // highest fee any of them may charge.
        _requireQuotable(phantomQuote, MIN_LAUNCH_SUPPLY, MAX_CURVE_FEE_BPS);
        _requireDecimals(pairToken, expectedDecimals, false);
        pairTokenEconomics[pairToken] = PairTokenEconomics({
            phantomQuote: phantomQuote, graduationThreshold: graduationThreshold, decimals: expectedDecimals
        });
        emit PairTokenEconomicsUpdated(pairToken, phantomQuote, graduationThreshold, expectedDecimals);
    }

    /**
     * @dev Requires the quote asset to report `expectedDecimals`. Assets with
     * no code yet, or that omit the optional metadata call, are accepted on
     * the caller's stated scale because nothing contradicts it. The scale is
     * stored and re-checked at approval so an address that only becomes a
     * contract afterwards cannot enter service on an unverified claim.
     */
    function _requireDecimals(address pairToken, uint8 expectedDecimals, bool required) private view {
        if (!required && pairToken.code.length == 0) return;
        try IERC20Metadata(pairToken).decimals() returns (uint8 actual) {
            if (actual != expectedDecimals) revert PairTokenDecimalsMismatch(expectedDecimals, actual);
        } catch {
            // Sizing may legitimately precede deployment, but an asset whose
            // scale cannot be read must never enter service on an unverified
            // claim, since the error this guards against is a silent
            // twelve-order-of-magnitude mispricing.
            if (required) revert PairTokenDecimalsUnavailable();
        }
    }

    /**
     * @notice Approves or removes a standard ERC-20 quote asset for new
     * launches. Because curves collect the quote asset directly, approving
     * one needs nothing beyond a real token contract and the economics its
     * curves will price against.
     * @dev The stored scale is re-verified here rather than trusted from the
     * economics call. Approval is the point where the asset enters service,
     * and it is the only point at which the address is guaranteed to hold
     * code, so this is what closes the gap for an asset configured before it
     * was deployed or one that has since changed its reported decimals.
     */
    function setPairTokenApproved(address pairToken, bool approved) external onlyOwner {
        if (pairToken == address(0)) revert PairTokenValidationFailed();
        if (approved) {
            if (pairToken.code.length == 0) revert PairTokenValidationFailed();

            PairTokenEconomics memory economics = pairTokenEconomics[pairToken];
            if (economics.phantomQuote == 0 || economics.graduationThreshold == 0) {
                revert PairTokenEconomicsInvalid();
            }
            _requireDecimals(pairToken, economics.decimals, true);
        }
        approvedPairTokens[pairToken] = approved;
        emit PairTokenApprovalUpdated(pairToken, approved);
    }

    /**
     * @notice Adjusts the ceiling a creator's chosen trade tax is validated
     * against at launch time. Already-launched tokens keep the immutable
     * tax rate they launched with regardless of later ceiling changes.
     */


    /**
     * @notice Sets the launch-second snipe tax that new launches snapshot
     * at creation. Curves already trading keep the figure they launched
     * under. Zero disables the tax for launches created while it is zero;
     * a nonzero figure must exceed the 20% combined base fee ceiling, so
     * the launch-window tax always dominates the ordinary fee take, and
     * stays below 100% so a taxed buy always nets the buyer something.
     */
    function setSnipeTaxStartBps(uint256 bps) external onlyOwner {
        if (bps != 0 && (bps <= MAX_TOTAL_TRADE_FEE_BPS || bps > MAX_SNIPE_TAX_START_BPS)) {
            revert InvalidBasisPoints();
        }
        snipeTaxStartBps = bps;
        emit SnipeTaxStartBpsUpdated(bps);
    }

    /**
     * @notice Sets the decay window new launches snapshot at creation, in
     * seconds. Capped at one minute so a misconfiguration cannot leave a
     * launch effectively closed to the public for minutes; disabling the
     * tax is done through `setSnipeTaxStartBps`, so a zero window is
     * refused rather than overloaded to mean off.
     */
    function setSnipeTaxSeconds(uint256 secondsWindow) external onlyOwner {
        if (secondsWindow == 0 || secondsWindow > MAX_SNIPE_TAX_SECONDS) revert InvalidSnipeTaxWindow();
        snipeTaxSeconds = secondsWindow;
        emit SnipeTaxSecondsUpdated(secondsWindow);
    }

    /**
     * @notice One-time wiring of the graduation executor, set after both are
     * deployed since the executor's constructor needs this factory's
     * already-known address.
     */
    function setGraduationExecutor(OursGraduationExecutor executor) external onlyOwner {
        if (address(graduationExecutor) != address(0)) revert AlreadySet();
        if (address(executor) == address(0)) revert ZeroAddress();
        graduationExecutor = executor;
        emit GraduationExecutorSet(address(executor));
    }

    /**
     * @notice One-time wiring of the launch deployer, set after both are
     * deployed since the deployer's constructor needs this factory's
     * already-known address.
     */
    function setLaunchDeployer(OursLaunchDeployer deployer) external onlyOwner {
        if (address(launchDeployer) != address(0)) revert AlreadySet();
        if (address(deployer) == address(0)) revert ZeroAddress();
        launchDeployer = deployer;
        emit LaunchDeployerSet(address(deployer));
    }

    /**
     * @notice Sets the router allowed to preserve the initiating user across
     * an atomic launch-and-buy call. May be rotated when the router is
     * upgraded without replacing the rest of the launch stack.
     * @dev Kept separate from `whitelistedLaunchers`: that list controls who
     * may launch while the public gate is closed, whereas this address is
     * trusted to identify another account for CREATE2 namespacing and launch
     * attribution.
     */
    function setLaunchForwarder(address forwarder) external onlyOwner {
        if (forwarder == address(0)) revert ZeroAddress();
        launchForwarder = forwarder;
        emit LaunchForwarderSet(forwarder);
    }

    /**
     * @notice Permanently disabled. An ownerless factory could never approve
     * a pairToken, adjust fee ceilings, or recover a creator's fee recipient,
     * and every launch already live would keep depending on those powers.
     * Ownership can still be handed to a new owner via the two-step transfer.
     */
    function renounceOwnership() public pure override {
        revert OwnershipCannotBeRenounced();
    }

    // ---------------------------------------------------------------------
    // Launch
    // ---------------------------------------------------------------------

    /**
     * @notice Returns the economics digest a launch of `launchConfigId` in
     * `pairToken` would produce right now, for a creator to pass back as
     * TokenParams.expectedEconomics.
     * @dev Reading the digest and launching in separate transactions still
     * leaves the terms free to move in between; the pin is what makes that
     * movement revert instead of silently repricing the launch.
     */
    function previewLaunchEconomics(uint256 launchConfigId, address pairToken) external view returns (bytes32) {
        if (launchConfigId >= _launchConfigs.length) revert InvalidLaunchConfigId();
        LaunchConfig memory config = _launchConfigs[launchConfigId];
        (uint256 phantomQuote, uint256 graduationThreshold) = pairToken == address(0)
            ? (config.phantomQuote, config.graduationThreshold)
            : (pairTokenEconomics[pairToken].phantomQuote, pairTokenEconomics[pairToken].graduationThreshold);
        return _economicsDigest(config, memeHook.currentFeePolicy(), phantomQuote, graduationThreshold);
    }

    /**
     * @dev Covers every owner-controlled term that fixes what a creator is
     * buying: the curve's shape and cost, the pool the launch graduates into,
     * and the fee split that follows it. Narrowing this to the phantom
     * reserve and threshold alone would let the supply, the trade fee, or the
     * pool's own fee tier move underneath a pinned launch.
     *
     * Initial revenuePolicy is supplied explicitly in launch calldata. Registry
     * and its current platform payee are pinned here with launch and snipe fees.
     */
    function _economicsDigest(
        LaunchConfig memory config,
        FeePolicySnapshot memory policy,
        uint256 phantomQuote,
        uint256 graduationThreshold
    ) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                phantomQuote,
                graduationThreshold,
                config.supply,
                config.curveFeeBps,
                config.poolFee,
                config.tickSpacing,
                policy.protocolFeeShareBps,
                policy.buybackBurnBps,
                policy.hookFeeBps,
                policy.maxInternalPriceImpactBps,
                address(revenueRegistry),
                revenueRegistry.platformRecipient(),
                launchFee,
                snipeTaxStartBps,
                snipeTaxSeconds
            )
        );
    }

    /**
     * @notice Deploys a bonding curve and its launch token, wires them
     * together, and records the launch. Trading starts immediately on the
     * curve; the graduation pool's pairToken is fixed here, chosen by the
     * caller. The caller and their creator fee recipient are exempted from
     * the snipe tax automatically; a launch with additional bundle wallets
     * should use the overload that takes an exemption list.
     */
    function launchToken(TokenParams calldata params, uint256 launchConfigId, address pairToken)
        external
        payable
        nonReentrant
        returns (address token, address curve)
    {
        return _launchToken(params, launchConfigId, pairToken, msg.sender);
    }

    /**
     * @notice Same launch flow, plus a creator-declared list of wallets
     * exempted from the snipe tax before trading opens to anyone else. This
     * is the sanctioned pathway for organized teams that bundle their
     * opening buys across several wallets: declared wallets clear at the
     * untaxed price during the launch window while undeclared snipers pay
     * the decaying tax.
     */
    function launchToken(
        TokenParams calldata params,
        uint256 launchConfigId,
        address pairToken,
        address[] calldata snipeTaxExemptions
    ) external payable nonReentrant returns (address token, address curve) {
        (token, curve) = _launchToken(params, launchConfigId, pairToken, msg.sender);
        _exemptFromSnipeTax(curve, snipeTaxExemptions);
    }

    /**
     * @notice Launches for the initiating user of the trusted atomic
     * launch-and-buy router, with its declared opening-buy exemptions.
     * @dev Only the configured `launchForwarder` may supply `originalDeployer`.
     * This preserves the real caller without `tx.origin`, which breaks through
     * account-abstraction relayers and must never be used for authorization.
     */
    function launchTokenFor(
        TokenParams calldata params,
        uint256 launchConfigId,
        address pairToken,
        address originalDeployer,
        address[] calldata snipeTaxExemptions
    ) external payable nonReentrant returns (address token, address curve) {
        if (msg.sender != launchForwarder) revert NotLaunchForwarder();
        (token, curve) = _launchToken(params, launchConfigId, pairToken, originalDeployer);
        _exemptFromSnipeTax(curve, snipeTaxExemptions);
    }

    /**
     * @dev Applies the bounded opening-buy exemption list shared by direct and
     * forwarded launches.
     */
    function _exemptFromSnipeTax(address curve, address[] calldata snipeTaxExemptions) private {
        if (snipeTaxExemptions.length > MAX_SNIPE_TAX_EXEMPTIONS) revert ExemptionListTooLong();
        for (uint256 i = 0; i < snipeTaxExemptions.length; ++i) {
            OursBondingCurve(curve).exemptFromSnipeTax(snipeTaxExemptions[i]);
        }
    }

    /**
     * @dev Shared body of the direct and trusted-forwarder entrypoints.
     * Validates the launch terms, deploys and records the pair, and exempts
     * the creator's own addresses from the snipe tax.
     */
    function _launchToken(
        TokenParams calldata params,
        uint256 launchConfigId,
        address pairToken,
        address originalDeployer
    ) private returns (address token, address curve) {
        if (address(launchDeployer) == address(0)) revert LaunchDeployerNotSet();
        _requireLaunchDependenciesWired();
        if (!canLaunch(originalDeployer)) revert NotWhitelisted();
        if (msg.value != launchFee) revert LaunchFeeNotPaid();
        if (launchConfigId >= _launchConfigs.length) revert InvalidLaunchConfigId();
        if (bytes(params.name).length == 0 || bytes(params.symbol).length == 0) revert InvalidTokenParams();
        if (params.creatorTaxBps != 0 || params.buybackEnabled) revert CreatorTaxTooHigh();
        if (pairToken != address(0) && !approvedPairTokens[pairToken]) revert PairTokenNotApproved();

        LaunchConfig memory config = _launchConfigs[launchConfigId];
        FeePolicySnapshot memory policy = memeHook.currentFeePolicy();
        // A launch prices in whatever asset it collects, so a custom quote
        // asset supplies its own phantom reserve and threshold in its own
        // decimals rather than inheriting the config's wei-denominated pair.
        (uint256 phantomQuote, uint256 graduationThreshold) = pairToken == address(0)
            ? (config.phantomQuote, config.graduationThreshold)
            : (pairTokenEconomics[pairToken].phantomQuote, pairTokenEconomics[pairToken].graduationThreshold);
        // The scale was verified at approval, but an upgradeable quote asset
        // can change it afterwards, and this curve prices against the stored
        // figure for its entire life. Re-reading here keeps a silent
        // twelve-order-of-magnitude mispricing out of the launch.
        if (pairToken != address(0)) {
            _requireDecimals(pairToken, pairTokenEconomics[pairToken].decimals, true);
        }
        // Every term below is owner-updatable, so a creator may pin the whole
        // set they were quoted rather than accept whatever is current when
        // their transaction lands.
        bytes32 economics = _economicsDigest(config, policy, phantomQuote, graduationThreshold);
        if (params.expectedEconomics != bytes32(0) && params.expectedEconomics != economics) {
            revert LaunchEconomicsMismatch(params.expectedEconomics, economics);
        }
        if (!config.enabled) revert LaunchConfigDisabled();
        // Unreachable while the individual ceilings stay where they are, since
        // each leg caps at 1000 bps against a 2000 bps combined limit. Kept as
        // the check that would actually bind if either ceiling were raised, so
        // the combined limit does not depend on arithmetic between constants
        // declared far apart.
        if (config.curveFeeBps + params.creatorTaxBps > MAX_TOTAL_TRADE_FEE_BPS) {
            revert CombinedFeeTooHigh();
        }
        if (policy.hookFeeBps + params.creatorTaxBps > MAX_TOTAL_TRADE_FEE_BPS) {
            revert CombinedFeeTooHigh();
        }
        // A config and a quote asset are validated separately but graduate as
        // a pair, and it is the pair that fixes the seed. Terms that imply a
        // position V4 will not mint are refused here, while the creator still
        // has their fee and nothing has been deployed.
        _requireSeedableTerms(config.supply, phantomQuote, graduationThreshold, config.tickSpacing);

        address creatorFeeRecipient =
            params.creatorFeeRecipient == address(0) ? originalDeployer : params.creatorFeeRecipient;

        (token, curve) = launchDeployer.deployLaunch(
            LaunchDeployment({
                pairToken: pairToken,
                creatorFeeRecipient: creatorFeeRecipient,
                originalDeployer: originalDeployer,
                registry: revenueRegistry,
                phantomQuote: phantomQuote,
                curveFeeBps: config.curveFeeBps,
                graduationThreshold: graduationThreshold,
                supply: config.supply,
                salt: params.salt,
                name: params.name,
                symbol: params.symbol,
                logo: params.logo,
                description: params.description,
                socials: params.socials
            })
        );
        OursBondingCurve(curve).initialize(token);
        revenueRegistry.registerProject(token,curve,originalDeployer,params.revenuePolicy);
        address[] memory modules = revenueRegistry.strategiesOf(token);
        address[] memory excluded = new address[](modules.length + 13);
        excluded[0]=curve; excluded[1]=address(poolManager); excluded[2]=address(memeHook);
        excluded[3]=address(this); excluded[4]=address(launchDeployer); excluded[5]=address(graduationExecutor);
        excluded[6]=address(locker); excluded[7]=address(positionManager); excluded[8]=revenueRegistry.feePool();
        excluded[9]=launchForwarder; excluded[10]=revenueRegistry.platformRecipient();
        excluded[11]=address(revenueRegistry); excluded[12]=revenueRegistry.settlementRouter();
        for(uint256 i; i<modules.length; ++i) excluded[13+i]=modules[i];
        OursLauncherToken(token).configureObservers(revenueRegistry.tokenObserverFactoriesOf(token),excluded);

        // The creator's own addresses never count as snipers on their own
        // launch: an atomic dev buy lands in the launch second, exactly when
        // the tax peaks, and would otherwise be consumed by it.
        OursBondingCurve(curve).exemptFromSnipeTax(originalDeployer);
        if (creatorFeeRecipient != originalDeployer) {
            OursBondingCurve(curve).exemptFromSnipeTax(creatorFeeRecipient);
        }

        _launchedTokens[token] = LaunchedToken({
            token: token,
            curve: curve,
            deployer: originalDeployer,
            creatorFeeRecipient: creatorFeeRecipient,
            pairToken: pairToken,
            graduationThreshold: graduationThreshold,
            poolFee: config.poolFee,
            tickSpacing: config.tickSpacing,
            creatorTaxBps: params.creatorTaxBps,
            buybackEnabled: params.buybackEnabled,
            phase: GraduationPhase.NotGraduated,
            sweptQuote: 0,
            sweptTokens: 0,
            sweptAt: 0,
            exists: true
        });
        _launchFeePolicies[token] = policy;

        // Last, after the launch is fully recorded: this forwards ETH to the
        // protocol recipient, which may be a contract that calls back in.
        _payLaunchFee();

        emit TokenLaunched(token, curve, originalDeployer, pairToken, launchConfigId, graduationThreshold);
    }

    /**
     * @dev Prevents launches until every singleton and helper points back to
     * this factory and to the same core dependencies. A partially wired stack
     * could otherwise accept buys but later block fee sweeps or graduation.
     */
    function _requireLaunchDependenciesWired() private view {
        if(address(revenueRegistry)==address(0)||address(graduationExecutor)==address(0))revert LaunchDependenciesNotWired();
        if(launchDeployer.factory()!=address(this)||graduationExecutor.factory()!=address(this)||memeHook.factory()!=address(this)||locker.factory()!=address(this))revert LaunchDependenciesNotWired();
        if(address(memeHook.poolManager())!=address(poolManager)||address(memeHook.revenueRegistry())!=address(revenueRegistry))revert LaunchDependenciesNotWired();
        if(locker.positionManager()!=address(positionManager)||address(graduationExecutor.positionManager())!=address(positionManager)||address(graduationExecutor.permit2())!=address(permit2)||address(graduationExecutor.locker())!=address(locker))revert LaunchDependenciesNotWired();
    }

    /**
     * @dev Reconstructs the pool ID for an already-graduated launch from its
     * snapshotted config, since the factory does not separately store it.
     */
    function _poolIdFor(address token, LaunchedToken storage launch) private view returns (PoolId) {
        (Currency currency0, Currency currency1,) = _sortCurrencies(token, launch.pairToken);
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: launch.poolFee,
            tickSpacing: launch.tickSpacing,
            hooks: IHooks(address(memeHook))
        });
        return key.toId();
    }

    // ---------------------------------------------------------------------
    // Graduation, phase 1: drain the curve
    // ---------------------------------------------------------------------

    /**
     * @notice Sweeps the curve's remaining quote and token reserves into this
     * factory and halts curve trading. Purely internal to the curve's own
     * balances, so it is safe for the curve to call this automatically the
     * instant a buy crosses the graduation threshold.
     */
    function graduate(address token) external nonReentrant {
        LaunchedToken storage launch = _launchedTokens[token];
        if (!launch.exists) revert TokenNotFound();
        if (launch.phase != GraduationPhase.NotGraduated) revert WrongGraduationPhase();
        OursBondingCurve curve = OursBondingCurve(launch.curve);
        if (!curve.readyToGraduate()) {
            revert OursBondingCurve.NotReadyToGraduate();
        }
        _assertGraduationSeedable(token, launch, curve.realQuoteReserve(), curve.tokenReserve());
        _sweepCurve(token, launch, curve);
    }

    /**
     * @notice Mirrors a registered curve's failed automatic graduation on the
     * factory so indexers can subscribe to one address for every launch.
     * @dev Event-only callback: deliberately not nonReentrant, since a curve
     * may report while an outer factory operation is still active.
     */
    function reportAutoGraduationFailed(address token, uint256 gasRemaining) external {
        LaunchedToken storage launch = _launchedTokens[token];
        if (!launch.exists) revert TokenNotFound();
        if (msg.sender != launch.curve) revert NotLaunchCurve();
        if (launch.phase != GraduationPhase.NotGraduated) revert WrongGraduationPhase();
        emit LaunchAutoGraduationFailed(token, msg.sender, gasRemaining);
    }

    /**
     * @notice Sweeps a curve whose seed the preflight refuses, moving its
     * reserves into this factory so the delayed rescue path can return them.
     * @dev The preflight in `graduate` runs before the irreversible sweep, so
     * a launch it refuses stays in NotGraduated. Trading is already closed at
     * that point, because the curve shuts its sell side the moment it is ready
     * to graduate, and `rescueSweptGraduation` keys off the Swept phase, so
     * without this the reserves would have no exit at all. Restricted to
     * launches the preflight genuinely refuses: while a seed is still viable
     * anyone can call `graduate` and this reverts, so it cannot be used to
     * take a healthy launch's reserves in place of seeding its pool. The
     * rescue timelock still runs from the sweep recorded here.
     */
    function forceSweptGraduation(address token) external onlyOwner nonReentrant {
        LaunchedToken storage launch = _launchedTokens[token];
        if (!launch.exists) revert TokenNotFound();
        if (launch.phase != GraduationPhase.NotGraduated) revert WrongGraduationPhase();
        OursBondingCurve curve = OursBondingCurve(launch.curve);
        if (!curve.readyToGraduate()) {
            revert OursBondingCurve.NotReadyToGraduate();
        }
        if (_graduationSeedable(token, launch, curve.realQuoteReserve(), curve.tokenReserve())) {
            revert GraduationStillViable();
        }

        _sweepCurve(token, launch, curve);
        emit LaunchForceSwept(token);
    }

    /**
     * @dev Moves a ready curve's reserves into this factory and records the
     * Swept phase. Shared by the normal graduation path and the forced sweep,
     * which differ only in the preflight that precedes them.
     */
    function _sweepCurve(address token, LaunchedToken storage launch, OursBondingCurve curve) private {
        // Record what this factory actually received rather than what the
        // curve reported sending. A quote asset that does not deliver its
        // full nominal amount would otherwise leave the launch claiming a
        // balance it never got, and the shortfall would be drawn from
        // whatever other launches are holding the same asset in escrow here.
        uint256 quoteBefore = _quoteBalance(launch.pairToken);
        (, uint256 tokenOut) = curve.graduate(address(this));
        uint256 quoteOut = _quoteBalance(launch.pairToken) - quoteBefore;
        if (quoteOut == 0) revert NothingToGraduate();

        launch.sweptQuote = quoteOut;
        launch.sweptTokens = tokenOut;
        launch.sweptAt = block.timestamp;
        launch.phase = GraduationPhase.Swept;

        emit LaunchSwept(token, quoteOut, tokenOut);
    }

    /**
     * @dev Whether the seed these reserves imply is one V4 would mint. Mirrors
     * `_assertGraduationSeedable` without reverting, so the forced sweep can
     * tell a stuck launch from a healthy one. A seed that rounds to nothing is
     * reported as unseedable too, since `_poolTokenAmount` refuses it and the
     * launch is stuck on that path just the same.
     */
    function _graduationSeedable(address token, LaunchedToken storage launch, uint256 sweptQuote, uint256 sweptTokens)
        private
        view
        returns (bool)
    {
        if (sweptQuote == 0 || sweptTokens == 0) return false;
        uint256 virtualQuote = sweptQuote + OursBondingCurve(launch.curve).phantomQuote();
        uint256 poolTokenAmount = FullMath.mulDiv(sweptTokens, sweptQuote, virtualQuote);
        if (poolTokenAmount == 0) return false;

        try graduationGuard.assertSeedable(token, launch.pairToken, launch.tickSpacing, sweptQuote, poolTokenAmount) {
            return true;
        } catch {
            return false;
        }
    }

    /**
     * @dev This factory's holding of a launch's quote asset, covering both the
     * native and ERC-20 cases so graduation can measure a delta either way.
     */
    function _quoteBalance(address pairToken) private view returns (uint256) {
        return pairToken == address(0) ? address(this).balance : IERC20(pairToken).balanceOf(address(this));
    }

    // ---------------------------------------------------------------------
    // Graduation, phase 2: seed the V4 pool
    // ---------------------------------------------------------------------

    /**
     * @notice Initializes the V4 pool with the swept reserves, mints a
     * full-range position directly to the locker, and registers the pool with
     * the meme hook. The curve already holds the pool's quote asset, so this
     * seeds with exactly what it swept and needs no slippage bound.
     * Permissionless and retryable: a launch stays in Swept until a seed
     * succeeds, so a transient failure can never strand reserves.
     */
    function createGraduatedPool(address token) external nonReentrant returns (uint256 positionId) {
        if (address(graduationExecutor) == address(0)) revert GraduationExecutorNotSet();
        LaunchedToken storage launch = _launchedTokens[token];
        if (!launch.exists) revert TokenNotFound();
        if (launch.phase != GraduationPhase.Swept) revert WrongGraduationPhase();

        uint256 sweptQuote = launch.sweptQuote;
        _assertGraduationSeedable(token, launch, sweptQuote, launch.sweptTokens);
        uint256 tokenAmount = _lockExcessGraduationTokens(token, launch, sweptQuote, launch.sweptTokens);

        launch.sweptQuote = 0;
        launch.sweptTokens = 0;
        launch.sweptAt = 0;
        launch.phase = GraduationPhase.PoolCreated;

        positionId = _createPoolAndMintPosition(token, launch, tokenAmount, sweptQuote);

        emit PoolGraduated(token, positionId, tokenAmount, sweptQuote);
    }

    /**
     * @notice Pays a still-trading launch's pending curve fees directly to the
     * protocol and creator recipients, bypassing the escrow, when its quote
     * asset has stopped delivering there.
     * @dev Also the only way to unwedge such a launch's graduation, since
     * `graduate` sweeps fees before handing over the reserves and cannot
     * succeed while that sweep reverts. Clearing the buckets makes the sweep
     * a no-op and lets graduation proceed.
     */


    /**
     * @notice Releases a swept launch's reserves to `recipient` when its quote
     * asset can no longer satisfy the seed step. `graduate` accepts a quote
     * asset that under-delivers, because it credits the balance it actually
     * received, but the seed leg funds the executor through `_transferExact`
     * and requires the full nominal amount. An asset that becomes
     * fee-on-transfer, rebasing, or blocklisting after approval therefore
     * leaves a launch that has already halted its curve with a seed step that
     * can never succeed, and every holder's quote asset frozen behind it.
     *
     * Deliberately does not use `_transferExact`: the asset's inability to
     * deliver exactly is the reason this path exists, so requiring it here
     * would reproduce the failure it recovers from. The reserves are moved
     * whole to a single recipient for off-chain distribution rather than
     * split on chain, since a launch in this state has no reliable way to pay
     * many holders in an asset that cannot pay one.
     *
     * The owner is trusted here, bounded by GRADUATION_RESCUE_DELAY. What
     * makes that bound meaningful is that seeding stays permissionless
     * throughout the wait: any holder can end the window early, and
     * permanently, with one call to createGraduatedPool. Reserves only stay
     * reachable by this path if nobody could seed them.
     *
     * Mirrors OursMemeHook.rescuePoolFees, which covers the same asset class
     * for the post-graduation pool.
     */
    function rescueSweptGraduation(address token, address recipient) external onlyOwner nonReentrant {
        LaunchedToken storage launch = _launchedTokens[token];
        if (!launch.exists) revert TokenNotFound();
        if (launch.phase != GraduationPhase.Swept) revert WrongGraduationPhase();
        if (recipient == address(0)) revert ZeroAddress();

        uint256 availableAt = launch.sweptAt + GRADUATION_RESCUE_DELAY;
        if (block.timestamp < availableAt) revert GraduationRescueTooEarly(availableAt);

        uint256 quoteAmount = launch.sweptQuote;
        uint256 tokenAmount = launch.sweptTokens;
        address pairToken = launch.pairToken;

        launch.sweptQuote = 0;
        launch.sweptTokens = 0;
        launch.sweptAt = 0;
        launch.phase = GraduationPhase.Rescued;

        if (quoteAmount != 0) {
            if (pairToken == address(0)) {
                (bool sent,) = payable(recipient).call{value: quoteAmount}("");
                if (!sent) revert FeeTransferFailed();
            } else {
                IERC20(pairToken).safeTransfer(recipient, quoteAmount);
            }
        }
        if (tokenAmount != 0) {
            IERC20(token).safeTransfer(recipient, tokenAmount);
        }

        emit LaunchGraduationRescued(token, recipient, quoteAmount, tokenAmount);
    }

    /**
     * @dev Uses only the token amount that preserves the terminal curve price
     * against the physically held graduation quote asset. The virtual-reserve
     * remainder is permanently locked in the launch locker and never enters
     * circulation.
     */
    function _lockExcessGraduationTokens(
        address token,
        LaunchedToken storage launch,
        uint256 sweptQuote,
        uint256 totalTokenAmount
    ) private returns (uint256 poolTokenAmount) {
        poolTokenAmount = _poolTokenAmount(launch, sweptQuote, totalTokenAmount);

        uint256 excess = totalTokenAmount - poolTokenAmount;
        if (excess != 0) {
            IERC20(token).forceApprove(address(locker), excess);
            locker.lockTokenSupply(token, excess);
            emit GraduationTokensPermanentlyLocked(token, excess);
        }
    }

    /**
     * @dev Derives the reserve fraction that preserves the curve's terminal
     * price after the virtual quote reserve is removed from the pool seed.
     */
    function _poolTokenAmount(LaunchedToken storage launch, uint256 sweptQuote, uint256 totalTokenAmount)
        private
        view
        returns (uint256 poolTokenAmount)
    {
        if (sweptQuote == 0 || totalTokenAmount == 0) revert NothingToGraduate();
        uint256 virtualQuote = sweptQuote + OursBondingCurve(launch.curve).phantomQuote();
        poolTokenAmount = FullMath.mulDiv(totalTokenAmount, sweptQuote, virtualQuote);
        if (poolTokenAmount == 0) revert NothingToGraduate();
    }

    /**
     * @dev Runs the V4 mint preflight while the curve is still reversible, so
     * a launch can never reach the irreversible Swept phase with a seed that
     * would be rejected. It also rejects amounts the executor could only
     * represent through a lossy uint128 cast.
     */
    function _assertGraduationSeedable(
        address token,
        LaunchedToken storage launch,
        uint256 sweptQuote,
        uint256 sweptTokens
    ) private view {
        uint256 poolTokenAmount = _poolTokenAmount(launch, sweptQuote, sweptTokens);
        graduationGuard.assertSeedable(token, launch.pairToken, launch.tickSpacing, sweptQuote, poolTokenAmount);
    }

    /**
     * @dev Initializes the V4 pool and registers it with the meme hook, then
     * hands the exact minted assets to OursGraduationExecutor to encode
     * the Permit2 approvals and PositionManager mint call. That step is
     * split into its own contract purely to keep this factory's own
     * bytecode under EIP-170's size limit.
     */
    function _createPoolAndMintPosition(
        address token,
        LaunchedToken storage launch,
        uint256 tokenAmount,
        uint256 pairTokenAmount
    ) private returns (uint256 positionId) {
        (Currency currency0, Currency currency1, bool memecoinIsCurrency0) = _sortCurrencies(token, launch.pairToken);
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: launch.poolFee,
            tickSpacing: launch.tickSpacing,
            hooks: IHooks(address(memeHook))
        });

        (uint256 amount0, uint256 amount1) =
            memecoinIsCurrency0 ? (tokenAmount, pairTokenAmount) : (pairTokenAmount, tokenAmount);
        if (amount0 > type(uint128).max || amount1 > type(uint128).max) revert GraduationSeedNotViable();
        uint160 sqrtPriceX96 = OursGraduationMath.sqrtPriceX96FromAmounts(amount0, amount1);
        if (sqrtPriceX96 <= TickMath.MIN_SQRT_PRICE || sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE) {
            revert SqrtPriceOutOfBounds();
        }

        poolManager.initialize(key, sqrtPriceX96);
        FeePolicySnapshot memory policy = _launchFeePolicies[token];
        // Register the snapshotted trade fee; revenue policy versions live in Registry.
        memeHook.registerPool(key, token, policy.hookFeeBps);

        (int24 tickLower, int24 tickUpper) = _fullRangeTicks(launch.tickSpacing);
        positionId = positionManager.nextTokenId();

        uint256 nativeValue = _fundGraduationExecutor(currency0, currency1, amount0, amount1);
        graduationExecutor.mintFullRangePosition{value: nativeValue}(
            token,
            key,
            tickLower,
            tickUpper,
            sqrtPriceX96,
            amount0,
            amount1,
            currency0,
            currency1,
            policy.protocolFeeRecipient
        );
        locker.lockPosition(token, positionId);
        revenueRegistry.bindGraduatedPool(token, PoolId.unwrap(key.toId()), address(memeHook));
    }

    /**
     * @dev Transfers exactly the assets a mint needs to the graduation
     * executor, returning whichever amount is native ETH (if either leg is)
     * so the caller can forward it as `msg.value` on the mint call itself.
     */
    function _fundGraduationExecutor(Currency currency0, Currency currency1, uint256 amount0, uint256 amount1)
        private
        returns (uint256 nativeValue)
    {
        if (currency0.isAddressZero()) {
            nativeValue = amount0;
        } else {
            _transferExact(Currency.unwrap(currency0), address(graduationExecutor), amount0);
        }
        if (currency1.isAddressZero()) {
            nativeValue = amount1;
        } else {
            _transferExact(Currency.unwrap(currency1), address(graduationExecutor), amount1);
        }
    }

    /**
     * @dev Rejects non-exact ERC-20 transfers before a V4 position can be
     * minted with a smaller balance than its accounting expects.
     */
    function _transferExact(address token, address recipient, uint256 amount) private {
        uint256 balanceBefore = IERC20(token).balanceOf(recipient);
        IERC20(token).safeTransfer(recipient, amount);
        uint256 balanceAfter = IERC20(token).balanceOf(recipient);
        uint256 received = balanceAfter > balanceBefore ? balanceAfter - balanceBefore : 0;
        if (received != amount) revert InexactTransfer(token, amount, received);
    }

    function _payLaunchFee() private {
        if (launchFee == 0) return;
        address recipient = memeHook.protocolFeeRecipient();
        if (recipient == address(0)) revert ZeroAddress();
        (bool sent,) = payable(recipient).call{value: launchFee}("");
        if (!sent) revert FeeTransferFailed();
    }

    function _sortCurrencies(address memecoin, address pairToken)
        private
        pure
        returns (Currency currency0, Currency currency1, bool memecoinIsCurrency0)
    {
        if (pairToken < memecoin) {
            return (Currency.wrap(pairToken), Currency.wrap(memecoin), false);
        }
        return (Currency.wrap(memecoin), Currency.wrap(pairToken), true);
    }

    function _fullRangeTicks(int24 tickSpacing) private pure returns (int24 tickLower, int24 tickUpper) {
        // The caller uses a launch's validated, positive int24 tickSpacing.
        // The product is bounded by 887272; neither result can overflow int24.
        // Symmetry plus truncation toward zero gives the exact lower boundary.
        assembly ("memory-safe") {
            let spacing := signextend(2, tickSpacing)
            tickUpper := mul(sdiv(887272, spacing), spacing)
            tickLower := sub(0, tickUpper)
        }
    }

    function _validateLaunchConfig(LaunchConfig calldata config) private pure {
        if (config.curveFeeBps > MAX_CURVE_FEE_BPS) revert CurveFeeTooHigh();
        if (config.supply < MIN_LAUNCH_SUPPLY) revert SupplyTooLow();
        // A supply above the seed ceiling would deploy a curve and token that
        // trade normally, then revert forever at graduation with the reserves
        // already swept out of the curve. The PositionManager's ABI takes the
        // amount as a uint128, but V4 core narrows it to int128, so the signed
        // bound is the one that has to be enforced here.
        if (config.supply > MAX_SEED_AMOUNT) revert SupplyTooHigh();
        if (config.phantomQuote == 0) revert InvalidPhantomQuote();
        if (config.graduationThreshold == 0) revert InvalidGraduationThreshold();
        if (config.tickSpacing <= 0 || config.tickSpacing > MAX_TICK_SPACING) revert InvalidTickSpacing();
        if (config.poolFee != 0) revert CoreLpFeeMustBeZero();
        _requireQuotable(config.phantomQuote, config.supply, config.curveFeeBps);
    }

    /**
     * @notice Reverts unless a small reference buy against a fresh curve with
     * these terms would return a non-zero amount of tokens.
     * @dev A phantom reserve set far too large against the supply prices every
     * realistic trade to zero, and the curve reverts on all of them. That
     * launch is dead on arrival but still deployable, and its creator has
     * already paid the launch fee, so the terms are rejected before any
     * contract exists rather than after.
     */
    function _requireQuotable(uint256 phantomQuote, uint256 supply, uint256 curveFeeBps) private pure {
        uint256 referenceBuy = phantomQuote / REFERENCE_BUY_DIVISOR;
        if (OursBondingCurveMath.quoteAmountOut(referenceBuy, phantomQuote, supply, curveFeeBps) == 0) {
            revert CurveNotQuotable();
        }
    }

    /**
     * @notice Reverts unless the seed these launch terms imply is one Uniswap
     * V4 would mint.
     * @dev Graduation drains a fixed share of supply against a quote reserve
     * the threshold fixes, so the seed is determined by the terms rather than
     * by how the curve is traded. Rejecting unmintable proportions at launch
     * keeps a curve from taking deposits it could never graduate. Fees and the
     * creator tax move the realised quote slightly off the threshold, so this
     * narrows the failure rather than removing it, and forceSweptGraduation
     * remains the backstop for whatever it does not catch.
     */
    function _requireSeedableTerms(uint256 supply, uint256 phantomQuote, uint256 graduationThreshold, int24 tickSpacing)
        private
        view
    {
        uint256 virtualQuote = phantomQuote + graduationThreshold;
        uint256 reserved = FullMath.mulDiv(supply, phantomQuote, virtualQuote);
        uint256 poolTokenAmount = FullMath.mulDiv(reserved, graduationThreshold, virtualQuote);
        // Terms whose token side rounds away have nothing to seed with, and
        // the price the guard derives from a zero amount is undefined.
        if (poolTokenAmount == 0) revert GraduationSeedNotViable();
        graduationGuard.assertSeedableEitherOrdering(tickSpacing, graduationThreshold, poolTokenAmount);
    }

    /**
     * @notice Accepts native ETH swept from a graduating curve and any
     * dust refunded by the PositionManager or pairToken router.
     */
    receive() external payable {}
}
