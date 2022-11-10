// SPDX-License-Identifier: MIT

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "./interfaces/IVault.sol";
import "./interfaces/IElpManager.sol";
import "../tokens/interfaces/IUSDX.sol";
import "../tokens/interfaces/IMintable.sol";
import "../tokens/interfaces/IWETH.sol";
import "../DID/interfaces/IESBT.sol";


pragma solidity ^0.8.0;

contract ElpManager is ReentrancyGuard, Ownable, IElpManager {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using Address for address payable;

    uint256 public constant PRICE_PRECISION = 10**30;
    uint256 public constant USDX_DECIMALS = 18;
    uint256 public constant MAX_COOLDOWN_DURATION = 48 hours;

    uint256 public constant WEIGHT_PRECISSION = 1000000;

    IVault public vault;
    address public elp;
    address public weth;
    address public esbt;

    uint256 public override cooldownDuration;
    mapping(address => uint256) public override lastAddedAt;

    uint256 public aumAddition;
    uint256 public aumDeduction;

    bool public inPrivateMode;
    mapping(address => bool) public isHandler;

    event AddLiquidity(
        address account,
        address token,
        uint256 amount,
        uint256 aumInUsdx,
        uint256 elpSupply,
        uint256 usdxAmount,
        uint256 mintAmount
    );

    event RemoveLiquidity(
        address account,
        address token,
        uint256 elpAmount,
        uint256 aumInUsdx,
        uint256 elpSupply,
        uint256 usdxAmount,
        uint256 amountOut
    );

    constructor(
        address _vault,
        address _elp,
        uint256 _cooldownDuration,
        address _weth
    ) {
        vault = IVault(_vault);
        elp = _elp;
        cooldownDuration = _cooldownDuration;
        weth = _weth;
    }

    function setInPrivateMode(bool _inPrivateMode) external onlyOwner {
        inPrivateMode = _inPrivateMode;
    }

    function setHandler(address _handler, bool _isActive) external onlyOwner {
        isHandler[_handler] = _isActive;
    }

    function setESBT(address _esbt) external onlyOwner {
        esbt = _esbt;
    }

    function setCooldownDuration(uint256 _cooldownDuration) external onlyOwner {
        require(
            _cooldownDuration <= MAX_COOLDOWN_DURATION,
            "ElpManager: invalid _cooldownDuration"
        );
        cooldownDuration = _cooldownDuration;
    }

    function setAumAdjustment(uint256 _aumAddition, uint256 _aumDeduction)
        external
        onlyOwner
    {
        aumAddition = _aumAddition;
        aumDeduction = _aumDeduction;
    }

    function addLiquidity(
        address _token,
        uint256 _amount,
        uint256 _minUsdx,
        uint256 _minElp
    ) external override nonReentrant returns (uint256) {
        if (inPrivateMode) {
            revert("ElpManager: action not enabled");
        }
        return
            _addLiquidity(
                msg.sender,
                msg.sender,
                _token,
                _amount,
                _minUsdx,
                _minElp
            );
    }

    function addLiquidityETH() external payable nonReentrant returns (uint256) {
        if (inPrivateMode) {
            revert("ElpManager: action not enabled");
        }
        if (msg.value < 1) {
            return 0;
        }
        IWETH(weth).deposit{value: msg.value}();
        address _account = msg.sender;
        uint256 _amount = msg.value;
        address _token = weth;

        uint256 aumInUSD = getAumInUSD(true);
        uint256 elpSupply = IERC20(elp).totalSupply();

        IERC20(weth).safeTransfer(address(vault), _amount);

        uint256 usdxAmount = vault.buyUSDX(_token, address(this));
        uint256 mintAmount = aumInUSD == 0
            ? usdxAmount
            : usdxAmount.mul(elpSupply).div(aumInUSD);

        IMintable(elp).mint(_account, mintAmount);
        lastAddedAt[_account] = block.timestamp;

        emit AddLiquidity(
            _account,
            _token,
            _amount,
            aumInUSD,
            elpSupply,
            usdxAmount,
            mintAmount
        );

        return mintAmount;
    }

    function _addLiquidity(
        address _fundingAccount,
        address _account,
        address _token,
        uint256 _amount,
        uint256 _minUsdx,
        uint256 _minElp
    ) private returns (uint256) {
        require(_fundingAccount != address(0), "zero address");
        require(_account != address(0), "ElpManager: zero address");
        require(_amount > 0, "ElpManager: invalid amount");

        // calculate aum before buyUSDX
        uint256 aumInUSD = getAumInUSD(true);
        uint256 elpSupply = IERC20(elp).totalSupply();

        IERC20(_token).safeTransferFrom(
            _fundingAccount,
            address(vault),
            _amount
        );

        uint256 usdxAmount = vault.buyUSDX(_token, address(this));
        require(usdxAmount >= _minUsdx, "ElpManager: insufficient USDX output");

        uint256 mintAmount = aumInUSD == 0
            ? usdxAmount
            : usdxAmount.mul(elpSupply).div(aumInUSD);
        require(mintAmount >= _minElp, "ElpManager: insufficient ELP output");

        IMintable(elp).mint(_account, mintAmount);

        lastAddedAt[_account] = block.timestamp;

        IESBT(esbt).updateAddLiqScoreForAccount(_account, usdxAmount);

        emit AddLiquidity(
            _account,
            _token,
            _amount,
            aumInUSD,
            elpSupply,
            usdxAmount,
            mintAmount
        );

        return mintAmount;
    }

    function removeLiquidity(
        address _tokenOut,
        uint256 _elpAmount,
        uint256 _minOut,
        address _receiver
    ) external override nonReentrant returns (uint256) {
        if (inPrivateMode) {
            revert("ElpManager: action not enabled");
        }
        return
            _removeLiquidity(
                msg.sender,
                _tokenOut,
                _elpAmount,
                _minOut,
                _receiver
            );
    }

    function removeLiquidityForAccount(
        address _account,
        address _tokenOut,
        uint256 _elpAmount,
        uint256 _minOut,
        address _receiver
    ) external nonReentrant returns (uint256) {
        _validateHandler();
        return
            _removeLiquidity(
                _account,
                _tokenOut,
                _elpAmount,
                _minOut,
                _receiver
            );
    }

    function _removeLiquidity(
        address _account,
        address _tokenOut,
        uint256 _elpAmount,
        uint256 _minOut,
        address _receiver
    ) private returns (uint256) {
        require(
            _account != address(0),
            "BEP20: transfer from the zero address"
        );
        require(_elpAmount > 0, "ElpManager: invalid _elpAmount");
        require(
            lastAddedAt[_account].add(cooldownDuration) <= block.timestamp,
            "ElpManager: cooldown duration not yet passed"
        );
        require(
            IERC20(elp).balanceOf(_account) >= _elpAmount,
            "insufficient ELP"
        );
        // calculate aum before sellUSDX
        uint256 aumInUSD = getAumInUSD(false);
        uint256 elpSupply = IERC20(elp).totalSupply();
        uint256 usdxAmount = _elpAmount.mul(aumInUSD).div(elpSupply);
        IMintable(elp).burn(_account, _elpAmount);
        uint256 amountOut = vault.sellUSDX(_tokenOut, _receiver, usdxAmount);
        require(amountOut >= _minOut, "ElpManager: insufficient output");

        emit RemoveLiquidity(
            _account,
            _tokenOut,
            _elpAmount,
            aumInUSD,
            elpSupply,
            usdxAmount,
            amountOut
        );

        return amountOut;
    }

    function removeLiquidityETH(uint256 _elpAmount)
        external
        payable
        nonReentrant
        returns (uint256)
    {
        if (inPrivateMode) {
            revert("ElpManager: action not enabled");
        }
        address _account = msg.sender;
        require(
            _account != address(0),
            "BEP20: transfer from the zero address"
        );
        require(_elpAmount > 0, "ElpManager: invalid _elpAmount");

        require(
            lastAddedAt[_account].add(cooldownDuration) <= block.timestamp,
            "ElpManager: cooldown duration not yet passed"
        );
        require(
            IERC20(elp).balanceOf(_account) >= _elpAmount,
            "insufficient ELP"
        );

        address _tokenOut = weth;
        uint256 aumInUSD = getAumInUSD(false);
        uint256 elpSupply = IERC20(elp).totalSupply();
        uint256 usdxAmount = _elpAmount.mul(aumInUSD).div(elpSupply);

        IMintable(elp).burn(_account, _elpAmount);
        uint256 _amountOut = vault.sellUSDX(
            _tokenOut,
            address(this),
            usdxAmount
        );

        IWETH(weth).withdraw(_amountOut);
        payable(_account).sendValue(_amountOut);

        emit RemoveLiquidity(
            _account,
            _tokenOut,
            _elpAmount,
            aumInUSD,
            elpSupply,
            usdxAmount,
            _amountOut
        );
        return _amountOut;
    }

    function getPoolInfo() public view returns (uint256[] memory) {
        uint256[] memory poolInfo = new uint256[](4);
        poolInfo[0] = getAum(true);
        poolInfo[1] = getAumSimple(true);
        poolInfo[2] = IERC20(elp).totalSupply();
        poolInfo[3] = IVault(vault).usdxSupply();
        return poolInfo;
    }

    function getPoolTokenList() public view returns (address[] memory) {
        uint256 length = vault.allWhitelistedTokensLength();
        require(length > 0, "Empty Pool");
        address[] memory whiteLT = new address[](length);

        for (uint256 i = 0; i < length; i++) {
            address token = vault.allWhitelistedTokens(i);
            if (vault.whitelistedTokens(token)) {
                whiteLT[i] = token;
            }
        }
        return whiteLT;
    }

    function getPoolTokenInfo(address _token)
        public
        view
        returns (uint256[] memory)
    {
        require(vault.whitelistedTokens(_token), "invalid token");
        uint256[] memory tokenIinfo = new uint256[](7);
        tokenIinfo[0] = vault.totalTokenWeights() > 0
            ? vault.tokenWeights(_token).mul(1000000).div(
                vault.totalTokenWeights()
            )
            : 0;
        tokenIinfo[1] = vault.tokenUtilization(_token);
        tokenIinfo[2] = vault.poolAmounts(_token);
        tokenIinfo[3] = vault.getMaxPrice(_token);
        tokenIinfo[4] = vault.getMinPrice(_token);
        tokenIinfo[5] = vault.getTokenFundingRate(_token);
        tokenIinfo[6] = vault.poolAmounts(_token);

        return tokenIinfo;
    }

    function getAums() public view returns (uint256[] memory) {
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = getAum(true);
        amounts[1] = getAum(false);
        return amounts;
    }

    function getAumInUSD(bool maximise) public view returns (uint256) {
        uint256 aum = getAum(maximise);
        return aum.mul(10**USDX_DECIMALS).div(PRICE_PRECISION);
    }

    function getAum(bool maximise) public view returns (uint256) {
        uint256 length = vault.allWhitelistedTokensLength();
        uint256 aum = aumAddition;
        uint256 shortProfits = 0;

        for (uint256 i = 0; i < length; i++) {
            address token = vault.allWhitelistedTokens(i);
            bool isWhitelisted = vault.whitelistedTokens(token);

            if (!isWhitelisted) {
                continue;
            }

            uint256 price = maximise
                ? vault.getMaxPrice(token)
                : vault.getMinPrice(token);
            uint256 poolAmount = vault.poolAmounts(token);
            uint256 decimals = vault.tokenDecimals(token);

            if (vault.stableTokens(token)) {
                aum = aum.add(poolAmount.mul(price).div(10**decimals));
            } else {
                // add global short profit / loss
                uint256 size = vault.globalShortSizes(token);
                if (size > 0) {
                    uint256 averagePrice = vault.globalShortAveragePrices(
                        token
                    );
                    uint256 priceDelta = averagePrice > price
                        ? averagePrice.sub(price)
                        : price.sub(averagePrice);
                    uint256 delta = size.mul(priceDelta).div(averagePrice);
                    if (price > averagePrice) {
                        // add losses from shorts
                        aum = aum.add(delta);
                    } else {
                        shortProfits = shortProfits.add(delta);
                    }
                }

                aum = aum.add(vault.guaranteedUsd(token));

                uint256 reservedAmount = vault.reservedAmounts(token);
                if (poolAmount > reservedAmount) {
                    aum = aum.add(
                        poolAmount.sub(reservedAmount).mul(price).div(
                            10**decimals
                        )
                    );
                }
            }
        }

        aum = shortProfits > aum ? 0 : aum.sub(shortProfits);
        return aumDeduction > aum ? 0 : aum.sub(aumDeduction);
    }

    function getAumSimple(bool maximise) public view returns (uint256) {
        uint256 length = vault.allWhitelistedTokensLength();
        uint256 aum = aumAddition;

        for (uint256 i = 0; i < length; i++) {
            address token = vault.allWhitelistedTokens(i);
            bool isWhitelisted = vault.whitelistedTokens(token);

            if (!isWhitelisted) {
                continue;
            }

            uint256 price = maximise
                ? vault.getMaxPrice(token)
                : vault.getMinPrice(token);
            uint256 poolAmount = vault.poolAmounts(token);
            uint256 decimals = vault.tokenDecimals(token);
            aum = aum.add(poolAmount.mul(price).div(10**decimals));
        }
        return aum;
    }

    function getWeightDetailed()
        public
        view
        returns (address[] memory, uint256[] memory)
    {
        uint256 length = vault.allWhitelistedTokensLength();
        uint256 aum = 0;
        uint256[] memory tokenAum = new uint256[](length);
        address[] memory tokenAddress = new address[](length);

        uint256 shortProfits = 0;

        for (uint256 i = 0; i < length; i++) {
            address token = vault.allWhitelistedTokens(i);
            bool isWhitelisted = vault.whitelistedTokens(token);

            if (!isWhitelisted) {
                continue;
            }

            uint256 price = vault.getMaxPrice(token);
            uint256 poolAmount = vault.poolAmounts(token);
            uint256 decimals = vault.tokenDecimals(token);

            if (vault.stableTokens(token)) {
                uint256 _pA = poolAmount.mul(price).div(10**decimals);
                aum = aum.add(_pA);
                tokenAum[i] = tokenAum[i].add(_pA);
            } else {
                // add global short profit / loss
                uint256 size = vault.globalShortSizes(token);
                if (size > 0) {
                    uint256 averagePrice = vault.globalShortAveragePrices(
                        token
                    );
                    uint256 priceDelta = averagePrice > price
                        ? averagePrice.sub(price)
                        : price.sub(averagePrice);
                    uint256 delta = size.mul(priceDelta).div(averagePrice);
                    if (price > averagePrice) {
                        // add losses from shorts
                        aum = aum.add(delta);
                        tokenAum[i] = tokenAum[i].add(delta);
                    } else {
                        shortProfits = shortProfits.add(delta);
                    }
                }

                aum = aum.add(vault.guaranteedUsd(token));
                tokenAum[i] = tokenAum[i].add(vault.guaranteedUsd(token));

                uint256 reservedAmount = vault.reservedAmounts(token);
                if (poolAmount > reservedAmount) {
                    uint256 _mdfAmount = poolAmount
                        .sub(reservedAmount)
                        .mul(price)
                        .div(10**decimals);
                    aum = aum.add(_mdfAmount);
                    tokenAum[i] = tokenAum[i].add(_mdfAmount);
                }
            }
        }

        for (uint256 i = 0; i < length; i++) {
            tokenAum[i] = aum > 0
                ? tokenAum[i].mul(WEIGHT_PRECISSION).div(aum)
                : 0;
        }

        return (tokenAddress, tokenAum);
    }

    function _validateHandler() private view {
        require(isHandler[msg.sender], "ElpManager: forbidden");
    }
}
