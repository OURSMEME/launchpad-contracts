// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "./TransferHelper.sol";

/// @notice 原生币募资记账合约；正常入金会立即转给收款地址，合约不保留募资资金。
contract FundraisingNative is Initializable, OwnableUpgradeable, UUPSUpgradeable, ReentrancyGuardUpgradeable {
    /// @dev 默认单笔最小入金数量和单地址累计最大入金数量，均为 0.5 原生币。
    uint256 public constant DEFAULT_DEPOSIT_LIMIT = 0 ether;
    /// @dev 默认全局累计募集上限，为 100000000 原生币。
    uint256 public constant DEFAULT_MAX_TOTAL_RAISED = 100000000 ether;

    /// @dev 当前调用者没有操作权限。
    error Unauthorized();
    /// @dev 传入了零地址。
    error ZeroAddress();
    /// @dev 收款地址不能是当前合约自身。
    error InvalidReceivingAddress();
    /// @dev 传入了零金额。
    error ZeroAmount();
    /// @dev 操作员已存在。
    error OperatorAlreadyAdded();
    /// @dev 操作员不存在。
    error OperatorNotFound();
    /// @dev 入金额度配置非法。
    error InvalidDepositLimit();
    /// @dev 当前未开放募资。
    error DepositNotAllowed();
    /// @dev 本次入金低于单笔最小额度。
    error DepositAmountTooSmall();
    /// @dev 本次入金后会超过累计最大额度。
    error DepositLimitExceeded();
    /// @dev 本次入金后会超过全局累计募集上限。
    error TotalRaiseLimitExceeded();

    event OperatorAdded(address indexed operator, uint256 timestamp);
    event OperatorRemoved(address indexed operator, uint256 timestamp);
    event ReceivingAddressUpdated(address indexed previousAddress, address indexed newAddress, uint256 timestamp);
    event DepositLimitUpdated(uint256 minAmount, uint256 maxAmount, uint256 timestamp);
    event MaxTotalRaisedUpdated(uint256 maxTotalRaised, uint256 timestamp);
    event Deposited(
        address indexed depositor,
        uint256 amount,
        uint256 totalAmount,
        address receivingAddress,
        uint256 timestamp
    );
    event Withdrawn(address indexed token, address indexed to, uint256 amount, uint256 timestamp);

    /// @dev 正常募资资金的统一接收地址。
    address public receivingAddress;
    /// @dev 已授权的操作员地址。
    mapping(address => bool) public operators;
    /// @dev 全局单笔最小入金数量。
    uint256 public minAmount;
    /// @dev 单个地址的历史累计最大入金数量；0 表示未开放募资。
    uint256 public maxAmount;
    /// @dev 全局历史累计募集最大数量；0 表示暂停全部募资。
    uint256 public maxTotalRaised;
    /// @dev 入金地址 => 历史累计已募资原生币数量。
    mapping(address => uint256) public totalDeposited;
    /// @dev 已成功募资的唯一地址列表。
    address[] private depositors;
    /// @dev 历史累计募集原生币总额。
    uint256 private totalRaised;

    /// @dev 仅允许 owner 或操作员调用。
    modifier onlyOwnerOrOperator() {
        if (msg.sender != owner() && !operators[msg.sender]) revert Unauthorized();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice 初始化原生币募资合约。
    /// @param owner_ 合约管理员地址。
    /// @param receivingAddress_ 正常募资资金的接收地址。
    function initialize(address owner_, address receivingAddress_) external initializer {
        if (owner_ == address(0) || receivingAddress_ == address(0)) revert ZeroAddress();
        if (receivingAddress_ == address(this)) revert InvalidReceivingAddress();

        __Ownable_init(owner_);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        receivingAddress = receivingAddress_;
        minAmount = DEFAULT_DEPOSIT_LIMIT;
        maxAmount = DEFAULT_DEPOSIT_LIMIT;
        maxTotalRaised = DEFAULT_MAX_TOTAL_RAISED;
    }

    /// @notice 接收直接转入的原生币，并按额度记账后立即转给收款地址。
    receive() external payable nonReentrant {
        _depositNative();
    }

    /// @notice 添加操作员。
    /// @param operator 操作员地址。
    function addOperator(address operator) external onlyOwner {
        if (operator == address(0)) revert ZeroAddress();
        if (operators[operator]) revert OperatorAlreadyAdded();

        operators[operator] = true;
        emit OperatorAdded(operator, block.timestamp);
    }

    /// @notice 移除操作员。
    /// @param operator 操作员地址。
    function removeOperator(address operator) external onlyOwner {
        if (!operators[operator]) revert OperatorNotFound();

        operators[operator] = false;
        emit OperatorRemoved(operator, block.timestamp);
    }

    /// @notice 更新正常募资资金的统一接收地址。
    /// @param receivingAddress_ 新的收款地址。
    function setReceivingAddress(address receivingAddress_) external onlyOwner {
        if (receivingAddress_ == address(0)) revert ZeroAddress();
        if (receivingAddress_ == address(this)) revert InvalidReceivingAddress();

        address previousAddress = receivingAddress;
        receivingAddress = receivingAddress_;
        emit ReceivingAddressUpdated(previousAddress, receivingAddress_, block.timestamp);
    }

    /// @notice 设置所有用户共用的原生币募资额度。
    /// @param minAmount_ 全局单笔最小入金数量。
    /// @param maxAmount_ 单个地址的历史累计最大入金数量；两者同时为 0 时关闭募资。
    function setDepositLimit(uint256 minAmount_, uint256 maxAmount_) external onlyOwnerOrOperator {
        if (maxAmount_ == 0) {
            if (minAmount_ != 0) revert InvalidDepositLimit();
        } else if (minAmount_ == 0 || minAmount_ > maxAmount_) {
            revert InvalidDepositLimit();
        }

        minAmount = minAmount_;
        maxAmount = maxAmount_;
        emit DepositLimitUpdated(minAmount_, maxAmount_, block.timestamp);
    }

    /// @notice 设置全局历史累计募集上限。
    /// @param maxTotalRaised_ 新的全局累计募集上限；0 表示暂停全部募资。
    function setMaxTotalRaised(uint256 maxTotalRaised_) external onlyOwnerOrOperator {
        maxTotalRaised = maxTotalRaised_;
        emit MaxTotalRaisedUpdated(maxTotalRaised_, block.timestamp);
    }

    /// @notice 通过显式方法转入原生币并立即转给统一收款地址。
    function depositNative() external payable nonReentrant {
        _depositNative();
    }

    /// @notice 提走意外转入或异常残留在合约中的资产。
    /// @param token 资产地址；address(0) 表示原生币。
    /// @param to 资产接收地址。
    /// @param amount 提取数量。
    function withdraw(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        if (token == address(0)) {
            TransferHelper.safeTransferETH(to, amount);
        } else {
            TransferHelper.safeTransfer(token, to, amount);
        }

        emit Withdrawn(token, to, amount, block.timestamp);
    }

    /// @notice 查询募集地址数量与历史累计募集总额。
    /// @return count 已成功募资的唯一地址数量。
    /// @return totalAmount 历史累计募集原生币总额。
    function getStats() external view returns (uint256 count, uint256 totalAmount) {
        count = depositors.length;
        totalAmount = totalRaised;
    }

    /// @notice 分页查询所有已成功募资的地址。
    /// @param offset 起始下标，从 0 开始。
    /// @param limit 本页最多返回的地址数量。
    /// @return result 当前页的募资地址列表。
    function getDepositorsByRange(uint256 offset, uint256 limit) external view returns (address[] memory result) {
        uint256 total = depositors.length;
        if (offset >= total || limit == 0) {
            return new address[](0);
        }

        uint256 resultLength = total - offset;
        if (resultLength > limit) {
            resultLength = limit;
        }

        result = new address[](resultLength);
        for (uint256 i = 0; i < resultLength; ++i) {
            result[i] = depositors[offset + i];
        }
    }

    /// @dev 校验额度、更新账本并将原生币立即转给收款地址。
    function _depositNative() internal {
        uint256 amount = msg.value;
        if (amount == 0) revert ZeroAmount();

        uint256 maxAmount_ = maxAmount;
        if (maxAmount_ == 0) revert DepositNotAllowed();
        if (amount < minAmount) revert DepositAmountTooSmall();

        uint256 previousAmount = totalDeposited[msg.sender];
        uint256 totalAmount = previousAmount + amount;
        if (totalAmount > maxAmount_) revert DepositLimitExceeded();

        uint256 newTotalRaised = totalRaised + amount;
        if (newTotalRaised > maxTotalRaised) revert TotalRaiseLimitExceeded();

        totalDeposited[msg.sender] = totalAmount;
        if (previousAmount == 0) {
            depositors.push(msg.sender);
        }
        totalRaised = newTotalRaised;

        emit Deposited(msg.sender, amount, totalAmount, receivingAddress, block.timestamp);
        TransferHelper.safeTransferETH(receivingAddress, amount);
    }

    /// @dev UUPS 升级授权钩子，仅 owner 可升级实现。
    function _authorizeUpgrade(address) internal override onlyOwner {}
}
