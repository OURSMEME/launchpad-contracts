// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
/// @dev Test-only stubs for price-source failure and decimal boundaries.
contract CappedPriceSourceStub {
    uint256 public value; uint64 public timestamp;
    function set(uint256 p,uint64 at) external { value=p; timestamp=at; }
    function price(address) external view returns(uint256,uint64) { return(value,timestamp); }
}
contract CappedQuoteRegistryStub {
    address public quote;
    function setQuote(address a) external { quote=a; }
    function quoteAsset(address) external view returns(address) { return quote; }
}
contract CappedDecimalsStub {
    uint8 public immutable decimals;
    constructor(uint8 n) { decimals=n; }
}
