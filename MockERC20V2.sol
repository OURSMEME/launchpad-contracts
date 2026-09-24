// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @notice Test platform token with a per-address faucet and holder-controlled burning.
contract MockERC20V2 is ERC20, ERC20Burnable, Ownable2Step {
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18;
    uint256 public constant MINT_AMOUNT = 100_000 * 10 ** 18;
    uint256 public constant MINT_INTERVAL = 24 hours;

    mapping(address => uint256) public nextMintAt;
    bool public mintEnabled = true;

    error MintDisabled();
    error MintCooldown(uint256 availableAt);
    event MintEnabledChanged(bool enabled);
    event FaucetMinted(address indexed account, uint256 amount, uint256 nextMintAt);

    /// @dev Initial supply goes to the deployer. First faucet mint is available immediately.
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) Ownable(msg.sender) {
        _mint(msg.sender, INITIAL_SUPPLY);
    }

    /// @notice Enable or disable faucet minting without changing existing cooldowns.
    function setMintEnabled(bool enabled) external onlyOwner {
        mintEnabled = enabled;
        emit MintEnabledChanged(enabled);
    }

    /// @notice Mint exactly 100,000 tokens to yourself once every rolling 24 hours.
    /// @dev Missed periods do not accumulate. Transfers and burns do not reset the cooldown.
    function mint() external {
        if (!mintEnabled) revert MintDisabled();
        uint256 availableAt = nextMintAt[msg.sender];
        if (block.timestamp < availableAt) revert MintCooldown(availableAt);

        uint256 next = block.timestamp + MINT_INTERVAL;
        nextMintAt[msg.sender] = next;
        _mint(msg.sender, MINT_AMOUNT);
        emit FaucetMinted(msg.sender, MINT_AMOUNT, next);
    }
}
