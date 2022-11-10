// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "../tokens/interfaces/IELP.sol";
import "../core/interfaces/IElpManager.sol";
import "./interfaces/IRewardTracker.sol";
import "../tokens/interfaces/IMintable.sol";
import "../tokens/interfaces/IWETH.sol";
import "../core/interfaces/IVaultPriceFeedV2.sol";
import "../core/interfaces/IVault.sol";

contract RewardRouter is ReentrancyGuard, Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using Address for address payable;

    uint256 public cooldownDuration = 1 hours;
    mapping(address => uint256) public latestOperationTime;

    uint256 public constant PRICE_TO_EUSD = 10**12; //ATTENTION: must be same as vault.
    uint256 public base_fee_point; //using LVT_PRECISION
    uint256 public constant LVT_PRECISION = 10000;
    uint256 public constant LVT_MINFEE = 50;
    uint256 public constant PRICE_PRECISION = 10**30; //ATTENTION: must be same as vault.

    bool public isInitialized;
    address public rewardToken;
    address public eusd;
    address public weth;

    address[] public allWhitelistedToken;
    mapping(address => bool) public whitelistedToken;

    address public pricefeed;

    uint256 public whitelistedELPnCount;
    uint256 public totalELPnWeights;
    address[] public allWhitelistedELPn;
    mapping(address => bool) public whitelistedELPn;
    mapping(address => uint256) public rewardELPnWeights;
    mapping(address => address) public stakedELPnTracker;
    mapping(address => address) public stakedELPnVault;
    mapping(address => uint256) public tokenDecimals;

    event StakeElp(address account, uint256 amount);
    event UnstakeElp(address account, uint256 amount);

    event UserStakeElp(address account, uint256 amount);
    event UserUnstakeElp(address account, uint256 amount);

    event Claim(address receiver, uint256 amount);

    event BuyEUSD(address account, address token, uint256 amount, uint256 fee);

    event SellEUSD(address account, address token, uint256 amount, uint256 fee);

    function initialize(
        address _rewardToken,
        address _eusd,
        address _weth,
        address _pricefeed,
        uint256 _base_fee_point
    ) external onlyOwner {
        require(!isInitialized, "RewardTracker: already initialized");
        isInitialized = true;
        eusd = _eusd;
        weth = _weth;
        rewardToken = _rewardToken;
        pricefeed = _pricefeed;
        base_fee_point = _base_fee_point;
        tokenDecimals[eusd] = 18; //(eusd).decimals()
    }

    function setPriceFeed(address _pricefeed) external onlyOwner {
        pricefeed = _pricefeed;
    }

    function setBaseFeePoint(uint256 _base_fee_point) external onlyOwner {
        base_fee_point = _base_fee_point;
    }

    function setCooldownDuration(uint256 _setCooldownDuration)
        external
        onlyOwner
    {
        cooldownDuration = _setCooldownDuration;
    }

    function setTokenConfig(address _token, uint256 _token_decimal)
        external
        onlyOwner
    {
        if (!whitelistedToken[_token]) {
            allWhitelistedToken.push(_token);
            whitelistedToken[_token] = true;
        }
        tokenDecimals[_token] = _token_decimal;
    }

    function delToken(address _token) external onlyOwner {
        require(whitelistedToken[_token], "not included");
        whitelistedToken[_token] = false;
    }

    function setELPn(
        address _elp_n,
        uint256 _elp_n_weight,
        address _stakedELPnVault,
        uint256 _elp_n_decimal,
        address _stakedElpTracker
    ) external onlyOwner {
        if (!whitelistedELPn[_elp_n]) {
            whitelistedELPnCount = whitelistedELPnCount.add(1);
            allWhitelistedELPn.push(_elp_n);
        }

        //ATTENTION! set this contract as selp-n minter before initialize.
        //ATTENTION! set elpn reawardTracker as ede minter before initialize.

        uint256 _totalELPnWeights = totalELPnWeights;
        _totalELPnWeights = _totalELPnWeights.sub(rewardELPnWeights[_elp_n]);

        whitelistedELPn[_elp_n] = true;
        tokenDecimals[_elp_n] = _elp_n_decimal;
        rewardELPnWeights[_elp_n] = _elp_n_weight;
        stakedELPnTracker[_elp_n] = _stakedElpTracker;
        stakedELPnVault[_elp_n] = _stakedELPnVault;
        totalELPnWeights = totalELPnWeights.add(_elp_n_weight);
    }

    function clearELPn(address _token) external onlyOwner {
        require(whitelistedELPn[_token], "not included");
        totalELPnWeights = totalELPnWeights.sub(rewardELPnWeights[_token]);

        delete whitelistedELPn[_token];
        delete tokenDecimals[_token];
        delete rewardELPnWeights[_token];
        delete stakedELPnTracker[_token];
        whitelistedELPnCount = whitelistedELPnCount.sub(1);
    }

    // to help users who accidentally send their tokens to this contract
    function withdrawToken(
        address _token,
        address _account,
        uint256 _amount
    ) external onlyOwner {
        IERC20(_token).safeTransfer(_account, _amount);
    }

    function stakedELPnAmount()
        external
        view
        returns (
            address[] memory,
            uint256[] memory,
            uint256[] memory
        )
    {
        uint256 poolLength = allWhitelistedELPn.length;
        uint256[] memory _stakedAmount = new uint256[](poolLength);
        address[] memory _stakedELPn = new address[](poolLength);
        uint256[] memory _poolRewardRate = new uint256[](poolLength);

        for (uint80 i = 0; i < poolLength; i++) {
            _stakedELPn[i] = allWhitelistedELPn[i];
            _stakedAmount[i] = IRewardTracker(
                stakedELPnTracker[allWhitelistedELPn[i]]
            ).poolStakedAmount();
            _poolRewardRate[i] = IRewardTracker(
                stakedELPnTracker[allWhitelistedELPn[i]]
            ).poolTokenRewardPerInterval();
        }
        return (_stakedELPn, _stakedAmount, _poolRewardRate);
    }

    function stakeELPn(address _token, uint256 _elpAmount)
        external
        nonReentrant
        returns (uint256)
    {
        require(_elpAmount > 0, "RewardRouter: invalid _amount");
        require(whitelistedELPn[_token], "RewardTracker: invalid stake Token");
        address account = msg.sender;

        latestOperationTime[account] = block.timestamp;

        IRewardTracker(stakedELPnTracker[_token]).stakeForAccount(
            account,
            account,
            _token,
            _elpAmount
        );

        emit UserStakeElp(account, _elpAmount);

        return _elpAmount;
    }

    function unstakeELPn(address _tokenIn, uint256 _tokenInAmount)
        external
        nonReentrant
        returns (uint256)
    {
        address account = msg.sender;
        require(
            block.timestamp.sub(latestOperationTime[account]) >
                cooldownDuration,
            "Cooldown Time Required."
        );
        latestOperationTime[account] = block.timestamp;

        require(_tokenInAmount > 0, "RewardRouter: invalid _elpAmount");
        require(
            whitelistedELPn[_tokenIn],
            "RewardTracker: invalid stake Token"
        );

        IRewardTracker(stakedELPnTracker[_tokenIn]).unstakeForAccount(
            account,
            _tokenIn,
            _tokenInAmount,
            account
        );

        emit UserUnstakeElp(account, _tokenInAmount);

        return _tokenInAmount;
    }

    //----------------------------------------------------------------------------------------------------------------

    function claimEDEForAccount(address _account)
        external
        nonReentrant
        returns (uint256)
    {
        address account = _account == address(0) ? msg.sender : _account;
        return _claimEDE(account);
    }

    function claimEDE() external nonReentrant returns (uint256) {
        address account = msg.sender;
        return _claimEDE(account);
    }

    function claimEUSDForAccount(address _account)
        public
        nonReentrant
        returns (uint256)
    {
        address account = _account == address(0) ? msg.sender : _account;
        return _claimEUSD(account);
    }

    function claimEUSD() public nonReentrant returns (uint256) {
        address account = msg.sender;
        return _claimEUSD(account);
    }

    function claimableEUSDForAccount(address _account)
        external
        view
        returns (uint256)
    {
        address account = _account == address(0) ? msg.sender : _account;
        uint256 totalClaimReward = 0;
        for (uint80 i = 0; i < allWhitelistedELPn.length; i++) {
            uint256 this_reward = IELP(allWhitelistedELPn[i]).claimable(
                account
            );
            totalClaimReward = totalClaimReward.add(this_reward);
        }
        return totalClaimReward;
    }

    function claimableEUSD() external view returns (uint256) {
        address account = msg.sender;
        uint256 totalClaimReward = 0;
        for (uint80 i = 0; i < allWhitelistedELPn.length; i++) {
            uint256 this_reward = IELP(allWhitelistedELPn[i]).claimable(
                account
            );
            totalClaimReward = totalClaimReward.add(this_reward);
        }
        return totalClaimReward;
    }

    function claimableEUSDListForAccount(address _account)
        external
        view
        returns (address[] memory, uint256[] memory)
    {
        uint256 poolLength = allWhitelistedELPn.length;
        address account = _account == address(0) ? msg.sender : _account;
        address[] memory _stakedELPn = new address[](poolLength);
        uint256[] memory _rewardList = new uint256[](poolLength);
        for (uint80 i = 0; i < allWhitelistedELPn.length; i++) {
            _rewardList[i] = IELP(allWhitelistedELPn[i]).claimable(account);
            _stakedELPn[i] = allWhitelistedELPn[i];
        }
        return (_stakedELPn, _rewardList);
    }

    function claimableEUSDList()
        external
        view
        returns (address[] memory, uint256[] memory)
    {
        uint256 poolLength = allWhitelistedELPn.length;
        address account = msg.sender;
        address[] memory _stakedELPn = new address[](poolLength);
        uint256[] memory _rewardList = new uint256[](poolLength);
        for (uint80 i = 0; i < allWhitelistedELPn.length; i++) {
            _rewardList[i] = IELP(allWhitelistedELPn[i]).claimable(account);
            _stakedELPn[i] = allWhitelistedELPn[i];
        }
        return (_stakedELPn, _rewardList);
    }

    function claimAllForAccount(address _account)
        external
        nonReentrant
        returns (uint256[] memory)
    {
        address account = _account == address(0) ? msg.sender : _account;
        uint256[] memory reward = new uint256[](2);
        reward[0] = _claimEDE(account);
        reward[1] = _claimEUSD(account);
        return reward;
    }

    function claimAll() external nonReentrant returns (uint256[] memory) {
        address account = msg.sender;
        uint256[] memory reward = new uint256[](2);
        reward[0] = _claimEDE(account);
        reward[1] = _claimEUSD(account);
        return reward;
    }

    function _claimEUSD(address _account) private returns (uint256) {
        address account = _account == address(0) ? msg.sender : _account;
        require(
            block.timestamp.sub(latestOperationTime[account]) >
                cooldownDuration,
            "Cooldown Time Required."
        );

        uint256 totalClaimReward = 0;
        for (uint80 i = 0; i < allWhitelistedELPn.length; i++) {
            uint256 this_reward = IELP(allWhitelistedELPn[i]).claimForAccount(
                account
            );
            totalClaimReward = totalClaimReward.add(this_reward);
        }
        return totalClaimReward;
    }

    function _claimEDE(address _account) private returns (uint256) {
        require(
            block.timestamp.sub(latestOperationTime[_account]) >
                cooldownDuration,
            "Cooldown Time Required."
        );
        uint256 totalClaimReward = 0;
        for (uint80 i = 0; i < allWhitelistedELPn.length; i++) {
            uint256 this_reward = IRewardTracker(
                stakedELPnTracker[allWhitelistedELPn[i]]
            ).claimForAccount(_account, _account);
            totalClaimReward = totalClaimReward.add(this_reward);
        }

        require(
            IERC20(rewardToken).balanceOf(address(this)) > totalClaimReward,
            "insufficient EDE"
        );
        IERC20(rewardToken).safeTransfer(_account, totalClaimReward);

        return totalClaimReward;
    }

    function claimableEDEListForAccount(address _account)
        external
        view
        returns (address[] memory, uint256[] memory)
    {
        uint256 poolLength = allWhitelistedELPn.length;
        address[] memory _stakedELPn = new address[](poolLength);
        uint256[] memory _rewardList = new uint256[](poolLength);
        address account = _account == address(0) ? msg.sender : _account;
        for (uint80 i = 0; i < allWhitelistedELPn.length; i++) {
            _rewardList[i] = IRewardTracker(
                stakedELPnTracker[allWhitelistedELPn[i]]
            ).claimable(account);
            _stakedELPn[i] = allWhitelistedELPn[i];
        }
        return (_stakedELPn, _rewardList);
    }

    function claimableEDEList()
        external
        view
        returns (address[] memory, uint256[] memory)
    {
        address account = msg.sender;
        uint256 poolLength = allWhitelistedELPn.length;
        address[] memory _stakedELPn = new address[](poolLength);
        uint256[] memory _rewardList = new uint256[](poolLength);
        for (uint80 i = 0; i < allWhitelistedELPn.length; i++) {
            _rewardList[i] = IRewardTracker(
                stakedELPnTracker[allWhitelistedELPn[i]]
            ).claimable(account);
            _stakedELPn[i] = allWhitelistedELPn[i];
        }
        return (_stakedELPn, _rewardList);
    }

    function claimableEDEForAccount(address _account)
        external
        view
        returns (uint256)
    {
        uint256 _rewardList = 0;
        address account = _account == address(0) ? msg.sender : _account;
        for (uint80 i = 0; i < allWhitelistedELPn.length; i++) {
            _rewardList = _rewardList.add(
                IRewardTracker(stakedELPnTracker[allWhitelistedELPn[i]])
                    .claimable(account)
            );
        }
        return _rewardList;
    }

    function claimableEDE() external view returns (uint256) {
        uint256 _rewardList = 0;
        address account = msg.sender;
        for (uint80 i = 0; i < allWhitelistedELPn.length; i++) {
            _rewardList = _rewardList.add(
                IRewardTracker(stakedELPnTracker[allWhitelistedELPn[i]])
                    .claimable(account)
            );
        }
        return _rewardList;
    }

    function withdrawToEDEPool() external {
        for (uint80 i = 0; i < allWhitelistedELPn.length; i++) {
            IELP(allWhitelistedELPn[i]).withdrawToEDEPool();
        }
    }

    //------ EUSD Part
    function _USDbyFee() internal view returns (uint256) {
        uint256 feeUSD = 0;
        for (uint80 i = 0; i < allWhitelistedELPn.length; i++) {
            feeUSD = feeUSD.add(IELP(allWhitelistedELPn[i]).USDbyFee());
        }
        return feeUSD;
    }

    function _collateralAmount(address token) internal view returns (uint256) {
        uint256 colAmount = 0;
        for (uint80 i = 0; i < allWhitelistedELPn.length; i++) {
            colAmount = colAmount.add(
                IELP(allWhitelistedELPn[i]).TokenFeeReserved(token)
            );
        }

        colAmount = colAmount.add(IERC20(token).balanceOf(address(this)));
        return colAmount;
    }

    function EUSDCirculation() public view returns (uint256) {
        uint256 _EUSDSupply = _USDbyFee().div(PRICE_TO_EUSD);
        return _EUSDSupply.sub(IERC20(eusd).balanceOf(address(this)));
    }

    function feeAUM() public view returns (uint256) {
        uint256 aum = 0;
        for (uint80 i = 0; i < allWhitelistedToken.length; i++) {
            if (!whitelistedToken[allWhitelistedToken[i]]) {
                continue;
            }
            uint256 price = IVaultPriceFeedV2(pricefeed).getOrigPrice(
                allWhitelistedToken[i]
            );
            uint256 poolAmount = _collateralAmount(allWhitelistedToken[i]);
            uint256 _decimalsTk = tokenDecimals[allWhitelistedToken[i]];
            aum = aum.add(poolAmount.mul(price).div(10**_decimalsTk));
        }
        return aum;
    }

    function lvt() public view returns (uint256) {
        uint256 _aumToEUSD = feeAUM().div(PRICE_TO_EUSD);
        uint256 _EUSDSupply = EUSDCirculation();
        return _aumToEUSD.mul(LVT_PRECISION).div(_EUSDSupply);
    }

    function _buyEUSDFee(uint256 _aumToEUSD, uint256 _EUSDSupply)
        internal
        view
        returns (uint256)
    {
        uint256 fee_count = _aumToEUSD > _EUSDSupply ? base_fee_point : 0;
        return fee_count;
    }

    function _sellEUSDFee(uint256 _aumToEUSD, uint256 _EUSDSupply)
        internal
        view
        returns (uint256)
    {
        uint256 fee_count = _aumToEUSD > _EUSDSupply
            ? base_fee_point
            : base_fee_point.add(
                _EUSDSupply.sub(_aumToEUSD).mul(LVT_PRECISION).div(_EUSDSupply)
            );
        return fee_count;
    }

    function buyEUSD(address _token, uint256 _amount)
        external
        nonReentrant
        returns (uint256)
    {
        address _account = msg.sender;
        require(whitelistedToken[_token], "Invalid Token");
        require(_amount > 0, "invalid amount");
        uint256 buyAmount = _buyEUSD(_account, _token, _amount);
        IERC20(_token).transferFrom(_account, address(this), _amount);
        return buyAmount;
    }

    function buyEUSDNative() external payable nonReentrant returns (uint256) {
        address _account = msg.sender;
        uint256 _amount = msg.value;
        address _token = weth;
        require(whitelistedToken[_token], "Invalid Token");
        require(_amount > 0, "invalid amount");

        IWETH(weth).deposit{value: msg.value}();
        uint256 buyAmount = _buyEUSD(_account, _token, _amount);

        return buyAmount;
    }

    function _buyEUSD(
        address _account,
        address _token,
        uint256 _amount
    ) internal returns (uint256) {
        uint256 _aumToEUSD = feeAUM().div(PRICE_TO_EUSD);
        uint256 _EUSDSupply = EUSDCirculation();

        uint256 fee_count = _buyEUSDFee(_aumToEUSD, _EUSDSupply);
        uint256 price = IVaultPriceFeedV2(pricefeed).getOrigPrice(_token);
        uint256 buyEusdAmount = _amount
            .mul(price)
            .div(10**tokenDecimals[_token])
            .mul(10**tokenDecimals[eusd])
            .div(PRICE_PRECISION);
        uint256 fee_cut = buyEusdAmount.mul(fee_count).div(LVT_PRECISION);
        buyEusdAmount = buyEusdAmount.sub(fee_cut);

        require(
            buyEusdAmount < IERC20(eusd).balanceOf(address(this)),
            "insufficient EUSD"
        );
        IERC20(eusd).transfer(_account, buyEusdAmount);

        emit BuyEUSD(_account, _token, buyEusdAmount, fee_count);
        return buyEusdAmount;
    }

    function claimGeneratedFee(address _token) public returns (uint256) {
        uint256 claimedTokenAmount = 0;
        for (uint80 i = 0; i < allWhitelistedELPn.length; i++) {
            claimedTokenAmount = claimedTokenAmount.add(
                IVault(stakedELPnVault[allWhitelistedELPn[i]]).claimFeeToken(
                    _token
                )
            );
        }
        return claimedTokenAmount;
    }

    function sellEUSD(address _token, uint256 _EUSDamount)
        public
        nonReentrant
        returns (uint256)
    {
        require(whitelistedToken[_token], "Invalid Token");
        require(_EUSDamount > 0, "invalid amount");
        address _account = msg.sender;
        uint256 sellTokenAmount = _sellEUSD(_account, _token, _EUSDamount);

        IERC20(_token).transfer(_account, sellTokenAmount);

        return sellTokenAmount;
    }

    function sellEUSDNative(uint256 _EUSDamount)
        public
        nonReentrant
        returns (uint256)
    {
        address _token = weth;
        require(whitelistedToken[_token], "Invalid Token");
        require(_EUSDamount > 0, "invalid amount");
        address _account = msg.sender;
        uint256 sellTokenAmount = _sellEUSD(_account, _token, _EUSDamount);

        IWETH(weth).withdraw(sellTokenAmount);
        payable(_account).sendValue(sellTokenAmount);

        return sellTokenAmount;
    }

    function _sellEUSD(
        address _account,
        address _token,
        uint256 _EUSDamount
    ) internal returns (uint256) {
        uint256 _aumToEUSD = feeAUM().div(PRICE_TO_EUSD);
        uint256 _EUSDSupply = EUSDCirculation();

        uint256 fee_count = _sellEUSDFee(_aumToEUSD, _EUSDSupply);
        uint256 price = IVaultPriceFeedV2(pricefeed).getOrigPrice(_token);
        uint256 sellTokenAmount = _EUSDamount
            .mul(PRICE_PRECISION)
            .div(10**tokenDecimals[eusd])
            .mul(10**tokenDecimals[_token])
            .div(price);
        uint256 fee_cut = sellTokenAmount.mul(fee_count).div(LVT_PRECISION);
        sellTokenAmount = sellTokenAmount.sub(fee_cut);
        claimGeneratedFee(_token);
        require(
            IERC20(_token).balanceOf(address(this)) > sellTokenAmount,
            "insufficient sell token"
        );

        IERC20(eusd).transferFrom(_account, address(this), _EUSDamount);

        uint256 burnEUSDAmount = _EUSDamount.mul(fee_count).div(LVT_PRECISION);
        if (burnEUSDAmount > 0) {
            IMintable(eusd).burn(address(this), burnEUSDAmount);
        }

        return sellTokenAmount;
    }

    function getEUSDPoolInfo() external view returns (uint256[] memory) {
        uint256[] memory _poolInfo = new uint256[](6);
        _poolInfo[0] = feeAUM();
        _poolInfo[1] = EUSDCirculation().add(
            IERC20(eusd).balanceOf(address(this))
        );
        _poolInfo[2] = EUSDCirculation();
        _poolInfo[3] = base_fee_point;
        _poolInfo[4] = _buyEUSDFee(
            _poolInfo[0].div(PRICE_TO_EUSD),
            _poolInfo[2]
        );
        _poolInfo[5] = _sellEUSDFee(
            _poolInfo[0].div(PRICE_TO_EUSD),
            _poolInfo[2]
        );
        return _poolInfo;
    }

    function getEUSDCollateralDetail()
        external
        view
        returns (
            address[] memory,
            uint256[] memory,
            uint256[] memory
        )
    {
        uint256 _length = allWhitelistedToken.length;
        address[] memory _collateralToken = new address[](_length);
        uint256[] memory _collageralAmount = new uint256[](_length);
        uint256[] memory _collageralUSD = new uint256[](_length);

        for (uint256 i = 0; i < allWhitelistedToken.length; i++) {
            if (!whitelistedToken[allWhitelistedToken[i]]) {
                continue;
            }
            uint256 price = IVaultPriceFeedV2(pricefeed).getOrigPrice(
                allWhitelistedToken[i]
            );
            _collateralToken[i] = allWhitelistedToken[i];
            _collageralAmount[i] = _collateralAmount(allWhitelistedToken[i]);
            uint256 _decimalsTk = tokenDecimals[allWhitelistedToken[i]];
            _collageralUSD[i] = _collageralAmount[i].mul(price).div(
                10**_decimalsTk
            );
        }

        return (_collateralToken, _collageralAmount, _collageralUSD);
    }
}
