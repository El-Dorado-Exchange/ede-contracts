// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IESBT {
    function updateIncreaseLogForAccount(
        address _account,
        address _collateralToken,
        uint256 _collateralSize,
        uint256 _positionSize,
        bool /*_isLong*/
    ) external returns (bool);

    function createTime(address _account) external view returns (uint256);

    function tradingKey(address _account, bytes32 key)
        external
        view
        returns (bytes32);

    function nickName(address _account) external view returns (string memory);

    function getReferralForAccount(address _account)
        external
        view
        returns (address[] memory, address[] memory);

    function userSize(address _account, address _vault)
        external
        view
        returns (uint256);

    function userSizeSum(address _account) external view returns (uint256);

    function updateFeeDiscount(
        address _account,
        uint256 _discount,
        uint256 _rebate
    ) external;

    function getFeeDiscount(address _account) external view returns (uint256);

    function updateFee(address _account, uint256 _origFee)
        external
        returns (uint256);

    function getESBTAddMpUintetRoles(address _mpaddress, bytes32 _key)
        external
        view
        returns (uint256[] memory);

    function updateTradingScoreForAccount(address _account, uint256 _amount)
        external;

    function updateSwapScoreForAccount(address _account, uint256 _amount)
        external;

    function updateAddLiqScoreForAccount(address _account, uint256 _amount)
        external;

    function updateStakeEDEScoreForAccount(address _account, uint256 _amount)
        external;
}
