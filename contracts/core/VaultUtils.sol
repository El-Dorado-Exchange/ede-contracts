// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
// import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IVault.sol";
import "./interfaces/IVaultUtils.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "../utils/EnumerableValues.sol";

contract VaultUtils is IVaultUtils, Ownable {
    using SafeMath for uint256;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using EnumerableValues for EnumerableSet.Bytes32Set;

    struct Position {
        uint256 size;
        uint256 collateral;
        uint256 averagePrice;
        uint256 entryFundingRate;
        uint256 reserveAmount;
        int256 realisedPnl;
        uint256 lastIncreasedTime;
    }

    struct PositionOrig {
        address account;
        address collateralToken;
        address indexToken;
        bool isLong;
    }
    mapping(bytes32 => PositionOrig) public positionsOrig;

    IVault public vault;
    EnumerableSet.Bytes32Set internal positionKeys;

    uint256 public constant BASIS_POINTS_DIVISOR = 10000;
    uint256 public constant FUNDING_RATE_PRECISION = 1000000;

    uint256 public constant PRICE_PRECISION = 10 ** 30;
    uint256 public constant MIN_LEVERAGE = 10000; // 1x
    uint256 public constant USDX_DECIMALS = 18;
    uint256 public constant MAX_FEE_BASIS_POINTS = 500; // 5%
    uint256 public constant MAX_LIQUIDATION_FEE_USD = 100 * PRICE_PRECISION; // 100 USD
    uint256 public constant MIN_FUNDING_RATE_INTERVAL = 1 hours;
    uint256 public constant MAX_FUNDING_RATE_FACTOR = 10000; // 1%

    uint256 public override liquidationFeeUsd;
    uint256 public override taxBasisPoints = 50; // 0.5%
    uint256 public override stableTaxBasisPoints = 20; // 0.2%
    uint256 public override mintBurnFeeBasisPoints = 30; // 0.3%
    uint256 public override swapFeeBasisPoints = 30; // 0.3%
    uint256 public override stableSwapFeeBasisPoints = 4; // 0.04%
    uint256 public override marginFeeBasisPoints = 10; // 0.1%
    uint256 public override minProfitTime;
    bool public override hasDynamicFees = false;

    uint256 public override maxLeverage = 50 * 10000; // 50x

    mapping(uint256 => string) public override errors;

    constructor(IVault _vault) {
        vault = _vault;
    }

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
    ) external override onlyOwner {
        require(_taxBasisPoints <= MAX_FEE_BASIS_POINTS, "3");
        require(_stableTaxBasisPoints <= MAX_FEE_BASIS_POINTS, "ERROR4");
        require(_mintBurnFeeBasisPoints <= MAX_FEE_BASIS_POINTS, "ERROR5");
        require(_swapFeeBasisPoints <= MAX_FEE_BASIS_POINTS, "ERROR6");
        require(_stableSwapFeeBasisPoints <= MAX_FEE_BASIS_POINTS, "ERROR7");
        require(_marginFeeBasisPoints <= MAX_FEE_BASIS_POINTS, "ERROR8");
        require(_liquidationFeeUsd <= MAX_LIQUIDATION_FEE_USD, "ERROR9");
        taxBasisPoints = _taxBasisPoints;
        stableTaxBasisPoints = _stableTaxBasisPoints;
        mintBurnFeeBasisPoints = _mintBurnFeeBasisPoints;
        swapFeeBasisPoints = _swapFeeBasisPoints;
        stableSwapFeeBasisPoints = _stableSwapFeeBasisPoints;
        marginFeeBasisPoints = _marginFeeBasisPoints;
        liquidationFeeUsd = _liquidationFeeUsd;
        minProfitTime = _minProfitTime;
        hasDynamicFees = _hasDynamicFees;
    }

    function setMaxLeverage(uint256 _maxLeverage) external override onlyOwner {
        require(_maxLeverage > MIN_LEVERAGE, "ERROR2");
        maxLeverage = _maxLeverage;
    }

    function addPosition(
        bytes32 _key,
        address _account,
        address _collateralToken,
        address _indexToken,
        bool _isLong
    ) public override {
        require(msg.sender == address(vault), "addPos: only vault");
        if (!positionKeys.contains(_key)) {
            positionKeys.add(_key);
            PositionOrig storage positionOrig = positionsOrig[_key];
            positionOrig.account = _account;
            positionOrig.collateralToken = _collateralToken;
            positionOrig.indexToken = _indexToken;
            positionOrig.isLong = _isLong;
        }
    }

    function removePosition(bytes32 _key) public override {
        require(msg.sender == address(vault), "addPos: only vault");
        if (positionKeys.contains(_key)) positionKeys.remove(_key);
    }

    function updateCumulativeFundingRate(
        address /* _collateralToken */,
        address /* _indexToken */
    ) public pure override returns (bool) {
        return true;
    }

    function validateIncreasePosition(
        address /* _account */,
        address /* _collateralToken */,
        address /* _indexToken */,
        uint256 /* _sizeDelta */,
        bool /* _isLong */
    ) external view override {
        // no additional validations
    }

    function validateDecreasePosition(
        address /* _account */,
        address /* _collateralToken */,
        address /* _indexToken */,
        uint256 /* _collateralDelta */,
        uint256 /* _sizeDelta */,
        bool /* _isLong */,
        address /* _receiver */
    ) external view override {
        // no additional validations
    }

    function getPosition(
        address _account,
        address _collateralToken,
        address _indexToken,
        bool _isLong
    ) internal view returns (Position memory) {
        IVault _vault = vault;
        Position memory position;
        {
            (
                uint256 size,
                uint256 collateral,
                uint256 averagePrice,
                uint256 entryFundingRate /* reserveAmount */ /* realisedPnl */ /* hasProfit */,
                ,
                ,
                ,
                uint256 lastIncreasedTime
            ) = _vault.getPosition(
                    _account,
                    _collateralToken,
                    _indexToken,
                    _isLong
                );
            position.size = size;
            position.collateral = collateral;
            position.averagePrice = averagePrice;
            position.entryFundingRate = entryFundingRate;
            position.lastIncreasedTime = lastIncreasedTime;
        }
        return position;
    }

    function getPositionKey(
        address _account,
        address _collateralToken,
        address _indexToken,
        bool _isLong,
        uint256 _keyID
    ) public pure returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(
                    _account,
                    _collateralToken,
                    _indexToken,
                    _isLong,
                    _keyID
                )
            );
    }

    function getKeyInfo(
        bytes32 _key
    ) public view returns (address, address, address, bool) {
        return (
            positionsOrig[_key].account,
            positionsOrig[_key].collateralToken,
            positionsOrig[_key].indexToken,
            positionsOrig[_key].isLong
        );
    }

    function getLiqPrice(bytes32 _key) public view override returns (uint256) {
        (
            uint256 size,
            uint256 collateral,
            uint256 averagePrice,
            uint256 entryFundingRate,
            ,
            ,
            ,

        ) = vault.getPositionByKey(_key);
        if (size < 1) return size;

        uint256 _fees = getFundingFee(
            positionsOrig[_key].account,
            positionsOrig[_key].collateralToken,
            positionsOrig[_key].indexToken,
            positionsOrig[_key].isLong,
            size,
            entryFundingRate
        );
        _fees = _fees.add(
            getPositionFee(
                positionsOrig[_key].account,
                positionsOrig[_key].collateralToken,
                positionsOrig[_key].indexToken,
                positionsOrig[_key].isLong,
                size
            )
        );
        _fees = _fees.add(liquidationFeeUsd);

        uint256 _maxLevCon = size.mul(BASIS_POINTS_DIVISOR).div(maxLeverage);

        uint256 _tmpDelta = _maxLevCon > _fees ? _maxLevCon : _fees;

        _tmpDelta = averagePrice.mul(collateral.sub(_tmpDelta)).div(size);
        return
            positionsOrig[_key].isLong
                ? averagePrice.sub(_tmpDelta)
                : averagePrice.add(_tmpDelta);
    }

    function getPositionsInfo(
        uint256 _start,
        uint256 _end
    ) public view returns (bytes32[] memory, uint256[] memory, bool[] memory) {
        if (_end > positionKeys.length()) _end = positionKeys.length();
        bytes32[] memory allKeys = positionKeys.valuesAt(_start, _end);

        uint256[] memory liqPrices = new uint256[](allKeys.length);
        bool[] memory isLongs = new bool[](allKeys.length);
        for (uint256 i = 0; i < allKeys.length; i++) {
            liqPrices[i] = getLiqPrice(allKeys[i]);
            isLongs[i] = positionsOrig[allKeys[i]].isLong;
        }
        return (allKeys, liqPrices, isLongs);
    }

    // for longs: nextAveragePrice = (nextPrice * nextSize)/ (nextSize + delta)
    // for shorts: nextAveragePrice = (nextPrice * nextSize) / (nextSize - delta)
    function getNextAveragePrice(
        address _indexToken,
        uint256 _size,
        uint256 _averagePrice,
        bool _isLong,
        uint256 _nextPrice,
        uint256 _sizeDelta,
        uint256 _lastIncreasedTime
    ) public view override returns (uint256) {
        (bool hasProfit, uint256 delta) = vault.getDelta(
            _indexToken,
            _size,
            _averagePrice,
            _isLong,
            _lastIncreasedTime
        );
        uint256 nextSize = _size.add(_sizeDelta);
        uint256 divisor;
        if (_isLong) {
            divisor = hasProfit ? nextSize.add(delta) : nextSize.sub(delta);
        } else {
            divisor = hasProfit ? nextSize.sub(delta) : nextSize.add(delta);
        }
        return _nextPrice.mul(nextSize).div(divisor);
    }

    function validateLiquidationbyKey(
        bytes32 _key,
        bool _raise
    ) public view returns (uint256, uint256) {
        return
            validateLiquidation(
                positionsOrig[_key].account,
                positionsOrig[_key].collateralToken,
                positionsOrig[_key].indexToken,
                positionsOrig[_key].isLong,
                _raise
            );
    }

    function validateLiquidation(
        address _account,
        address _collateralToken,
        address _indexToken,
        bool _isLong,
        bool _raise
    ) public view override returns (uint256, uint256) {
        Position memory position = getPosition(
            _account,
            _collateralToken,
            _indexToken,
            _isLong
        );
        IVault _vault = vault;

        (bool hasProfit, uint256 delta) = _vault.getDelta(
            _indexToken,
            position.size,
            position.averagePrice,
            _isLong,
            position.lastIncreasedTime
        );
        uint256 marginFees = getFundingFee(
            _account,
            _collateralToken,
            _indexToken,
            _isLong,
            position.size,
            position.entryFundingRate
        );

        marginFees = marginFees.add(
            getPositionFee(
                _account,
                _collateralToken,
                _indexToken,
                _isLong,
                position.size
            )
        );

        if (!hasProfit && position.collateral < delta) {
            if (_raise) {
                revert("Vault: losses exceed collateral");
            }
            return (1, marginFees);
        }

        uint256 remainingCollateral = position.collateral;

        if (remainingCollateral < marginFees) {
            if (_raise) {
                revert("Vault: fees exceed collateral");
            }
            // cap the fees to the remainingCollateral
            return (1, remainingCollateral);
        }

        if (!hasProfit) {
            remainingCollateral = position.collateral.sub(delta);
        }

        if (remainingCollateral < marginFees) {
            if (_raise) {
                revert("Vault: fees exceed collateral");
            }
            // cap the fees to the remainingCollateral
            return (1, remainingCollateral);
        }

        if (remainingCollateral < marginFees.add(liquidationFeeUsd)) {
            if (_raise) {
                revert("Vault: liquidation fees exceed collateral");
            }
            return (1, marginFees);
        }

        if (
            remainingCollateral.mul(maxLeverage) <
            position.size.mul(BASIS_POINTS_DIVISOR)
        ) {
            if (_raise) {
                revert("Vault: maxLeverage exceeded");
            }
            return (2, marginFees);
        }

        return (0, marginFees);
    }

    function getEntryFundingRate(
        address _collateralToken,
        address /* _indexToken */,
        bool /* _isLong */
    ) public view override returns (uint256) {
        return vault.cumulativeFundingRates(_collateralToken);
    }

    function getPositionFee(
        address /* _account */,
        address /* _collateralToken */,
        address /* _indexToken */,
        bool /* _isLong */,
        uint256 _sizeDelta
    ) public view override returns (uint256) {
        if (_sizeDelta == 0) {
            return 0;
        }
        uint256 afterFeeUsd = _sizeDelta
            .mul(BASIS_POINTS_DIVISOR.sub(marginFeeBasisPoints))
            .div(BASIS_POINTS_DIVISOR);
        return _sizeDelta.sub(afterFeeUsd);
    }

    function getFundingFee(
        address /* _account */,
        address _collateralToken,
        address /* _indexToken */,
        bool /* _isLong */,
        uint256 _size,
        uint256 _entryFundingRate
    ) public view override returns (uint256) {
        if (_size == 0) {
            return 0;
        }

        uint256 fundingRate = vault
            .cumulativeFundingRates(_collateralToken)
            .sub(_entryFundingRate);
        if (fundingRate == 0) {
            return 0;
        }

        return _size.mul(fundingRate).div(FUNDING_RATE_PRECISION);
    }

    function getBuyUsdxFeeBasisPoints(
        address _token,
        uint256 _usdxAmount
    ) public view override returns (uint256) {
        return
            getFeeBasisPoints(
                _token,
                _usdxAmount,
                mintBurnFeeBasisPoints,
                taxBasisPoints,
                true
            );
    }

    function getSellUsdxFeeBasisPoints(
        address _token,
        uint256 _usdxAmount
    ) public view override returns (uint256) {
        return
            getFeeBasisPoints(
                _token,
                _usdxAmount,
                mintBurnFeeBasisPoints,
                taxBasisPoints,
                false
            );
    }

    function getSwapFeeBasisPoints(
        address _tokenIn,
        address _tokenOut,
        uint256 _usdxAmount
    ) public view override returns (uint256) {
        bool isStableSwap = vault.stableTokens(_tokenIn) &&
            vault.stableTokens(_tokenOut);
        uint256 baseBps = isStableSwap
            ? stableSwapFeeBasisPoints
            : swapFeeBasisPoints;
        uint256 taxBps = isStableSwap ? stableTaxBasisPoints : taxBasisPoints;
        uint256 feesBasisPoints0 = getFeeBasisPoints(
            _tokenIn,
            _usdxAmount,
            baseBps,
            taxBps,
            true
        );
        uint256 feesBasisPoints1 = getFeeBasisPoints(
            _tokenOut,
            _usdxAmount,
            baseBps,
            taxBps,
            false
        );
        // use the higher of the two fee basis points
        return
            feesBasisPoints0 > feesBasisPoints1
                ? feesBasisPoints0
                : feesBasisPoints1;
    }

    // cases to consider
    // 1. initialAmount is far from targetAmount, action increases balance slightly => high rebate
    // 2. initialAmount is far from targetAmount, action increases balance largely => high rebate
    // 3. initialAmount is close to targetAmount, action increases balance slightly => low rebate
    // 4. initialAmount is far from targetAmount, action reduces balance slightly => high tax
    // 5. initialAmount is far from targetAmount, action reduces balance largely => high tax
    // 6. initialAmount is close to targetAmount, action reduces balance largely => low tax
    // 7. initialAmount is above targetAmount, nextAmount is below targetAmount and vice versa
    // 8. a large swap should have similar fees as the same trade split into multiple smaller swaps
    function getFeeBasisPoints(
        address _token,
        uint256 _usdxDelta,
        uint256 _feeBasisPoints,
        uint256 _taxBasisPoints,
        bool _increment
    ) public view override returns (uint256) {
        if (!hasDynamicFees) {
            return _feeBasisPoints;
        }

        uint256 initialAmount = vault.usdxAmounts(_token);
        uint256 nextAmount = initialAmount.add(_usdxDelta);
        if (!_increment) {
            nextAmount = _usdxDelta > initialAmount
                ? 0
                : initialAmount.sub(_usdxDelta);
        }

        uint256 targetAmount = vault.getTargetUsdxAmount(_token);
        if (targetAmount == 0) {
            return _feeBasisPoints;
        }

        uint256 initialDiff = initialAmount > targetAmount
            ? initialAmount.sub(targetAmount)
            : targetAmount.sub(initialAmount);
        uint256 nextDiff = nextAmount > targetAmount
            ? nextAmount.sub(targetAmount)
            : targetAmount.sub(nextAmount);

        // action improves relative asset balance
        if (nextDiff < initialDiff) {
            uint256 rebateBps = _taxBasisPoints.mul(initialDiff).div(
                targetAmount
            );
            return
                rebateBps > _feeBasisPoints
                    ? 0
                    : _feeBasisPoints.sub(rebateBps);
        }

        uint256 averageDiff = initialDiff.add(nextDiff).div(2);
        if (averageDiff > targetAmount) {
            averageDiff = targetAmount;
        }
        uint256 taxBps = _taxBasisPoints.mul(averageDiff).div(targetAmount);
        return _feeBasisPoints.add(taxBps);
    }

    function setErrorContenct(string[] memory _errorInstru) external onlyOwner {
        for (uint16 i = 0; i < _errorInstru.length; i++)
            errors[i] = _errorInstru[i];
    }

    function _validate(bool _condition, uint256 _errorCode) private view {
        require(_condition, errors[_errorCode]);
    }
}
