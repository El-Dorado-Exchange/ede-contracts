// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IDataFeed {
    function getRoundData(uint256 _dataIdx, uint256 _dataPara) external view returns (int256, uint256);

}
