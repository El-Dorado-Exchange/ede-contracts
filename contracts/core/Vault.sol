// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../tokens/interfaces/IUSDX.sol";
import "./interfaces/IVault.sol";
import "./interfaces/IVaultUtils.sol";
import "./interfaces/IVaultPriceFeedV2.sol";
import "../DID/interfaces/IESBT.sol";

contract Vault is ReentrancyGuard, IVault, Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    struct Position {
        uint256 size;
        uint256 collateral;
        uint256 averagePrice;
        uint256 entryFundingRate;
        uint256 reserveAmount;
        int256 realisedPnl;
        uint256 lastIncreasedTime;
    }

    bool public override isInitialized;
    bool public override isSwapEnabled = true;
    bool public override isLeverageEnabled = true;

    address public override vaultUtilsAddress;
    IVaultUtils public vaultUtils;
    IESBT public eSBT;

    address public override router;
    address public override priceFeed;

    address public override usdx;

    uint256 public override whitelistedTokenCount;

    uint256 public override fundingInterval = 8 hours;
    uint256 public override fundingRateFactor;
    uint256 public override stableFundingRateFactor;
    uint256 public override totalTokenWeights;

    bool public override inManagerMode = false;
    bool public override inPrivateLiquidationMode = true;

    mapping(address => mapping(address => bool))
        public
        override approvedRouters;
    mapping(address => bool) public override isLiquidator;
    mapping(address => bool) public override isManager;

    address[] public override allWhitelistedTokens;

    mapping(address => bool) public override whitelistedTokens;
    mapping(address => uint256) public override tokenDecimals;
    mapping(address => uint256) public override minProfitBasisPoints;
    mapping(address => bool) public override stableTokens;
    mapping(address => bool) public override shortableTokens;

    // tokenBalances is used only to determine _transferIn values
    mapping(address => uint256) public override tokenBalances;

    // tokenWeights allows customisation of index composition
    mapping(address => uint256) public override tokenWeights;

    // usdxAmounts tracks the amount of USDX debt for each whitelisted token
    mapping(address => uint256) public override usdxAmounts;
    uint256 public override usdxSupply;

    // maxUSDAmounts allows setting a max amount of USDX debt for a token
    mapping(address => uint256) public override maxUSDAmounts;
    // poolAmounts tracks the number of received tokens that can be used for leverage
    // this is tracked separately from tokenBalances to exclude funds that are deposited as margin collateral
    mapping(address => uint256) public override poolAmounts;
    // reservedAmounts tracks the number of tokens reserved for open leverage positions
    mapping(address => uint256) public override reservedAmounts;
    // bufferAmounts allows specification of an amount to exclude from swaps
    // this can be used to ensure a certain amount of liquidity is available for leverage positions
    mapping(address => uint256) public override bufferAmounts;
    // guaranteedUsd tracks the amount of USD that is "guaranteed" by opened leverage positions
    mapping(address => uint256) public override guaranteedUsd;
    // cumulativeFundingRates tracks the funding rates based on utilization
    mapping(address => uint256) public override cumulativeFundingRates;
    // lastFundingTimes tracks the last time funding was updated for a token
    mapping(address => uint256) public override lastFundingTimes;

    // positions tracks all open positions
    mapping(bytes32 => Position) public positions;

    // feeReserves tracks the amount of fees per token
    mapping(address => uint256) public override feeReserves;
    mapping(address => uint256) public override feeSold;
    uint256 public override feeReservesUSD;
    uint256 public override feeReservesDiscountedUSD;

    mapping(uint256 => uint256) public override feeReservesRecord;
    uint256 public override feeClaimedUSD;

    mapping(address => uint256) public override globalShortSizes;
    mapping(address => uint256) public override globalShortAveragePrices;
    mapping(address => uint256) public override maxGlobalShortSizes;

    event ZeroOut(bytes32 key, address account, uint256 size);

    event Swap(
        address account,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 amountOutAfterFees,
        uint256 feeBasisPoints
    );

    event IncreasePosition(
        bytes32 key,
        address account,
        address collateralToken,
        address indexToken,
        uint256 collateralDelta,
        uint256 sizeDelta,
        bool isLong,
        uint256 price,
        uint256 fee
    );
    event DecreasePosition(
        bytes32 key,
        address account,
        address collateralToken,
        address indexToken,
        uint256 collateralDelta,
        uint256 sizeDelta,
        bool isLong,
        uint256 price,
        uint256 fee,
        uint256 usdOut,
        uint256 latestCollatral,
        uint256 prevCollateral
    );
    event DecreasePositionTransOut(bytes32 key, uint256 transOut);
    event LiquidatePosition(
        bytes32 key,
        address account,
        address collateralToken,
        address indexToken,
        bool isLong,
        uint256 size,
        uint256 collateral,
        uint256 reserveAmount,
        int256 realisedPnl,
        uint256 markPrice
    );
    event UpdatePosition(
        bytes32 key,
        address account,
        uint256 size,
        uint256 collateral,
        uint256 averagePrice,
        uint256 entryFundingRate,
        uint256 reserveAmount,
        int256 realisedPnl,
        uint256 markPrice
    );
    event ClosePosition(
        bytes32 key,
        address account,
        uint256 size,
        uint256 collateral,
        uint256 averagePrice,
        uint256 entryFundingRate,
        uint256 reserveAmount,
        int256 realisedPnl
    );

    event UpdateFundingRate(address token, uint256 fundingRate);
    event UpdatePnl(
        bytes32 key,
        bool hasProfit,
        uint256 delta,
        uint256 currentSize,
        uint256 currentCollateral,
        uint256 usdOut,
        uint256 usdOutAfterFee
    );
    event CollectSwapFees(address token, uint256 feeUsd, uint256 feeTokens);
    event CollectMarginFees(address token, uint256 feeUsd, uint256 feeTokens);

    event DirectPoolDeposit(address token, uint256 amount);
    event IncreasePoolAmount(address token, uint256 amount);
    event DecreasePoolAmount(address token, uint256 amount);
    event IncreaseReservedAmount(address token, uint256 amount);
    event DecreaseReservedAmount(address token, uint256 amount);
    event IncreaseGuaranteedUsd(address token, uint256 amount);
    event DecreaseGuaranteedUsd(address token, uint256 amount);

    // once the parameters are verified to be working correctly,
    // gov should be set to a timelock contract or a governance contract

    function initialize(
        address _router,
        address _usdx,
        address _priceFeed,
        uint256 /*_liquidationFeeUsd*/,
        uint256 _fundingRateFactor,
        uint256 _stableFundingRateFactor
    ) external onlyOwner {
        require(!isInitialized, "Err1");
        isInitialized = true;
        router = _router;
        usdx = _usdx;
        tokenDecimals[usdx] = 18;
        priceFeed = _priceFeed;
        fundingRateFactor = _fundingRateFactor;
        stableFundingRateFactor = _stableFundingRateFactor;
    }

    function setVaultUtils(address _vaultUtils) external override onlyOwner {
        vaultUtils = IVaultUtils(_vaultUtils);
        vaultUtilsAddress = _vaultUtils;
    }

    function setESBT(address _eSBT) external override onlyOwner {
        eSBT = IESBT(_eSBT);
    }

    function allWhitelistedTokensLength()
        external
        view
        override
        returns (uint256)
    {
        return allWhitelistedTokens.length;
    }

    function setInManagerMode(bool _inManagerMode) external override onlyOwner {
        inManagerMode = _inManagerMode;
    }

    function setManager(
        address _manager,
        bool _isManager
    ) external override onlyOwner {
        isManager[_manager] = _isManager;
    }

    function setInPrivateLiquidationMode(
        bool _inPrivateLiquidationMode
    ) external override onlyOwner {
        inPrivateLiquidationMode = _inPrivateLiquidationMode;
    }

    function setLiquidator(
        address _liquidator,
        bool _isActive
    ) external override onlyOwner {
        isLiquidator[_liquidator] = _isActive;
    }

    function setIsSwapEnabled(bool _isSwapEnabled) external override onlyOwner {
        isSwapEnabled = _isSwapEnabled;
    }

    function setIsLeverageEnabled(
        bool _isLeverageEnabled
    ) external override onlyOwner {
        isLeverageEnabled = _isLeverageEnabled;
    }

    function setPriceFeed(address _priceFeed) external override onlyOwner {
        priceFeed = _priceFeed;
    }

    function setRouter(address _router) external override onlyOwner {
        router = _router;
    }

    function setBufferAmount(
        address _token,
        uint256 _amount
    ) external override onlyOwner {
        bufferAmounts[_token] = _amount;
    }

    function setMaxGlobalShortSize(
        address _token,
        uint256 _amount
    ) external override onlyOwner {
        maxGlobalShortSizes[_token] = _amount;
    }

    function setFundingRate(
        uint256 _fundingInterval,
        uint256 _fundingRateFactor,
        uint256 _stableFundingRateFactor
    ) external override onlyOwner {
        _validate(
            _fundingInterval >= vaultUtils.MIN_FUNDING_RATE_INTERVAL(),
            10
        );
        _validate(
            _fundingRateFactor <= vaultUtils.MAX_FUNDING_RATE_FACTOR(),
            11
        );
        _validate(
            _stableFundingRateFactor <= vaultUtils.MAX_FUNDING_RATE_FACTOR(),
            12
        );
        fundingInterval = _fundingInterval;
        fundingRateFactor = _fundingRateFactor;
        stableFundingRateFactor = _stableFundingRateFactor;
    }

    function setTokenConfig(
        address _token,
        uint256 _tokenDecimals,
        uint256 _tokenWeight,
        uint256 _minProfitBps,
        uint256 _maxUSDAmount,
        bool _isStable,
        bool _isShortable
    ) external override onlyOwner {
        // increment token count for the first time
        if (!whitelistedTokens[_token]) {
            whitelistedTokenCount = whitelistedTokenCount.add(1);
            allWhitelistedTokens.push(_token);
        }

        uint256 _totalTokenWeights = totalTokenWeights;
        _totalTokenWeights = _totalTokenWeights.sub(tokenWeights[_token]);

        whitelistedTokens[_token] = true;
        tokenDecimals[_token] = _tokenDecimals;
        tokenWeights[_token] = _tokenWeight;
        minProfitBasisPoints[_token] = _minProfitBps;
        maxUSDAmounts[_token] = _maxUSDAmount;
        stableTokens[_token] = _isStable;
        shortableTokens[_token] = _isShortable;

        totalTokenWeights = _totalTokenWeights.add(_tokenWeight);

        // validate price feed
        getMaxPrice(_token);
    }

    function clearTokenConfig(address _token) external onlyOwner {
        _validate(whitelistedTokens[_token], 13);
        totalTokenWeights = totalTokenWeights.sub(tokenWeights[_token]);
        delete whitelistedTokens[_token];
        delete tokenDecimals[_token];
        delete tokenWeights[_token];
        delete minProfitBasisPoints[_token];
        delete maxUSDAmounts[_token];
        delete stableTokens[_token];
        delete shortableTokens[_token];
        whitelistedTokenCount = whitelistedTokenCount.sub(1);
    }

    function addRouter(address _router) external {
        approvedRouters[msg.sender][_router] = true;
    }

    function removeRouter(address _router) external {
        approvedRouters[msg.sender][_router] = false;
    }

    function setUsdxAmount(
        address _token,
        uint256 _amount
    ) external override onlyOwner {
        uint256 usdxAmount = usdxAmounts[_token];
        if (_amount > usdxAmount) {
            _increaseUsdxAmount(_token, _amount.sub(usdxAmount));
            return;
        }
        _decreaseUsdxAmount(_token, usdxAmount.sub(_amount));
    }

    // the governance controlling this function should have a timelock
    function upgradeVault(
        address _newVault,
        address _token,
        uint256 _amount
    ) external onlyOwner {
        IERC20(_token).safeTransfer(_newVault, _amount);
    }

    // deposit into the pool without minting USDX tokens
    // useful in allowing the pool to become over-collaterised
    function directPoolDeposit(address _token) external override nonReentrant {
        _validate(whitelistedTokens[_token], 14);
        uint256 tokenAmount = _transferIn(_token);
        _validate(tokenAmount > 0, 15);
        _increasePoolAmount(_token, tokenAmount);
        emit DirectPoolDeposit(_token, tokenAmount);
    }

    function buyUSDX(
        address _token,
        address _receiver
    ) external override nonReentrant returns (uint256) {
        _validate(isManager[msg.sender], 54);
        _validate(whitelistedTokens[_token], 16);

        uint256 tokenAmount = _transferIn(_token);
        _validate(tokenAmount > 0, 17);

        updateCumulativeFundingRate(_token, _token);

        uint256 price = getMinPrice(_token);

        uint256 usdxAmount = tokenAmount.mul(price).div(
            vaultUtils.PRICE_PRECISION()
        );
        usdxAmount = adjustForDecimals(usdxAmount, _token, usdx);
        _validate(usdxAmount > 0, 18);
        uint256 feeBasisPoints = vaultUtils.getBuyUsdxFeeBasisPoints(
            _token,
            usdxAmount
        );
        uint256 amountAfterFees = _collectSwapFees(
            _token,
            tokenAmount,
            feeBasisPoints
        );
        uint256 mintAmount = amountAfterFees.mul(price).div(
            vaultUtils.PRICE_PRECISION()
        );
        mintAmount = adjustForDecimals(mintAmount, _token, usdx);
        _increaseUsdxAmount(_token, mintAmount);
        _increasePoolAmount(_token, amountAfterFees);
        usdxSupply = usdxSupply.add(mintAmount);
        _increaseUsdxAmount(_receiver, mintAmount);

        return mintAmount;
    }

    function sellUSDX(
        address _token,
        address _receiver,
        uint256 _usdxAmount
    ) external override nonReentrant returns (uint256) {
        _validate(isManager[msg.sender], 54);
        _validate(whitelistedTokens[_token], 19);
        require(usdxAmounts[msg.sender] > _usdxAmount, "insufficient usd");

        uint256 usdxAmount = _usdxAmount; // _transferIn(usdx);
        _validate(usdxAmount > 0, 20);

        updateCumulativeFundingRate(_token, _token);

        uint256 redemptionAmount = getRedemptionAmount(_token, usdxAmount);
        _validate(redemptionAmount > 0, 21);

        _decreaseUsdxAmount(_token, usdxAmount);
        _decreasePoolAmount(_token, redemptionAmount);

        usdxSupply = usdxSupply > usdxAmount ? usdxSupply.sub(usdxAmount) : 0;

        usdxAmounts[msg.sender] = usdxAmounts[msg.sender] > _usdxAmount
            ? usdxAmounts[msg.sender].sub(_usdxAmount)
            : 0;
        uint256 feeBasisPoints = vaultUtils.getSellUsdxFeeBasisPoints(
            _token,
            usdxAmount
        );
        uint256 amountOut = _collectSwapFees(
            _token,
            redemptionAmount,
            feeBasisPoints
        );
        _validate(amountOut > 0, 22);
        _transferOut(_token, amountOut, _receiver);
        return amountOut;
    }

    function claimFeeToken(
        address _token
    ) external override nonReentrant returns (uint256) {
        _validate(isManager[msg.sender], 54);
        if (!whitelistedTokens[_token]) {
            return 0;
        }
        _validate(whitelistedTokens[_token], 19);
        require(feeReserves[_token] >= feeSold[_token], "insufficient Fee");
        uint256 _amount = feeReserves[_token].sub(feeSold[_token]);
        feeSold[_token] = feeReserves[_token];
        if (_amount > 0) {
            _transferOut(_token, _amount, msg.sender);
        }
        return _amount;
    }

    function swap(
        address _tokenIn,
        address _tokenOut,
        address _receiver
    ) external override nonReentrant returns (uint256) {
        _validate(isSwapEnabled, 23);
        _validate(whitelistedTokens[_tokenIn], 24);
        _validate(whitelistedTokens[_tokenOut], 25);
        _validate(_tokenIn != _tokenOut, 26);

        updateCumulativeFundingRate(_tokenIn, _tokenIn);
        updateCumulativeFundingRate(_tokenOut, _tokenOut);

        uint256 amountIn = _transferIn(_tokenIn);
        _validate(amountIn > 0, 27);

        uint256 priceIn = getMinPrice(_tokenIn);
        uint256 priceOut = getMaxPrice(_tokenOut);

        uint256 amountOut = amountIn.mul(priceIn).div(priceOut);
        amountOut = adjustForDecimals(amountOut, _tokenIn, _tokenOut);

        // adjust usdxAmounts by the same usdxAmount as debt is shifted between the assets
        uint256 usdxAmount = amountIn.mul(priceIn).div(
            vaultUtils.PRICE_PRECISION()
        );
        usdxAmount = adjustForDecimals(usdxAmount, _tokenIn, usdx);

        uint256 feeBasisPoints = vaultUtils.getSwapFeeBasisPoints(
            _tokenIn,
            _tokenOut,
            usdxAmount
        );
        uint256 amountOutAfterFees = _collectSwapFees(
            _tokenOut,
            amountOut,
            feeBasisPoints
        );

        _increaseUsdxAmount(_tokenIn, usdxAmount);
        _decreaseUsdxAmount(_tokenOut, usdxAmount);

        _increasePoolAmount(_tokenIn, amountIn);
        _decreasePoolAmount(_tokenOut, amountOut);

        _validateBufferAmount(_tokenOut);

        _transferOut(_tokenOut, amountOutAfterFees, _receiver);

        emit Swap(
            _receiver,
            _tokenIn,
            _tokenOut,
            amountIn,
            amountOut,
            amountOutAfterFees,
            feeBasisPoints
        );

        return amountOutAfterFees;
    }

    function increasePosition(
        address _account,
        address _collateralToken,
        address _indexToken,
        uint256 _sizeDelta,
        bool _isLong
    ) external override nonReentrant {
        _validate(isLeverageEnabled, 28);
        _validateRouter(_account);
        _validateTokens(_collateralToken, _indexToken, _isLong);
        vaultUtils.validateIncreasePosition(
            _account,
            _collateralToken,
            _indexToken,
            _sizeDelta,
            _isLong
        );
        updateCumulativeFundingRate(_collateralToken, _indexToken);

        bytes32 key = vaultUtils.getPositionKey(
            _account,
            _collateralToken,
            _indexToken,
            _isLong,
            0
        );
        Position storage position = positions[key];
        vaultUtils.addPosition(
            key,
            _account,
            _collateralToken,
            _indexToken,
            _isLong
        );
        uint256 price = _isLong
            ? getMaxPrice(_indexToken)
            : getMinPrice(_indexToken);

        if (position.size == 0) {
            position.averagePrice = price;
        }

        if (position.size > 0 && _sizeDelta > 0) {
            position.averagePrice = vaultUtils.getNextAveragePrice(
                _indexToken,
                position.size,
                position.averagePrice,
                _isLong,
                price,
                _sizeDelta,
                position.lastIncreasedTime
            );
        }

        uint256 fee = _collectMarginFees(
            _account,
            _collateralToken,
            _indexToken,
            _isLong,
            _sizeDelta,
            position.size,
            position.entryFundingRate
        );
        uint256 collateralDelta = _transferIn(_collateralToken);

        uint256 collateralDeltaUsd = tokenToUsdMin(
            _collateralToken,
            collateralDelta
        );

        position.collateral = position.collateral.add(collateralDeltaUsd);

        _validate(position.collateral >= fee, 29);

        position.collateral = position.collateral.sub(fee);
        position.entryFundingRate = vaultUtils.getEntryFundingRate(
            _collateralToken,
            _indexToken,
            _isLong
        );
        position.size = position.size.add(_sizeDelta);
        position.lastIncreasedTime = block.timestamp;

        _validate(position.size > 0, 30);
        _validatePosition(position.size, position.collateral);
        vaultUtils.validateLiquidation(
            _account,
            _collateralToken,
            _indexToken,
            _isLong,
            true
        );

        // reserve tokens to pay profits on the position
        uint256 reserveDelta = usdToTokenMax(_collateralToken, _sizeDelta);
        position.reserveAmount = position.reserveAmount.add(reserveDelta);
        _increaseReservedAmount(_collateralToken, reserveDelta);

        if (_isLong) {
            // guaranteedUsd stores the sum of (position.size - position.collateral) for all positions
            // if a fee is charged on the collateral then guaranteedUsd should be increased by that fee amount
            // since (position.size - position.collateral) would have increased by `fee`
            _increaseGuaranteedUsd(_collateralToken, _sizeDelta.add(fee));
            _decreaseGuaranteedUsd(_collateralToken, collateralDeltaUsd);
            // treat the deposited collateral as part of the pool
            _increasePoolAmount(_collateralToken, collateralDelta);
            // fees need to be deducted from the pool since fees are deducted from position.collateral
            // and collateral is treated as part of the pool
            _decreasePoolAmount(
                _collateralToken,
                usdToTokenMin(_collateralToken, fee)
            );
        } else {
            if (globalShortSizes[_indexToken] == 0) {
                globalShortAveragePrices[_indexToken] = price;
            } else {
                globalShortAveragePrices[
                    _indexToken
                ] = getNextGlobalShortAveragePrice(
                    _indexToken,
                    price,
                    _sizeDelta
                );
            }

            _increaseGlobalShortSize(_indexToken, _sizeDelta);
        }

        emit IncreasePosition(
            key,
            _account,
            _collateralToken,
            _indexToken,
            collateralDeltaUsd,
            _sizeDelta,
            _isLong,
            price,
            fee
        );
        emit UpdatePosition(
            key,
            _account,
            position.size,
            position.collateral,
            position.averagePrice,
            position.entryFundingRate,
            position.reserveAmount,
            position.realisedPnl,
            price
        );
    }

    function decreasePosition(
        address _account,
        address _collateralToken,
        address _indexToken,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong,
        address _receiver
    ) external override nonReentrant returns (uint256) {
        _validateRouter(_account);
        return
            _decreasePosition(
                _account,
                _collateralToken,
                _indexToken,
                _collateralDelta,
                _sizeDelta,
                _isLong,
                _receiver
            );
    }

    function _decreasePosition(
        address _account,
        address _collateralToken,
        address _indexToken,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong,
        address _receiver
    ) private returns (uint256) {
        vaultUtils.validateDecreasePosition(
            _account,
            _collateralToken,
            _indexToken,
            _collateralDelta,
            _sizeDelta,
            _isLong,
            _receiver
        );
        updateCumulativeFundingRate(_collateralToken, _indexToken);
        bytes32 key = vaultUtils.getPositionKey(
            _account,
            _collateralToken,
            _indexToken,
            _isLong,
            0
        );
        Position storage position = positions[key];
        _validate(position.size > 0, 31);
        _validate(position.size >= _sizeDelta, 32);
        _validate(position.collateral >= _collateralDelta, 33);

        uint256 collateral = position.collateral;
        // scrop variables to avoid stack too deep errors
        {
            uint256 reserveDelta = position.reserveAmount.mul(_sizeDelta).div(
                position.size
            );
            position.reserveAmount = position.reserveAmount.sub(reserveDelta);
            _decreaseReservedAmount(_collateralToken, reserveDelta);
        }

        (uint256 usdOut, uint256 usdOutAfterFee) = _reduceCollateral(
            _account,
            _collateralToken,
            _indexToken,
            _collateralDelta,
            _sizeDelta,
            _isLong
        );

        // scrop variables to avoid stack too deep errors
        {
            uint256 price = _isLong
                ? getMinPrice(_indexToken)
                : getMaxPrice(_indexToken);
            emit DecreasePosition(
                key,
                _account,
                _collateralToken,
                _indexToken,
                _collateralDelta,
                _sizeDelta,
                _isLong,
                price,
                usdOut.sub(usdOutAfterFee),
                usdOut,
                position.collateral,
                collateral
            );
            if (position.size != _sizeDelta) {
                position.entryFundingRate = vaultUtils.getEntryFundingRate(
                    _collateralToken,
                    _indexToken,
                    _isLong
                );
                position.size = position.size.sub(_sizeDelta);
                _validatePosition(position.size, position.collateral);
                vaultUtils.validateLiquidation(
                    _account,
                    _collateralToken,
                    _indexToken,
                    _isLong,
                    true
                );
                if (_isLong) {
                    _increaseGuaranteedUsd(
                        _collateralToken,
                        collateral.sub(position.collateral)
                    );
                    _decreaseGuaranteedUsd(_collateralToken, _sizeDelta);
                }
                emit UpdatePosition(
                    key,
                    _account,
                    position.size,
                    position.collateral,
                    position.averagePrice,
                    position.entryFundingRate,
                    position.reserveAmount,
                    position.realisedPnl,
                    price
                );
            } else {
                if (_isLong) {
                    _increaseGuaranteedUsd(_collateralToken, collateral);
                    _decreaseGuaranteedUsd(_collateralToken, _sizeDelta);
                }
                emit ClosePosition(
                    key,
                    _account,
                    position.size,
                    position.collateral,
                    position.averagePrice,
                    position.entryFundingRate,
                    position.reserveAmount,
                    position.realisedPnl
                );

                delete positions[key];
                vaultUtils.removePosition(key);
            }
        }

        if (!_isLong) {
            _decreaseGlobalShortSize(_indexToken, _sizeDelta);
        }

        if (usdOut > 0) {
            uint256 amountOutAfterFees = 0;
            if (_isLong) {
                _decreasePoolAmount(
                    _collateralToken,
                    usdToTokenMin(_collateralToken, usdOut)
                );
            }
            amountOutAfterFees = usdToTokenMin(
                _collateralToken,
                usdOutAfterFee
            );
            emit DecreasePositionTransOut(key, amountOutAfterFees);
            _transferOut(_collateralToken, amountOutAfterFees, _receiver);
            return amountOutAfterFees;
        } else {
            emit ZeroOut(key, _receiver, _sizeDelta);
        }

        return 0;
    }

    function claimFeeReserves() external override returns (uint256) {
        _validate(isManager[msg.sender], 54);
        uint256 feeToClaim = feeReservesUSD.sub(feeReservesDiscountedUSD).sub(
            feeClaimedUSD
        );
        feeClaimedUSD = feeReservesUSD.sub(feeReservesDiscountedUSD);
        return feeToClaim;
    }

    function claimableFeeReserves() external view override returns (uint256) {
        return feeReservesUSD.sub(feeReservesDiscountedUSD).sub(feeClaimedUSD);
    }

    function liquidatePosition(
        address _account,
        address _collateralToken,
        address _indexToken,
        bool _isLong,
        address _feeReceiver
    ) external override nonReentrant {
        if (inPrivateLiquidationMode) {
            _validate(isLiquidator[msg.sender], 34);
        }
        updateCumulativeFundingRate(_collateralToken, _indexToken);

        bytes32 key = vaultUtils.getPositionKey(
            _account,
            _collateralToken,
            _indexToken,
            _isLong,
            0
        );
        Position memory position = positions[key];
        _validate(position.size > 0, 35);

        (uint256 liquidationState, uint256 marginFees) = vaultUtils
            .validateLiquidation(
                _account,
                _collateralToken,
                _indexToken,
                _isLong,
                false
            );
        _validate(liquidationState != 0, 36);
        if (liquidationState == 2) {
            // max leverage exceeded but there is collateral remaining after deducting losses so decreasePosition instead
            _decreasePosition(
                _account,
                _collateralToken,
                _indexToken,
                0,
                position.size,
                _isLong,
                _account
            );
            return;
        }

        uint256 feeTokens = usdToTokenMin(_collateralToken, marginFees);
        feeReserves[_collateralToken] = feeReserves[_collateralToken].add(
            feeTokens
        );
        feeReservesUSD = feeReservesUSD.add(marginFees);
        uint256 _discFee = eSBT.updateFee(_account, marginFees);
        feeReservesDiscountedUSD = feeReservesDiscountedUSD.add(_discFee);

        uint256 _tIndex = block.timestamp.div(24 hours);
        feeReservesRecord[_tIndex] = feeReservesRecord[_tIndex].add(marginFees);
        emit CollectMarginFees(_collateralToken, marginFees, feeTokens);

        _decreaseReservedAmount(_collateralToken, position.reserveAmount);
        if (_isLong) {
            _decreaseGuaranteedUsd(
                _collateralToken,
                position.size.sub(position.collateral)
            );
            _decreasePoolAmount(
                _collateralToken,
                usdToTokenMin(_collateralToken, marginFees)
            );
        }

        uint256 markPrice = _isLong
            ? getMinPrice(_indexToken)
            : getMaxPrice(_indexToken);
        emit LiquidatePosition(
            key,
            _account,
            _collateralToken,
            _indexToken,
            _isLong,
            position.size,
            position.collateral,
            position.reserveAmount,
            position.realisedPnl,
            markPrice
        );

        if (!_isLong && marginFees < position.collateral) {
            uint256 remainingCollateral = position.collateral.sub(marginFees);
            _increasePoolAmount(
                _collateralToken,
                usdToTokenMin(_collateralToken, remainingCollateral)
            );
        }

        if (!_isLong) {
            _decreaseGlobalShortSize(_indexToken, position.size);
        }

        delete positions[key];
        vaultUtils.removePosition(key);

        // pay the fee receiver using the pool, we assume that in general the liquidated amount should be sufficient to cover
        // the liquidation fees
        _decreasePoolAmount(
            _collateralToken,
            usdToTokenMin(_collateralToken, vaultUtils.liquidationFeeUsd())
        );
        _transferOut(
            _collateralToken,
            usdToTokenMin(_collateralToken, vaultUtils.liquidationFeeUsd()),
            _feeReceiver
        );
    }

    function getMaxPrice(
        address _token
    ) public view override returns (uint256) {
        return
            IVaultPriceFeedV2(priceFeed).getPrice(_token, true, false, false);
    }

    function getMinPrice(
        address _token
    ) public view override returns (uint256) {
        return
            IVaultPriceFeedV2(priceFeed).getPrice(_token, false, false, false);
    }

    function getRedemptionAmount(
        address _token,
        uint256 _usdxAmount
    ) public view override returns (uint256) {
        uint256 price = getMaxPrice(_token);
        uint256 redemptionAmount = _usdxAmount
            .mul(vaultUtils.PRICE_PRECISION())
            .div(price);
        return adjustForDecimals(redemptionAmount, usdx, _token);
    }

    function getRedemptionCollateral(
        address _token
    ) public view returns (uint256) {
        if (stableTokens[_token]) {
            return poolAmounts[_token];
        }
        uint256 collateral = usdToTokenMin(_token, guaranteedUsd[_token]);
        return collateral.add(poolAmounts[_token]).sub(reservedAmounts[_token]);
    }

    function getRedemptionCollateralUsd(
        address _token
    ) public view returns (uint256) {
        return tokenToUsdMin(_token, getRedemptionCollateral(_token));
    }

    function adjustForDecimals(
        uint256 _amount,
        address _tokenDiv,
        address _tokenMul
    ) public view returns (uint256) {
        return
            _amount.mul(10 ** tokenDecimals[_tokenMul]).div(
                10 ** tokenDecimals[_tokenDiv]
            );
    }

    function tokenToUsdMin(
        address _token,
        uint256 _tokenAmount
    ) public view override returns (uint256) {
        if (_tokenAmount == 0) {
            return 0;
        }
        uint256 price = getMinPrice(_token);
        uint256 decimals = tokenDecimals[_token];
        return _tokenAmount.mul(price).div(10 ** decimals);
    }

    function usdToTokenMax(
        address _token,
        uint256 _usdAmount
    ) public view override returns (uint256) {
        if (_usdAmount == 0) {
            return 0;
        }
        return usdToToken(_token, _usdAmount, getMinPrice(_token));
    }

    function usdToTokenMin(
        address _token,
        uint256 _usdAmount
    ) public view override returns (uint256) {
        if (_usdAmount == 0) {
            return 0;
        }
        return usdToToken(_token, _usdAmount, getMaxPrice(_token));
    }

    function usdToToken(
        address _token,
        uint256 _usdAmount,
        uint256 _price
    ) public view returns (uint256) {
        if (_usdAmount == 0) {
            return 0;
        }
        uint256 decimals = tokenDecimals[_token];
        return _usdAmount.mul(10 ** decimals).div(_price);
    }

    function getPosition(
        address _account,
        address _collateralToken,
        address _indexToken,
        bool _isLong
    )
        public
        view
        override
        returns (
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            bool,
            uint256
        )
    {
        return
            getPositionByKey(
                vaultUtils.getPositionKey(
                    _account,
                    _collateralToken,
                    _indexToken,
                    _isLong,
                    0
                )
            );
    }

    function getPositionByKey(
        bytes32 _key
    )
        public
        view
        override
        returns (
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            bool,
            uint256
        )
    {
        Position memory position = positions[_key];
        uint256 realisedPnl = position.realisedPnl > 0
            ? uint256(position.realisedPnl)
            : uint256(-position.realisedPnl);
        return (
            position.size, // 0
            position.collateral, // 1
            position.averagePrice, // 2
            position.entryFundingRate, // 3
            position.reserveAmount, // 4
            realisedPnl, // 5
            position.realisedPnl >= 0, // 6
            position.lastIncreasedTime // 7
        );
    }

    function getDelta(
        address _indexToken,
        uint256 _size,
        uint256 _averagePrice,
        bool _isLong,
        uint256 _lastIncreasedTime
    ) public view override returns (bool, uint256) {
        _validate(_averagePrice > 0, 38);
        uint256 price = _isLong
            ? getMinPrice(_indexToken)
            : getMaxPrice(_indexToken);
        uint256 priceDelta = _averagePrice > price
            ? _averagePrice.sub(price)
            : price.sub(_averagePrice);
        uint256 delta = _size.mul(priceDelta).div(_averagePrice);

        bool hasProfit;
        if (_isLong) {
            hasProfit = price > _averagePrice;
        } else {
            hasProfit = _averagePrice > price;
        }

        // if the minProfitTime has passed then there will be no min profit threshold
        // the min profit threshold helps to prevent front-running issues
        uint256 minBps = block.timestamp >
            _lastIncreasedTime.add(vaultUtils.minProfitTime())
            ? 0
            : minProfitBasisPoints[_indexToken];
        if (
            hasProfit &&
            delta.mul(vaultUtils.BASIS_POINTS_DIVISOR()) <= _size.mul(minBps)
        ) {
            delta = 0;
        }

        return (hasProfit, delta);
    }

    function updateCumulativeFundingRate(
        address _collateralToken,
        address /*_indexToken*/
    ) public {
   
        if (lastFundingTimes[_collateralToken] == 0) {
            lastFundingTimes[_collateralToken] = block
                .timestamp
                .div(fundingInterval)
                .mul(fundingInterval);
            return;
        }

        if (
            lastFundingTimes[_collateralToken].add(fundingInterval) >
            block.timestamp
        ) {
            return;
        }

        uint256 fundingRate = getNextFundingRate(_collateralToken);
        cumulativeFundingRates[_collateralToken] = cumulativeFundingRates[
            _collateralToken
        ].add(fundingRate);
        lastFundingTimes[_collateralToken] = block
            .timestamp
            .div(fundingInterval)
            .mul(fundingInterval);

        emit UpdateFundingRate(
            _collateralToken,
            cumulativeFundingRates[_collateralToken]
        );
    }

    function getNextFundingRate(
        address _token
    ) public view override returns (uint256) {
        if (lastFundingTimes[_token].add(fundingInterval) > block.timestamp) {
            return 0;
        }

        uint256 intervals = block.timestamp.sub(lastFundingTimes[_token]).div(
            fundingInterval
        );
        uint256 poolAmount = poolAmounts[_token];
        if (poolAmount == 0) {
            return 0;
        }

        uint256 _fundingRateFactor = stableTokens[_token]
            ? stableFundingRateFactor
            : fundingRateFactor;

        return
            _fundingRateFactor.mul(reservedAmounts[_token]).mul(intervals).div(
                poolAmount
            );
    }

    function getPositionLeverage(
        address _account,
        address _collateralToken,
        address _indexToken,
        bool _isLong
    ) public view returns (uint256) {
        bytes32 key = vaultUtils.getPositionKey(
            _account,
            _collateralToken,
            _indexToken,
            _isLong,
            0
        );
        Position memory position = positions[key];
        _validate(position.collateral > 0, 37);
        return
            position.size.mul(vaultUtils.BASIS_POINTS_DIVISOR()).div(
                position.collateral
            );
    }

    // for longs: nextAveragePrice = (nextPrice * nextSize)/ (nextSize + delta)
    // for shorts: nextAveragePrice = (nextPrice * nextSize) / (nextSize - delta)
    function getNextGlobalShortAveragePrice(
        address _indexToken,
        uint256 _nextPrice,
        uint256 _sizeDelta
    ) public view returns (uint256) {
        uint256 size = globalShortSizes[_indexToken];
        uint256 averagePrice = globalShortAveragePrices[_indexToken];
        uint256 priceDelta = averagePrice > _nextPrice
            ? averagePrice.sub(_nextPrice)
            : _nextPrice.sub(averagePrice);
        uint256 delta = size.mul(priceDelta).div(averagePrice);
        bool hasProfit = averagePrice > _nextPrice;

        uint256 nextSize = size.add(_sizeDelta);
        uint256 divisor = hasProfit ? nextSize.sub(delta) : nextSize.add(delta);

        return _nextPrice.mul(nextSize).div(divisor);
    }

    function getGlobalShortDelta(
        address _token
    ) public view returns (bool, uint256) {
        uint256 size = globalShortSizes[_token];
        if (size == 0) {
            return (false, 0);
        }

        uint256 nextPrice = getMaxPrice(_token);
        uint256 averagePrice = globalShortAveragePrices[_token];
        uint256 priceDelta = averagePrice > nextPrice
            ? averagePrice.sub(nextPrice)
            : nextPrice.sub(averagePrice);
        uint256 delta = size.mul(priceDelta).div(averagePrice);
        bool hasProfit = averagePrice > nextPrice;
        return (hasProfit, delta);
    }

    function getTargetUsdxAmount(
        address _token
    ) public view override returns (uint256) {
        uint256 supply = usdxSupply;
        if (supply == 0) {
            return 0;
        }
        uint256 weight = tokenWeights[_token];
        return weight.mul(supply).div(totalTokenWeights);
    }

    function _reduceCollateral(
        address _account,
        address _collateralToken,
        address _indexToken,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong
    ) private returns (uint256, uint256) {
        bytes32 key = vaultUtils.getPositionKey(
            _account,
            _collateralToken,
            _indexToken,
            _isLong,
            0
        );
        Position storage position = positions[key];

        uint256 fee = _collectMarginFees(
            _account,
            _collateralToken,
            _indexToken,
            _isLong,
            _sizeDelta,
            position.size,
            position.entryFundingRate
        );
        bool hasProfit;
        uint256 adjustedDelta;

        // scope variables to avoid stack too deep errors
        {
            (bool _hasProfit, uint256 delta) = getDelta(
                _indexToken,
                position.size,
                position.averagePrice,
                _isLong,
                position.lastIncreasedTime
            );
            hasProfit = _hasProfit;
            // get the proportional change in pnl
            adjustedDelta = _sizeDelta.mul(delta).div(position.size);
        }

        uint256 usdOut;
        // transfer profits out
        if (hasProfit && adjustedDelta > 0) {
            usdOut = adjustedDelta;
            position.realisedPnl = position.realisedPnl + int256(adjustedDelta);

            // pay out realised profits from the pool amount for short positions
            if (!_isLong) {
                uint256 tokenAmount = usdToTokenMin(
                    _collateralToken,
                    adjustedDelta
                );
                _decreasePoolAmount(_collateralToken, tokenAmount);
            }
        }

        if (!hasProfit && adjustedDelta > 0) {
            position.collateral = position.collateral.sub(adjustedDelta);

            // transfer realised losses to the pool for short positions
            // realised losses for long positions are not transferred here as
            // _increasePoolAmount was already called in increasePosition for longs
            if (!_isLong) {
                uint256 tokenAmount = usdToTokenMin(
                    _collateralToken,
                    adjustedDelta
                );
                _increasePoolAmount(_collateralToken, tokenAmount);
            }
            position.realisedPnl = position.realisedPnl - int256(adjustedDelta);
        }

        // reduce the position's collateral by _collateralDelta
        // transfer _collateralDelta out
        if (_collateralDelta > 0) {
            usdOut = usdOut.add(_collateralDelta);
            position.collateral = position.collateral.sub(_collateralDelta);
        }

        // if the position will be closed, then transfer the remaining collateral out
        if (position.size == _sizeDelta) {
            usdOut = usdOut.add(position.collateral);
            position.collateral = 0;
        }

        // if the usdOut is more than the fee then deduct the fee from the usdOut directly
        // else deduct the fee from the position's collateral
        uint256 usdOutAfterFee = usdOut;
        if (usdOut > fee) {
            usdOutAfterFee = usdOut.sub(fee);
        } else {
            position.collateral = position.collateral.sub(fee);
            if (_isLong) {
                uint256 feeTokens = usdToTokenMin(_collateralToken, fee);
                _decreasePoolAmount(_collateralToken, feeTokens);
            }
        }
        emit UpdatePnl(
            key,
            hasProfit,
            adjustedDelta,
            position.size,
            position.collateral,
            usdOut,
            usdOutAfterFee
        );

        return (usdOut, usdOutAfterFee);
    }

    function _validatePosition(
        uint256 _size,
        uint256 _collateral
    ) private view {
        if (_size == 0) {
            _validate(_collateral == 0, 39);
            return;
        }
        _validate(_size >= _collateral, 40);
    }

    function _validateRouter(address _account) private view {
        if (msg.sender == _account) {
            return;
        }
        if (msg.sender == router) {
            return;
        }
        _validate(approvedRouters[_account][msg.sender], 41);
    }

    function _validateTokens(
        address _collateralToken,
        address _indexToken,
        bool _isLong
    ) private view {
        _validate(whitelistedTokens[_collateralToken], 43);
        _validate(whitelistedTokens[_indexToken], 45);
        if (_isLong) {
            _validate(_collateralToken == _indexToken, 42);
            _validate(!stableTokens[_collateralToken], 44);
            return;
        }
        _validate(stableTokens[_collateralToken], 46);
        _validate(!stableTokens[_indexToken], 47);
        _validate(shortableTokens[_indexToken], 48);
    }

    function _collectSwapFees(
        address _token,
        uint256 _amount,
        uint256 _feeBasisPoints
    ) private returns (uint256) {
        uint256 afterFeeAmount = _amount
            .mul(vaultUtils.BASIS_POINTS_DIVISOR().sub(_feeBasisPoints))
            .div(vaultUtils.BASIS_POINTS_DIVISOR());
        uint256 feeAmount = _amount.sub(afterFeeAmount);
        feeReserves[_token] = feeReserves[_token].add(feeAmount);
        uint256 _feeUSD = tokenToUsdMin(_token, feeAmount);
        feeReservesUSD = feeReservesUSD.add(_feeUSD);
        uint256 _tIndex = block.timestamp.div(24 hours);
        feeReservesRecord[_tIndex] = feeReservesRecord[_tIndex].add(_feeUSD);
        emit CollectSwapFees(_token, _feeUSD, feeAmount);
        return afterFeeAmount;
    }

    function _collectMarginFees(
        address _account,
        address _collateralToken,
        address _indexToken,
        bool _isLong,
        uint256 _sizeDelta,
        uint256 _size,
        uint256 _entryFundingRate
    ) private returns (uint256) {
        uint256 feeUsd_norm = vaultUtils.getPositionFee(
            _account,
            _collateralToken,
            _indexToken,
            _isLong,
            _sizeDelta
        );
        uint256 fundingFee = vaultUtils.getFundingFee(
            _account,
            _collateralToken,
            _indexToken,
            _isLong,
            _size,
            _entryFundingRate
        );
        feeUsd_norm = feeUsd_norm.add(fundingFee);
        uint256 feeUsd = feeUsd_norm;
        uint256 feeTokens = usdToTokenMin(_collateralToken, feeUsd);
        feeReserves[_collateralToken] = feeReserves[_collateralToken].add(
            feeTokens
        );
        feeReservesUSD = feeReservesUSD.add(feeUsd);
        uint256 _discFee = eSBT.updateFee(_account, feeUsd);
        feeReservesDiscountedUSD = feeReservesDiscountedUSD.add(_discFee);
        uint256 _tIndex = block.timestamp.div(24 hours);
        feeReservesRecord[_tIndex] = feeReservesRecord[_tIndex].add(feeUsd);
        emit CollectMarginFees(_collateralToken, feeUsd, feeTokens);
        return feeUsd;
    }

    function _transferIn(address _token) private returns (uint256) {
        uint256 prevBalance = tokenBalances[_token];
        uint256 nextBalance = IERC20(_token).balanceOf(address(this));
        tokenBalances[_token] = nextBalance;
        return nextBalance.sub(prevBalance);
    }

    function _transferOut(
        address _token,
        uint256 _amount,
        address _receiver
    ) private {
        IERC20(_token).safeTransfer(_receiver, _amount);
        tokenBalances[_token] = IERC20(_token).balanceOf(address(this));
    }

    function _increasePoolAmount(address _token, uint256 _amount) private {
        poolAmounts[_token] = poolAmounts[_token].add(_amount);
        uint256 balance = IERC20(_token).balanceOf(address(this));
        _validate(poolAmounts[_token] <= balance, 49);
        emit IncreasePoolAmount(_token, _amount);
    }

    function _decreasePoolAmount(address _token, uint256 _amount) private {
        poolAmounts[_token] = poolAmounts[_token].sub(
            _amount,
            "PoolAmount exceeded"
        );
        _validate(reservedAmounts[_token] <= poolAmounts[_token], 50);
        emit DecreasePoolAmount(_token, _amount);
    }

    function _validateBufferAmount(address _token) private view {
        require(
            poolAmounts[_token] >= bufferAmounts[_token],
            "pool less than buffer"
        );
    }

    function _increaseUsdxAmount(address _token, uint256 _amount) private {
        usdxAmounts[_token] = usdxAmounts[_token].add(_amount);
        uint256 maxUsdxAmount = maxUSDAmounts[_token];
        if (maxUsdxAmount != 0 && whitelistedTokens[_token]) {
            _validate(usdxAmounts[_token] <= maxUsdxAmount, 51);
        }
    }

    function _decreaseUsdxAmount(address _token, uint256 _amount) private {
        uint256 value = usdxAmounts[_token];
        if (value <= _amount) {
            usdxAmounts[_token] = 0;
            return;
        }
        usdxAmounts[_token] = value.sub(_amount);
    }

    function _increaseReservedAmount(address _token, uint256 _amount) private {
        reservedAmounts[_token] = reservedAmounts[_token].add(_amount);
        _validate(reservedAmounts[_token] <= poolAmounts[_token], 52);
        emit IncreaseReservedAmount(_token, _amount);
    }

    function _decreaseReservedAmount(address _token, uint256 _amount) private {
        reservedAmounts[_token] = reservedAmounts[_token].sub(
            _amount,
            "Vault: insufficient reserve"
        );
        emit DecreaseReservedAmount(_token, _amount);
    }

    function _increaseGuaranteedUsd(
        address _token,
        uint256 _usdAmount
    ) private {
        guaranteedUsd[_token] = guaranteedUsd[_token].add(_usdAmount);
        emit IncreaseGuaranteedUsd(_token, _usdAmount);
    }

    function _decreaseGuaranteedUsd(
        address _token,
        uint256 _usdAmount
    ) private {
        guaranteedUsd[_token] = guaranteedUsd[_token].sub(_usdAmount);
        emit DecreaseGuaranteedUsd(_token, _usdAmount);
    }

    //----------
    function tokenUtilization(
        address _token
    ) public view override returns (uint256) {
        return
            poolAmounts[_token] > 0
                ? reservedAmounts[_token].mul(1000000).div(poolAmounts[_token])
                : 0;
    }

    function _increaseGlobalShortSize(address _token, uint256 _amount) private {
        globalShortSizes[_token] = globalShortSizes[_token].add(_amount);
        uint256 maxSize = maxGlobalShortSizes[_token];
        if (maxSize != 0) {
            require(
                globalShortSizes[_token] <= maxSize,
                "Vault: max shorts exceeded"
            );
        }
    }

    function _decreaseGlobalShortSize(address _token, uint256 _amount) private {
        uint256 size = globalShortSizes[_token];
        if (_amount > size) {
            globalShortSizes[_token] = 0;
            return;
        }
        globalShortSizes[_token] = size.sub(_amount);
    }

    function _validate(bool _condition, uint256 _errorCode) private view {
        require(_condition, vaultUtils.errors(_errorCode));
    }
}
