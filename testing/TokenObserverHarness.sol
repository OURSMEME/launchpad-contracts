// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {IOursTokenObserver} from "../interfaces/IOursTokenObserver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
contract TokenObserverHarness is IOursTokenObserver {
    address public immutable token;
    uint256 public immutable mode;
    uint256 public calls;
    constructor(address t, uint256 m) { token=t; mode=m; }
    function onBalanceChange(address, address, uint256) external returns(bytes4) {
        require(msg.sender==token);
        if(mode==1) revert("observer failed");
        if(mode==2) IERC20(token).transfer(address(this),0);
        ++calls;
        return mode==3 ? bytes4(0) : IOursTokenObserver.onBalanceChange.selector;
    }
}
contract TokenObserverFactoryHarness {
    address public immutable registry;
    uint256 public immutable mode;
    mapping(address=>address) public observerOf;
    constructor(address r,uint256 m) { registry=r;mode=m; }
    function requiresTokenObserver() external pure returns(bool) { return true; }
    function validateConfig(address,address,bytes calldata) external pure {}
    function createTokenObserver(address[] calldata) external returns(address) {
        require(observerOf[msg.sender]==address(0));
        address o=address(new TokenObserverHarness(msg.sender,mode));observerOf[msg.sender]=o;return o;
    }
}
