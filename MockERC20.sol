// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract MockERC20 {
    /// @dev 代币名称。
    string public name;
    /// @dev 代币符号。
    string public symbol;
    /// @dev 小数位，测试场景固定为 18。
    uint8 public constant decimals = 18;
    /// @dev 总发行量。
    uint256 public totalSupply;

    /// @dev 账户地址 => 余额。
    mapping(address => uint256) public balanceOf;
    /// @dev owner => spender => 授权额度。
    mapping(address => mapping(address => uint256)) public allowance;

    /// @notice 初始化测试代币的名称和符号。
    constructor(string memory name_, string memory symbol_) {
        name = name_;
        symbol = symbol_;
    }

    /// @notice 增发测试代币。
    /// @param to 接收地址。
    /// @param amount 增发数量。
    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    /// @notice 授权 spender 使用当前账户的代币。
    /// @param spender 被授权地址。
    /// @param amount 授权额度。
    /// @return 是否成功。
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /// @notice 从当前账户向目标地址转账。
    /// @param to 接收地址。
    /// @param amount 转账数量。
    /// @return 是否成功。
    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    /// @notice 使用授权额度从 from 向 to 转账。
    /// @param from 扣款地址。
    /// @param to 收款地址。
    /// @param amount 转账数量。
    /// @return 是否成功。
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 currentAllowance = allowance[from][msg.sender];
        require(currentAllowance >= amount, "ERC20: insufficient allowance");
        unchecked {
            allowance[from][msg.sender] = currentAllowance - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    /// @dev 内部转账逻辑。
    /// @param from 扣款地址。
    /// @param to 收款地址。
    /// @param amount 转账数量。
    function _transfer(address from, address to, uint256 amount) internal {
        require(to != address(0), "ERC20: transfer to zero");
        uint256 balance = balanceOf[from];
        require(balance >= amount, "ERC20: insufficient balance");
        unchecked {
            balanceOf[from] = balance - amount;
        }
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}
