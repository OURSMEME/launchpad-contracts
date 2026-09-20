// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

interface IPlatformRewardTreasury {
    function rewardDistributor() external view returns (address);
    function platformToken() external view returns (address);
    function releaseRewards(uint256 amount) external;
}

/// @notice Contribution rewards, separate from project-holder dividends.
/// @dev Reviewer attests off-chain contributions. Active roots and funded claims cannot be withdrawn.
contract OursPlatformRewardDistributor is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    error Invalid(); error Unauthorized(); error TransferMismatch();
    enum Status { Unset, Funded, Proposed, Active }
    struct Epoch {
        uint256 funded;
        uint256 totalEntitlement;
        uint256 claimedAmount;
        uint64 claimableAt;
        bytes32 root;
        bytes32 manifestHash;
        Status status;
    }
    IERC20 public immutable platformToken;
    uint64 public immutable reviewDelay;
    address public reviewer;
    IPlatformRewardTreasury public treasury;
    uint256 public nextEpoch = 1;
    uint256 public totalLiability;
    mapping(uint256 => Epoch) public epochs;
    mapping(uint256 => mapping(address => bool)) public claimed;
    event TreasuryBound(address indexed treasury);
    event ReviewerSet(address indexed reviewer);
    event Funded(uint256 indexed epoch, uint256 amount);
    event Proposed(uint256 indexed epoch, bytes32 root, bytes32 manifestHash, uint256 total, uint64 claimableAt);
    event Cancelled(uint256 indexed epoch);
    event Activated(uint256 indexed epoch);
    event Claimed(uint256 indexed epoch, address indexed account, uint256 amount);

    constructor(address governance, IERC20 token, address reviewer_, uint64 delay_) Ownable(governance) {
        if(address(token).code.length==0 || reviewer_==address(0) || delay_==0) revert Invalid();
        platformToken=token; reviewer=reviewer_; reviewDelay=delay_;
    }
    modifier onlyReviewer() { if(msg.sender!=reviewer) revert Unauthorized(); _; }
    function renounceOwnership() public override onlyOwner { revert Invalid(); }
    function setReviewer(address account) external onlyOwner {
        if(account==address(0)) revert Invalid(); reviewer=account; emit ReviewerSet(account);
    }
    function bindTreasury(IPlatformRewardTreasury target) external onlyOwner {
        if(address(treasury)!=address(0) || target.rewardDistributor()!=address(this)
            || target.platformToken()!=address(platformToken)) revert Invalid();
        treasury=target; emit TreasuryBound(address(target));
    }
    /// @notice Each call funds a new immutable budget. No implicit contribution list or periodic scheduler.
    function fundEpoch(uint256 amount) external onlyOwner nonReentrant returns(uint256 id) {
        if(amount==0 || address(treasury)==address(0)) revert Invalid();
        uint256 before_=platformToken.balanceOf(address(this));
        treasury.releaseRewards(amount);
        if(platformToken.balanceOf(address(this))!=before_+amount) revert TransferMismatch();
        id=nextEpoch++; epochs[id].funded=amount; epochs[id].status=Status.Funded;
        totalLiability+=amount; emit Funded(id,amount);
    }
    function propose(uint256 id, bytes32 root, bytes32 manifestHash, uint256 total) external onlyReviewer {
        Epoch storage e=epochs[id];
        if(e.status!=Status.Funded || root==0 || manifestHash==0 || total==0 || total>e.funded) revert Invalid();
        e.root=root; e.manifestHash=manifestHash; e.totalEntitlement=total;
        e.claimableAt=uint64(block.timestamp)+reviewDelay; e.status=Status.Proposed;
        emit Proposed(id,root,manifestHash,total,e.claimableAt);
    }
    function cancel(uint256 id) external onlyReviewer {
        Epoch storage e=epochs[id];
        if(e.status!=Status.Proposed || block.timestamp>=e.claimableAt) revert Invalid();
        e.root=0; e.manifestHash=0; e.totalEntitlement=0; e.claimableAt=0; e.status=Status.Funded;
        emit Cancelled(id);
    }
    function activate(uint256 id) external {
        Epoch storage e=epochs[id];
        if(e.status!=Status.Proposed || block.timestamp<e.claimableAt) revert Invalid();
        e.status=Status.Active; emit Activated(id);
    }
    function leaf(uint256 id, address account, uint256 amount) public view returns(bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(block.chainid,address(this),id,account,amount))));
    }
    function claim(uint256 id, uint256 amount, bytes32[] calldata proof) external nonReentrant {
        Epoch storage e=epochs[id];
        if(e.status!=Status.Active || amount==0 || claimed[id][msg.sender]
            || !MerkleProof.verifyCalldata(proof,e.root,leaf(id,msg.sender,amount))
            || e.claimedAmount+amount>e.totalEntitlement) revert Invalid();
        claimed[id][msg.sender]=true; e.claimedAmount+=amount; totalLiability-=amount;
        uint256 before_=platformToken.balanceOf(address(this));
        uint256 userBefore=platformToken.balanceOf(msg.sender);
        platformToken.safeTransfer(msg.sender,amount);
        if(platformToken.balanceOf(address(this))+amount!=before_
            || platformToken.balanceOf(msg.sender)!=userBefore+amount) revert TransferMismatch();
        emit Claimed(id,msg.sender,amount);
    }
}
