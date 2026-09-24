// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IOursTokenObserver, IOursTokenObserverFactory} from "./interfaces/IOursTokenObserver.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/// @notice Fixed creation code; the deploying contract initializes metadata and mints once atomically.
contract OursLauncherToken is ERC20Burnable {
    struct Socials {
        string twitter;
        string telegram;
        string discord;
        string website;
        string farcaster;
    }

    error ZeroAddress();
    error UnauthorizedInitializer();
    error AlreadyInitialized();

    address private immutable _initializer;
    bool public initialized;
    string private _tokenName;
    string private _tokenSymbol;

    address public deployer;
    address public launchFactory;
    address public curve;

    string public logo;
    string public description;

    Socials private _socials;

    constructor() ERC20("", "") {
        _initializer = msg.sender;
    }

    bool public observersConfigured;
    bool private notifying;
    address[] private observers;
    error InvalidObserver();
    error ObserverReentry();
    event ObserverBound(address indexed factory, address indexed observer);

    function tokenObservers() external view returns (address[] memory) { return observers; }

    /// @notice Called once by the launch factory, before inventory leaves the curve.
    /// Selected, governance-approved strategy factories supply immutable per-token observers.
    function configureObservers(address[] calldata factories, address[] calldata system) external {
        if (msg.sender != launchFactory || observersConfigured) revert UnauthorizedInitializer();
        if (!initialized || balanceOf(curve) != totalSupply() || factories.length > 8) revert InvalidObserver();
        observersConfigured = true;
        notifying = true;
        for (uint256 i; i < factories.length; ++i) {
            address observer = IOursTokenObserverFactory(factories[i]).createTokenObserver(system);
            if (observer.code.length == 0 || IOursTokenObserver(observer).token() != address(this)) revert InvalidObserver();
            for (uint256 j; j < observers.length; ++j) if (observers[j] == observer) revert InvalidObserver();
            observers.push(observer);
            emit ObserverBound(factories[i], observer);
        }
        notifying = false;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (notifying) revert ObserverReentry();
        super._update(from, to, amount);
        if (observers.length == 0 || from == to || amount == 0) return;
        notifying = true;
        for (uint256 i; i < observers.length; ++i) {
            if (IOursTokenObserver(observers[i]).onBalanceChange(from, to, amount)
                != IOursTokenObserver.onBalanceChange.selector) revert InvalidObserver();
        }
        notifying = false;
    }
    function name() public view override returns (string memory) { return _tokenName; }
    function symbol() public view override returns (string memory) { return _tokenSymbol; }

    /// @dev Only the deploying contract may initialize, once. No public mint or metadata setters.
    function initialize(
        string memory name_, string memory symbol_, string memory logo_, string memory description_,
        Socials memory socials_, address deployer_, address curve_, address launchFactory_, uint256 supply_
    ) external {
        if (msg.sender != _initializer) revert UnauthorizedInitializer();
        if (initialized) revert AlreadyInitialized();
        if (deployer_ == address(0) || curve_ == address(0) || launchFactory_ == address(0)) {
            revert ZeroAddress();
        }

        initialized = true;
        _tokenName = name_;
        _tokenSymbol = symbol_;
        deployer = deployer_;
        // Passed explicitly rather than read from msg.sender: OursLaunchFactory
        // deploys this token indirectly through OursLaunchDeployer to keep its
        // own bytecode under EIP-170's size limit, so msg.sender at construction
        // time would otherwise resolve to that deployer helper, not the factory.
        launchFactory = launchFactory_;
        curve = curve_;
        logo = logo_;
        description = description_;
        _socials = socials_;

        _mint(curve_, supply_);
    }

    /**
     * @notice Returns the launch token's five social metadata fields.
     */
    function socials()
        external
        view
        returns (
            string memory twitter,
            string memory telegram,
            string memory discord,
            string memory website,
            string memory farcaster
        )
    {
        Socials memory values = _socials;
        return (values.twitter, values.telegram, values.discord, values.website, values.farcaster);
    }

    /**
     * @notice Returns creator and metadata in the launcher-compatible tuple.
     */
    function getTokenInfo()
        external
        view
        returns (
            address tokenDeployer,
            string memory tokenLogo,
            string memory tokenDescription,
            Socials memory tokenSocials
        )
    {
        return (deployer, logo, description, _socials);
    }
}
