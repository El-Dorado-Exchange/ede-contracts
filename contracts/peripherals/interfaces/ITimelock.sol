// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface ITimelock {
    function enableLeverage(address _vault) external;

    function disableLeverage(address _vault) external;

    function setIsLeverageEnabled(
        address _vault,
        bool _isLeverageEnabled
    ) external;

    function signalSetGov(address _target, address _gov) external;

    function signalTransOwner(address _target, address _gov) external;
}
