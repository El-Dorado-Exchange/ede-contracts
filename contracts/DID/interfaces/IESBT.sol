// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IESBT {
    function scorePara(uint256 _paraId) external view returns (uint256);

    function createTime(address _account) external view returns (uint256);

    function nickName(address _account) external view returns (string memory);

    function getReferralForAccount(
        address _account
    ) external view returns (address[] memory, address[] memory);

    function userSizeSum(address _account) external view returns (uint256);

    function updateFee(
        address _account,
        uint256 _origFee
    ) external returns (uint256);

    function getESBTAddMpUintetRoles(
        address _mpaddress,
        bytes32 _key
    ) external view returns (uint256[] memory);

    function updateClaimVal(address _account) external;

    function userClaimable(
        address _account
    ) external view returns (uint256, uint256);

    function updateScoreForAccount(
        address _account,
        address /*_vault*/,
        uint256 _amount,
        uint256 _reasonCode
    ) external;

    function updateTradingScoreForAccount(
        address _account,
        address _vault,
        uint256 _amount,
        uint256 _refCode
    ) external;

    function updateSwapScoreForAccount(
        address _account,
        address _vault,
        uint256 _amount
    ) external;

    function updateAddLiqScoreForAccount(
        address _account,
        address _vault,
        uint256 _amount,
        uint256 _refCode
    ) external;

    function getScore(address _account) external view returns (uint256);

    function getRefCode(address _account) external view returns (string memory);

    function accountToDisReb(
        address _account
    ) external view returns (uint256, uint256);

    function rank(address _account) external view returns (uint256);

    function addressToTokenID(address _account) external view returns (uint256);
}
