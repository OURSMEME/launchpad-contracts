// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
interface ISecurityToken {
    function balanceOf(address) external view returns(uint256);
    function approve(address,uint256) external returns(bool);
}
interface ISecurityCurve {
    function buy(uint256,uint256,address) external payable returns(uint256);
    function sell(uint256,uint256,address) external returns(uint256);
}
interface ISecurityFactory { function createGraduatedPool(address) external returns(uint256); }
interface ISecurityTrader {
    struct PoolKey {address currency0;address currency1;uint24 fee;int24 tickSpacing;address hooks;}
    function trade(PoolKey calldata,bool,uint256,uint160) external payable;
}
interface ISecurityBorrower { function onLoan(uint256,bytes calldata) external; }
/// @dev Zero-fee flash liquidity deliberately gives the attacker the strongest repayment terms.
contract SecurityFlashLender {
    receive() external payable {}
    function loan(ISecurityBorrower borrower,uint256 amount,bytes calldata data) external {
        uint256 beforeBalance=address(this).balance;
        (bool ok,)=address(borrower).call{value:amount}("");require(ok);
        borrower.onLoan(amount,data);
        require(address(this).balance>=beforeBalance,"FLASH_NOT_REPAID");
    }
}
contract SecurityRoundTrip is ISecurityBorrower {
    SecurityFlashLender public immutable lender;
    ISecurityCurve public immutable curve;
    ISecurityToken public immutable token;
    ISecurityFactory public immutable factory;
    ISecurityTrader public immutable trader;
    address public immutable hook;
    constructor(SecurityFlashLender l,ISecurityCurve c,ISecurityToken t,ISecurityFactory f,ISecurityTrader r,address h){lender=l;curve=c;token=t;factory=f;trader=r;hook=h;}
    receive() external payable {}
    function attack(uint256 amount,bool migrate) external { lender.loan(this,amount,abi.encode(migrate)); }
    function onLoan(uint256 amount,bytes calldata data) external {
        require(msg.sender==address(lender));_roundTrip(amount,abi.decode(data,(bool)));
        (bool ok,)=address(lender).call{value:address(this).balance}("");require(ok);
    }
    function probe(bool migrate) external payable returns(uint256 recovered) {
        require(address(this).balance==msg.value,"PREEXISTING_BALANCE");
        _roundTrip(msg.value,migrate);recovered=address(this).balance;
        (bool ok,)=msg.sender.call{value:recovered}("");require(ok);
    }
    function _roundTrip(uint256 amount,bool migrate) private {
        curve.buy{value:amount}(amount,0,address(this));
        uint256 tokens=token.balanceOf(address(this));
        if(migrate){
            factory.createGraduatedPool(address(token));
            token.approve(address(trader),tokens);
            trader.trade(ISecurityTrader.PoolKey(address(0),address(token),0,60,hook),false,tokens,1461446703485210103287273052203988822378723970341);
        }else{token.approve(address(curve),tokens);curve.sell(tokens,0,address(this));}
    }
}
