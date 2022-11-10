// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IRewardRouter {
    function getEUSDPoolInfo() external view returns (uint256[] memory);

    function lvt() external view returns (uint256);
}
