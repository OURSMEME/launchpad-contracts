// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

import {OursLauncherToken} from "./OursLauncherToken.sol";
import {OursBondingCurve} from "./OursBondingCurve.sol";
import {OursProjectRegistry} from "./revenue/OursProjectRegistry.sol";
import {FeePolicySnapshot, IOursFeeEscrow, IOursFeePolicy} from "./interfaces/ILaunchpad.sol";

/**
 * @notice Every input OursLaunchFactory hands the deployer to stand up one
 * launch. Grouped into a single calldata struct rather than a flat parameter
 * list so the deployer stays inside the EVM's 16-slot stack window when
 * compiled without the IR pipeline, which is the mode `forge coverage` uses.
 */
struct LaunchDeployment {
    address pairToken;
    address creatorFeeRecipient;
    address originalDeployer;
    OursProjectRegistry registry;
    uint256 phantomQuote;
    uint256 curveFeeBps;
    uint256 graduationThreshold;
    uint256 supply;
    // Raw CREATE2 salt shared by all creators; suitable for a precomputed address pool.
    bytes32 salt;
    string name;
    string symbol;
    string logo;
    string description;
    OursLauncherToken.Socials socials;
}

/**
 * @title OursLaunchDeployer
 * @notice Deploys the bonding curve and launch token pair for one Ours
 * launch on OursLaunchFactory's behalf. Split out into its own contract
 * purely so OursLaunchFactory's own bytecode stays under EIP-170's
 * 24576-byte deployed-code limit: embedding two full contracts' creation
 * code via `new` inside the factory itself was the single largest
 * contributor to its size. Both new contracts still record the real
 * factory's address explicitly (never this deployer's), since they gate
 * privileged calls on it.
 */
contract OursLaunchDeployer {
    // Metadata is stored on the token and read back by unbounded-return view
    // functions, so an unbounded write here becomes a permanently unreadable
    // token: `socials()` returns all five strings at once and would run out
    // of gas or time out an RPC node. Bounding the write is the only place
    // the limit can be enforced, since the strings are immutable afterwards.
    uint256 private constant MAX_NAME_LENGTH = 64;
    uint256 private constant MAX_SYMBOL_LENGTH = 16;
    uint256 private constant MAX_LOGO_LENGTH = 512;
    uint256 private constant MAX_DESCRIPTION_LENGTH = 2048;
    uint256 private constant MAX_SOCIAL_LENGTH = 256;

    error NotFactory();
    error MetadataTooLong();

    address public immutable factory;

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    constructor(address factory_) {
        if (factory_ == address(0)) revert NotFactory();
        factory = factory_;
    }

    /// @notice Deploy and initialize atomically. A salt can create only one Token per deployer.
    function deployLaunch(LaunchDeployment calldata params)
        external
        onlyFactory
        returns (address token, address curve)
    {
        _requireMetadataWithinLimits(params);

        bytes32 salt = params.salt;
        curve = Create2.deploy(0, salt, _curveCreationCode(params));
        token = Create2.deploy(0, salt, type(OursLauncherToken).creationCode);
        OursLauncherToken(token).initialize(
            params.name, params.symbol, params.logo, params.description, params.socials,
            params.originalDeployer, curve, factory, params.supply
        );
    }

    /// @notice Token depends only on raw salt; Curve also depends on its economic constructor arguments.
    function predictLaunchAddresses(LaunchDeployment calldata params)
        external
        view
        returns (address token, address curve)
    {
        bytes32 salt = params.salt;
        curve = Create2.computeAddress(salt, keccak256(_curveCreationCode(params)));
        token = Create2.computeAddress(salt, tokenInitCodeHash());
    }

    function tokenInitCodeHash() public pure returns (bytes32) {
        return keccak256(type(OursLauncherToken).creationCode);
    }

    function predictTokenAddress(bytes32 salt) external view returns (address) {
        return Create2.computeAddress(salt, tokenInitCodeHash());
    }

    /**
     * @dev Creation code for the launch's bonding curve. Shared by the deploy
     * and predict paths so the two can never derive different addresses.
     */
    function _curveCreationCode(LaunchDeployment calldata params) private view returns (bytes memory) {
        return abi.encodePacked(
            type(OursBondingCurve).creationCode,
            abi.encode(
                params.pairToken,
                factory,
                params.registry,
                params.phantomQuote,
                params.curveFeeBps,
                params.graduationThreshold
            )
        );
    }

    /**
     * @notice Reverts unless every metadata string fits its length cap.
     * @dev The factory already rejects an empty name or symbol, so only the
     * upper bound is checked here.
     */
    function _requireMetadataWithinLimits(LaunchDeployment calldata params) private pure {
        if (
            bytes(params.name).length > MAX_NAME_LENGTH || bytes(params.symbol).length > MAX_SYMBOL_LENGTH
                || bytes(params.logo).length > MAX_LOGO_LENGTH
                || bytes(params.description).length > MAX_DESCRIPTION_LENGTH
        ) {
            revert MetadataTooLong();
        }
        if (
            bytes(params.socials.twitter).length > MAX_SOCIAL_LENGTH
                || bytes(params.socials.telegram).length > MAX_SOCIAL_LENGTH
                || bytes(params.socials.discord).length > MAX_SOCIAL_LENGTH
                || bytes(params.socials.website).length > MAX_SOCIAL_LENGTH
                || bytes(params.socials.farcaster).length > MAX_SOCIAL_LENGTH
        ) {
            revert MetadataTooLong();
        }
    }
}
