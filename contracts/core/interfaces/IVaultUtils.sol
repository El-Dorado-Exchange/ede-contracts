// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IVaultUtils {
    function updateCumulativeFundingRate(
        address _collateralToken,
        address _indexToken
    ) external returns (bool);

    function validateIncreasePosition(
        address _account,
        address _collateralToken,
        address _indexToken,
        uint256 _sizeDelta,
        bool _isLong
    ) external view;

    function validateDecreasePosition(
        address _account,
        address _collateralToken,
        address _indexToken,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong,
        address _receiver
    ) external view;

    function validateLiquidation(
        address _account,
        address _collateralToken,
        address _indexToken,
        bool _isLong,
        bool _raise
    ) external view returns (uint256, uint256);

    function getEntryFundingRate(
        address _collateralToken,
        address _indexToken,
        bool _isLong
    ) external view returns (uint256);

    function getPositionFee(
        address _account,
        address _collateralToken,
        address _indexToken,
        bool _isLong,
        uint256 _sizeDelta
    ) external view returns (uint256);

    function getFundingFee(
        address _account,
        address _collateralToken,
        address _indexToken,
        bool _isLong,
        uint256 _size,
        uint256 _entryFundingRate
    ) external view returns (uint256);

    function getBuyUsdxFeeBasisPoints(address _token, uint256 _usdxAmount)
        external
        view
        returns (uint256);

    function getSellUsdxFeeBasisPoints(address _token, uint256 _usdxAmount)
        external
        view
        returns (uint256);

    function getSwapFeeBasisPoints(
        address _tokenIn,
        address _tokenOut,
        uint256 _usdxAmount
    ) external view returns (uint256);

    function getFeeBasisPoints(
        address _token,
        uint256 _usdxDelta,
        uint256 _feeBasisPoints,
        uint256 _taxBasisPoints,
        bool _increment
    ) external view returns (uint256);

    function BASIS_POINTS_DIVISOR() external view returns (uint256);

    function FUNDING_RATE_PRECISION() external view returns (uint256);

    function PRICE_PRECISION() external view returns (uint256);

    function MIN_LEVERAGE() external view returns (uint256);

    function USDX_DECIMALS() external view returns (uint256);

    function MAX_FEE_BASIS_POINTS() external view returns (uint256);

    function MAX_LIQUIDATION_FEE_USD() external view returns (uint256);

    function MIN_FUNDING_RATE_INTERVAL() external view returns (uint256);

    function MAX_FUNDING_RATE_FACTOR() external view returns (uint256);

    function liquidationFeeUsd() external view returns (uint256);

    function taxBasisPoints() external view returns (uint256);

    function stableTaxBasisPoints() external view returns (uint256);

    function mintBurnFeeBasisPoints() external view returns (uint256);

    function swapFeeBasisPoints() external view returns (uint256);

    function stableSwapFeeBasisPoints() external view returns (uint256);

    function marginFeeBasisPoints() external view returns (uint256);

    function minProfitTime() external view returns (uint256);

    function hasDynamicFees() external view returns (bool);

    function maxLeverage() external view returns (uint256);

    function setMaxLeverage(uint256 _maxLeverage) external;

    function errors(uint256) external view returns (string memory);

    function setFees(
        uint256 _taxBasisPoints,
        uint256 _stableTaxBasisPoints,
        uint256 _mintBurnFeeBasisPoints,
        uint256 _swapFeeBasisPoints,
        uint256 _stableSwapFeeBasisPoints,
        uint256 _marginFeeBasisPoints,
        uint256 _liquidationFeeUsd,
        uint256 _minProfitTime,
        bool _hasDynamicFees
    ) external;
}
