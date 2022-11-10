// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";

import "./interfaces/IVaultPriceFeedV2.sol";
import "../oracle/interfaces/IPriceFeed.sol";
import "../oracle/interfaces/ISecondaryPriceFeed.sol";
import "../oracle/interfaces/IChainlinkFlags.sol";
import "../oracle/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract VaultPriceFeedV2 is IVaultPriceFeedV2, Ownable {
    using SafeMath for uint256;

    uint256 public constant PRICE_PRECISION = 10**30;
    uint256 public constant ONE_USD = PRICE_PRECISION;
    uint256 public constant BASIS_POINTS_DIVISOR = 10000;
    uint256 public constant MAX_SPREAD_BASIS_POINTS = 50;
    uint256 public constant MAX_ADJUSTMENT_INTERVAL = 2 hours;
    uint256 public constant MAX_ADJUSTMENT_BASIS_POINTS = 20;

    uint256 public priceSafetyGap = 5 minutes;

    uint256 public priceVariance = 250;
    uint256 public constant PRICE_VARIANCE_PRECISION = 10000;

    // Identifier of the Sequencer offline flag on the Flags contract
    address private constant FLAG_ARBITRUM_SEQ_OFFLINE =
        address(
            bytes20(
                bytes32(
                    uint256(keccak256("chainlink.flags.arbitrum-seq-offline")) -
                        1
                )
            )
        );

    address public gov;
    address public chainlinkFlags;

    bool public isAmmEnabled = true;
    bool public isSecondaryPriceEnabled = true;
    bool public useV2Pricing = false;
    bool public favorPrimaryPrice = false;
    uint256 public priceSampleSpace = 3;
    uint256 public maxStrictPriceDeviation = 0;
    address public secondaryPriceFeed;
    uint256 public spreadThresholdBasisPoints = 30;

    address public btc;
    address public eth;
    address public bnb;
    address public bnbBusd;
    address public ethBnb;
    address public btcBnb;

    mapping(address => address) public priceFeeds;
    mapping(address => uint256) public chainlinkPrecision;
    mapping(address => address) public chainlinkAddress;
    mapping(address => uint256) public priceDecimals;
    mapping(address => uint256) public spreadBasisPoints;
    // Chainlink can return prices for stablecoins
    // that differs from 1 USD by a larger percentage than stableSwapFeeBasisPoints
    // we use strictStableTokens to cap the price to 1 USD
    // this allows us to configure stablecoins like DAI as being a stableToken
    // while not being a strictStableToken
    mapping(address => bool) public strictStableTokens;

    mapping(address => uint256) public override adjustmentBasisPoints;
    mapping(address => bool) public override isAdjustmentAdditive;
    mapping(address => uint256) public lastAdjustmentTimings;

    function setSafePriceTimeGap(uint256 _gap) external onlyOwner {
        priceSafetyGap = _gap;
    }

    function setChainlinkFlags(address _chainlinkFlags) external onlyOwner {
        chainlinkFlags = _chainlinkFlags;
    }

    function setAdjustment(
        address _token,
        bool _isAdditive,
        uint256 _adjustmentBps
    ) external override onlyOwner {
        require(
            lastAdjustmentTimings[_token].add(MAX_ADJUSTMENT_INTERVAL) <
                block.timestamp,
            "VaultPriceFeed: adjustment frequency exceeded"
        );
        require(
            _adjustmentBps <= MAX_ADJUSTMENT_BASIS_POINTS,
            "invalid _adjustmentBps"
        );
        isAdjustmentAdditive[_token] = _isAdditive;
        adjustmentBasisPoints[_token] = _adjustmentBps;
        lastAdjustmentTimings[_token] = block.timestamp;
    }

    function setUseV2Pricing(bool _useV2Pricing) external override onlyOwner {
        useV2Pricing = _useV2Pricing;
    }

    function setIsAmmEnabled(bool _isEnabled) external override onlyOwner {
        isAmmEnabled = _isEnabled;
    }

    function setIsSecondaryPriceEnabled(bool _isEnabled)
        external
        override
        onlyOwner
    {
        isSecondaryPriceEnabled = _isEnabled;
    }

    function setSecondaryPriceFeed(address _secondaryPriceFeed)
        external
        onlyOwner
    {
        secondaryPriceFeed = _secondaryPriceFeed;
    }

    function setTokens(
        address _btc,
        address _eth,
        address _bnb
    ) external onlyOwner {
        btc = _btc;
        eth = _eth;
        bnb = _bnb;
    }

    function setPairs(
        address _bnbBusd,
        address _ethBnb,
        address _btcBnb
    ) external onlyOwner {
        bnbBusd = _bnbBusd;
        ethBnb = _ethBnb;
        btcBnb = _btcBnb;
    }

    function setSpreadBasisPoints(address _token, uint256 _spreadBasisPoints)
        external
        override
        onlyOwner
    {
        require(
            _spreadBasisPoints <= MAX_SPREAD_BASIS_POINTS,
            "VaultPriceFeed: invalid _spreadBasisPoints"
        );
        spreadBasisPoints[_token] = _spreadBasisPoints;
    }

    function setSpreadThresholdBasisPoints(uint256 _spreadThresholdBasisPoints)
        external
        override
        onlyOwner
    {
        spreadThresholdBasisPoints = _spreadThresholdBasisPoints;
    }

    function setFavorPrimaryPrice(bool _favorPrimaryPrice)
        external
        override
        onlyOwner
    {
        favorPrimaryPrice = _favorPrimaryPrice;
    }

    function setPriceSampleSpace(uint256 _priceSampleSpace)
        external
        override
        onlyOwner
    {
        require(
            _priceSampleSpace > 0,
            "VaultPriceFeed: invalid _priceSampleSpace"
        );
        priceSampleSpace = _priceSampleSpace;
    }

    function setMaxStrictPriceDeviation(uint256 _maxStrictPriceDeviation)
        external
        override
        onlyOwner
    {
        maxStrictPriceDeviation = _maxStrictPriceDeviation;
    }

    function setTokenChainlink(address _token, address _chainlinkContract)
        external
        override
        onlyOwner
    {
        uint256 chainLinkDecimal = uint256(
            AggregatorV3Interface(_chainlinkContract).decimals()
        );
        require(
            chainLinkDecimal < 10 && chainLinkDecimal > 0,
            "invalid chainlink decimal"
        );
        chainlinkAddress[_token] = _chainlinkContract;
        chainlinkPrecision[_token] = 10**chainLinkDecimal;
    }

    function setTokenConfig(
        address _token,
        address _priceFeed,
        uint256 _priceDecimals,
        bool _isStrictStable
    ) external override onlyOwner {
        priceFeeds[_token] = _priceFeed;
        priceDecimals[_token] = _priceDecimals;
        strictStableTokens[_token] = _isStrictStable;
    }

    function getPrice(
        address _token,
        bool _maximise,
        bool,
        bool
    ) public view override returns (uint256) {
        (uint256 pricePr, bool statePr) = getPrimaryPrice(_token, _maximise);
        (uint256 priceCl, bool stateCl) = getChainlinkPrice(_token);

        uint256 price = 0;

        require(stateCl && statePr, "Price Failure");

        uint256 price_minBound = priceCl
            .mul(PRICE_VARIANCE_PRECISION - priceVariance)
            .div(PRICE_VARIANCE_PRECISION);
        uint256 price_maxBound = priceCl
            .mul(PRICE_VARIANCE_PRECISION + priceVariance)
            .div(PRICE_VARIANCE_PRECISION);

        if ((pricePr < price_maxBound) && (pricePr > price_minBound)) {
            price = pricePr;
        } else {
            price = priceCl;
        }
        require(price > 0, "invalid price");

        uint256 adjustmentBps = adjustmentBasisPoints[_token];
        if (adjustmentBps > 0) {
            bool isAdditive = isAdjustmentAdditive[_token];
            if (isAdditive) {
                price = price.mul(BASIS_POINTS_DIVISOR.add(adjustmentBps)).div(
                    BASIS_POINTS_DIVISOR
                );
            } else {
                price = price.mul(BASIS_POINTS_DIVISOR.sub(adjustmentBps)).div(
                    BASIS_POINTS_DIVISOR
                );
            }
        }

        return price;
    }

    function getOrigPrice(address _token)
        public
        view
        override
        returns (uint256)
    {
        (uint256 pricePr, bool statePr) = getPrimaryPrice(_token, true);
        (uint256 priceCl, bool stateCl) = getChainlinkPrice(_token);

        uint256 price = 0;

        require(stateCl && statePr, "Price Failure");

        uint256 price_minBound = priceCl
            .mul(PRICE_VARIANCE_PRECISION - priceVariance)
            .div(PRICE_VARIANCE_PRECISION);
        uint256 price_maxBound = priceCl
            .mul(PRICE_VARIANCE_PRECISION + priceVariance)
            .div(PRICE_VARIANCE_PRECISION);

        if ((pricePr < price_maxBound) && (pricePr > price_minBound)) {
            price = pricePr;
        } else {
            price = priceCl;
        }
        require(price > 0, "invalid price");

        return price;
    }

    function getChainlinkPrice(address _token)
        public
        view
        returns (uint256, bool)
    {
        if (chainlinkAddress[_token] == address(0)) {
            return (0, false);
        }
        if (chainlinkPrecision[_token] < 2) {
            return (0, false);
        }

        (
            ,
            /*uint80 roundId*/
            int256 answer, /*uint256 startedAt*/
            ,
            uint256 updatedAt, /*uint80 answeredInRound*/

        ) = AggregatorV3Interface(chainlinkAddress[_token]).latestRoundData();
        if (answer < 1) {
            return (0, false);
        }

        uint256 time_interval = uint256(block.timestamp).sub(updatedAt);
        if (time_interval > priceSafetyGap && !strictStableTokens[_token]) {
            return (0, false);
        }
        uint256 price = uint256(answer).mul(PRICE_PRECISION).div(
            chainlinkPrecision[_token]
        );
        return (price, true);
    }

    function getLatestPrimaryPrice(address _token)
        public
        view
        override
        returns (uint256)
    {
        address priceFeedAddress = priceFeeds[_token];
        require(
            priceFeedAddress != address(0),
            "VaultPriceFeed: invalid price feed"
        );

        IPriceFeed priceFeed = IPriceFeed(priceFeedAddress);

        int256 price = priceFeed.latestAnswer();
        require(price > 0, "VaultPriceFeed: invalid price");

        return uint256(price);
    }

    function getPrimaryPrice(address _token, bool _maximise)
        public
        view
        override
        returns (uint256, bool)
    {
        address priceFeedAddress = priceFeeds[_token];
        require(
            priceFeedAddress != address(0),
            "VaultPriceFeed: invalid price feed"
        );

        if (chainlinkFlags != address(0)) {
            bool isRaised = IChainlinkFlags(chainlinkFlags).getFlag(
                FLAG_ARBITRUM_SEQ_OFFLINE
            );
            if (isRaised) {
                // If flag is raised we shouldn't perform any critical operations
                revert("Chainlink feeds are not being updated");
            }
        }

        IPriceFeed priceFeed = IPriceFeed(priceFeedAddress);

        uint256 price = 0;
        uint80 roundId = priceFeed.latestRound();
        uint256 roundTimestamp = priceFeed.latestTimestamp();

        uint256 time_interval = uint256(block.timestamp).sub(roundTimestamp);
        if (time_interval > priceSafetyGap && !strictStableTokens[_token]) {
            return (0, false);
        }

        for (uint80 i = 0; i < priceSampleSpace; i++) {
            if (roundId <= i) {
                break;
            }
            uint256 p;

            if (i == 0) {
                int256 _p = priceFeed.latestAnswer();
                require(_p > 0, "VaultPriceFeed: invalid price");
                p = uint256(_p);
            } else {
                (, int256 _p, , , ) = priceFeed.getRoundData(roundId - i);
                require(_p > 0, "VaultPriceFeed: invalid price");
                p = uint256(_p);
            }

            if (price == 0) {
                price = p;
                continue;
            }

            if (_maximise && p > price) {
                price = p;
                continue;
            }

            if (!_maximise && p < price) {
                price = p;
            }
        }

        require(price > 0, "VaultPriceFeed: could not fetch price");
        // normalise price precision
        uint256 _priceDecimals = priceDecimals[_token];
        return (price.mul(PRICE_PRECISION).div(10**_priceDecimals), true);
    }

    function getSecondaryPrice(
        address _token,
        uint256 _referencePrice,
        bool _maximise
    ) public view returns (uint256) {
        if (secondaryPriceFeed == address(0)) {
            return _referencePrice;
        }
        return
            ISecondaryPriceFeed(secondaryPriceFeed).getPrice(
                _token,
                _referencePrice,
                _maximise
            );
    }
}
