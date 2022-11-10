// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IELP {
    function updateStakingAmount(address _account, uint256 _amount) external;

    function claimForAccount(address _account) external returns (uint256);

    function claimable(address _account) external view returns (uint256);

    function USDbyFee() external view returns (uint256);

    function TokenFeeReserved(address _token) external view returns (uint256);

    function withdrawToEDEPool() external returns (uint256);
}