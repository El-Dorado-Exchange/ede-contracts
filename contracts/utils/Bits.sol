// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.0;

library Bits {
    // uint256(~0) is 256 bits of 1s
    // shift the 1s by (256 - 16) to get (256 - 16) 0s followed by 16 1s
    uint256 public constant BITMASK_16 = ~uint256(0) >> (256 - 16);
    // shift the 1s by (256 - 32) to get (256 - 32) 0s followed by 32 1s
    uint256 public constant BITMASK_32 = ~uint256(0) >> (256 - 32);
    // shift the 1s by (256 - 64) to get (256 - 64) 0s followed by 64 1s
    uint256 public constant BITMASK_64 = ~uint256(0) >> (256 - 64);
}