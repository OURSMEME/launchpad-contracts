// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @dev Local fault injection only. Tests replace FeePool runtime while preserving its storage.
contract DistributionFailureHarness {
    address private immutable implementation;
    uint256 private immutable mode;
    constructor(address original, uint256 failureMode) { implementation=original;mode=failureMode; }
    function distribute(address,address,uint64) external view {
        if(mode==1) { assembly { invalid() } }
        if(mode==2) { assembly { revert(0,1048576) } }
        revert("DISTRIBUTION_FAILURE");
    }
    fallback() external payable {
        if(mode==3 && msg.sig==bytes4(keccak256("pendingFees(address,address,uint64)"))) revert("PENDING_READ_FAILURE");
        address target=implementation;
        assembly {
            calldatacopy(0,0,calldatasize())
            let ok := delegatecall(gas(),target,0,calldatasize(),0,0)
            returndatacopy(0,0,returndatasize())
            switch ok case 0 { revert(0,returndatasize()) } default { return(0,returndatasize()) }
        }
    }
}
