// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "./interfaces/IESBT.sol";
import "../data/DataStore.sol";
import "../utils/NFTUtils.sol";

contract ESBT is
    ReentrancyGuard,
    Ownable,
    IERC721,
    IERC721Metadata,
    IESBT,
    NFTUtils,
    DataStore
{
    using SafeMath for uint256;
    using Strings for uint256;
    using Address for address;

    string internal _baseImgURI; // Base token URI
    string internal _name = "EDE Soul Bound Token"; //

    bytes32 public constant FEEDISCOUNT_UPDATER =
        keccak256("FEEDISCOUNT_UPDATER");
    bytes32 public constant FEE_DISCOUNT_PERCENT =
        keccak256("FEE_DISCOUNT_PERCENT");
    bytes32 public constant FEE_REBATE_PERCENT =
        keccak256("FEE_REBATE_PERCENT");
    uint256 public constant FEE_PERCENT_PRECISION = 1000000;

    bytes32 public constant REFERRAL_PARRENT = keccak256("REFERRAL_PARRENT");
    bytes32 public constant REFERRAL_CHILD = keccak256("REFERRAL_CHILD");
    bytes32 public constant INCREASE_OPE = keccak256("INCREASE_OPE");
    bytes32 public constant COLLATERAL_TOKEN = keccak256("COLLATERAL_TOKEN");
    bytes32 public constant COLLATERAL_SIZE = keccak256("COLLATERAL_SIZE");
    bytes32 public constant POSITION_SIZE = keccak256("POSITION_SIZE");
    bytes32 public constant POSITION_TIME = keccak256("POSITION_TIME");

    bytes32 public constant OPERATION_TYPE = keccak256("OPERATION_TYPE");
    bytes32 public constant OPERATION_LONG = keccak256("OPERATION_LONG");
    bytes32 public constant OPERATION_SHORT = keccak256("OPERATION_SHORT");
    bytes32 public constant ACCUM_POSITIONSIZE =
        keccak256("ACCUM_POSITIONSIZE");
    bytes32 public constant ACCUM_PROFIT = keccak256("ACCUM_PROFIT");
    bytes32 public constant ACCUM_LOSS = keccak256("ACCUM_LOSS");

    bytes32 public constant ACCUM_SWAP = keccak256("ACCUM_SWAP");
    bytes32 public constant ACCUM_ADDLIQUIDITY =
        keccak256("ACCUM_ADDLIQUIDITY");
    bytes32 public constant ACCUM_TRADING = keccak256("ACCUM_TRADING");
    bytes32 public constant ACCUM_STAKE_EDE = keccak256("ACCUM_STAKE_EDE");
    bytes32 public constant ACCUM_SCORE = keccak256("ACCUM_SCORE");
    bytes32 public constant ACCUM_SCORE_TIME = keccak256("ACCUM_SCORE_TIME");

    bytes32 public constant VALID_VAULTS = keccak256("VALID_VAULTS");
    bytes32 public constant VALID_LOGGER = keccak256("VALID_LOGGER");
    bytes32 public constant VALID_SCORE_UPDATER =
        keccak256("VALID_SCORE_UPDATER");

    bytes32 public constant VALID_FEE_UPDATER = keccak256("VALID_FEE_UPDATER");
    bytes32 public constant ACCUM_FEE_DISCOUNTED =
        keccak256("ACCUM_FEE_DISCOUNTED");
    bytes32 public constant ACCUM_FEE_REBATED = keccak256("ACCUM_FEE_REBATED");
    bytes32 public constant ACCUM_FEE = keccak256("ACCUM_FEE");
    bytes32 public constant ACCUM_REBATE = keccak256("ACCUM_REBATE");

    bytes32 public constant MIN_MINT_TRADING_VALUE =
        keccak256("MIN_MINT_TRADING_VALUE");
    uint256 public constant UPDATE_TIME_INTERVAL = 3600 * 24 * 30;

    uint256 public constant SCORE_PRECISION = 10**18;
    uint256 public constant USD_TO_SCORE_PRECISION = 10**12;
    uint256 public constant SCORE_DECREASE_PRECISION = 10**18;
    uint256 public scoreDecreasePerInverval;

    event ScoreUpdate(address _account, uint256 _addition, uint256 _reasonCode);
    event ScoreDecrease(address _account, uint256 _amount, uint256 _timegap);

    mapping(address => uint256) private _balances; // Mapping owner address to token count
    mapping(address => mapping(bytes32 => bytes32)) public tradingKey;
    mapping(address => bytes32) public loggerDef;
    mapping(string => address) public refCodeOwner;
    mapping(address => string) public refCodeContent;
    mapping(address => uint256) private idOwner;
    mapping(uint256 => address) private idAddress;
    mapping(address => uint256) public override createTime;

    struct ESBTStr {
        address owner;
        uint256 id;
    }

    ESBTStr[] private _tokens; //

    mapping(address => string) public override nickName;

    uint256 public PRICE_PRECISION = 10**30;

    constructor() {
        ESBTStr memory _ESBTStr = ESBTStr(address(0), 0);
        _tokens.push(_ESBTStr);
        _safeCreate(address(this), "this");
    }

    function safeMintForUser(address _newAccount, string memory _refCode)
        public
        onlyOwner
    {
        _safeCreate(_newAccount, _refCode);
    }

    function safeMint(string memory _refCode) external returns (string memory) {
        address _newAccount = msg.sender;
        return _safeCreate(_newAccount, _refCode);
    }

    function defaultRefCode() public view returns (string memory) {
        return refCodeContent[address(this)];
    }

    function _safeCreate(address _newAccount, string memory _refCode)
        internal
        returns (string memory)
    {
        address _referalAccount = refCodeOwner[_refCode];
        if (_newAccount != address(this)) {
            require(
                userSizeSum(_newAccount) >= getUint(MIN_MINT_TRADING_VALUE),
                "Min. trading value not satisfied."
            );
            require(_referalAccount != address(0), "Invalid referal Code");
            require(
                balanceOf(_referalAccount) > 0,
                "Referral Account is not active"
            );
        }
        require(balanceOf(_newAccount) < 1, "Only New User permited.");

        uint256 _tId = _tokens.length;
        _balances[_newAccount] += 1;
        idAddress[_tId] = _newAccount;
        idOwner[_newAccount] = _tId;
        ESBTStr memory fESBT = ESBTStr(_newAccount, _tId);
        _tokens.push(fESBT);
        createTime[_newAccount] = block.timestamp;

        grantAddMpAddressSetForAccount(
            _newAccount,
            REFERRAL_PARRENT,
            _referalAccount
        );
        updateReferralForAccount(_newAccount, _referalAccount);
        updateScore(_referalAccount, 10 * SCORE_PRECISION, 0);
        return _genReferralCode(_newAccount);
    }

    function updateReferralForAccount(
        address _account_child,
        address _account_parrent
    ) internal {
        require(
            getAddMpBytes32SetCount(_account_child, REFERRAL_PARRENT) == 0,
            "Parrent already been set"
        );
        require(
            !hasAddMpAddressSet(
                _account_parrent,
                REFERRAL_CHILD,
                _account_child
            ),
            "Child already exist"
        );
        grantAddMpAddressSetForAccount(
            _account_parrent,
            REFERRAL_CHILD,
            _account_child
        );
        grantAddMpAddressSetForAccount(
            _account_child,
            REFERRAL_PARRENT,
            _account_parrent
        );
    }

    function getRefCode(address _account)
        external
        view
        returns (string memory)
    {
        return refCodeContent[_account];
    }

    function setMinMintTValueUSD(uint256 _valut) external onlyOwner {
        setUint(MIN_MINT_TRADING_VALUE, _valut);
    }

    function setScoreDecreasePerMonth(uint256 _scoreDecPercent)
        external
        onlyOwner
    {
        require(
            _scoreDecPercent < SCORE_DECREASE_PRECISION,
            "invalid Decreasefactor"
        );
        scoreDecreasePerInverval = _scoreDecPercent.div(24 * 30 * 3600);
    }

    function setNickName(string memory _setNN) external {
        address _account = msg.sender;
        require(balanceOf(_account) == 1, "invald holder");
        nickName[_account] = _setNN;
    }

    function setVault(address _vault, bool _status) external onlyOwner {
        if (_status) {
            grantAddressSet(VALID_VAULTS, _vault);
            tradingKey[_vault][COLLATERAL_TOKEN] = keccak256(
                abi.encodePacked("COLLATERAL_TOKEN", _vault)
            );
            tradingKey[_vault][COLLATERAL_SIZE] = keccak256(
                abi.encodePacked("COLLATERAL_SIZE", _vault)
            );
            tradingKey[_vault][POSITION_SIZE] = keccak256(
                abi.encodePacked("POSITION_SIZE", _vault)
            );
            tradingKey[_vault][POSITION_TIME] = keccak256(
                abi.encodePacked("POSITION_TIME", _vault)
            );
            tradingKey[_vault][ACCUM_PROFIT] = keccak256(
                abi.encodePacked("ACCUM_PROFIT", _vault)
            );
            tradingKey[_vault][ACCUM_LOSS] = keccak256(
                abi.encodePacked("ACCUM_LOSS", _vault)
            );

            tradingKey[_vault][ACCUM_FEE_DISCOUNTED] = keccak256(
                abi.encodePacked("ACCUM_FEE_DISCOUNTED", _vault)
            );
            tradingKey[_vault][ACCUM_FEE_REBATED] = keccak256(
                abi.encodePacked("ACCUM_FEE_REBATED", _vault)
            );
            tradingKey[_vault][ACCUM_FEE] = keccak256(
                abi.encodePacked("ACCUM_FEE", _vault)
            );

            tradingKey[_vault][ACCUM_POSITIONSIZE] = keccak256(
                abi.encodePacked("ACCUM_POSITIONSIZE", _vault)
            );
            tradingKey[_vault][OPERATION_TYPE] = keccak256(
                abi.encodePacked("OPERATION_TYPE", _vault)
            );
            loggerDef[_vault] = keccak256(
                abi.encodePacked("VALID_LOGGER", _vault)
            );
            _setLogger(_vault, true);
        } else {
            revokeAddressSet(VALID_VAULTS, _vault);
            _setLogger(_vault, false);
        }
    }

    function setFeeUpdater(address _updater, bool _status) external onlyOwner {
        if (_status) {
            grantAddressSet(VALID_FEE_UPDATER, _updater);
            _setLogger(_updater, true);
        } else {
            revokeAddressSet(VALID_FEE_UPDATER, _updater);
            _setLogger(_updater, false);
        }
    }

    function setScoreUpdater(address _updater, bool _status)
        external
        onlyOwner
    {
        if (_status) {
            grantAddressSet(VALID_SCORE_UPDATER, _updater);
            _setLogger(_updater, true);
        } else {
            revokeAddressSet(VALID_SCORE_UPDATER, _updater);
            _setLogger(_updater, false);
        }
    }

    function updateFeeDiscount(
        address _account,
        uint256 _discount,
        uint256 _rebate
    ) external override {
        address _updater = msg.sender;
        require(_discount < FEE_PERCENT_PRECISION.div(2), "invalid discount");
        _validLogger(_updater);
        require(
            hasAddressSet(VALID_FEE_UPDATER, _updater),
            "unauthorized updater"
        );
        setAddUint(_account, FEE_REBATE_PERCENT, _rebate);
        setAddUint(_account, FEE_DISCOUNT_PERCENT, _discount);
    }

    function updateFee(address _account, uint256 _origFee)
        external
        override
        returns (uint256)
    {
        address _vault = msg.sender;
        _validLogger(_vault);
        if (!hasAddressSet(VALID_VAULTS, _vault)) return 0;
        uint256 _discountedFee = _origFee
            .mul(getAddUint(_account, FEE_DISCOUNT_PERCENT))
            .div(FEE_PERCENT_PRECISION);
        uint256 rebateFee = _discountedFee
            .mul(getAddUint(_account, FEE_REBATE_PERCENT))
            .div(FEE_PERCENT_PRECISION);

        incrementAddUint(
            _account,
            tradingKey[_vault][ACCUM_FEE_REBATED],
            rebateFee
        );
        incrementAddUint(
            _account,
            tradingKey[_vault][ACCUM_FEE_DISCOUNTED],
            _discountedFee.sub(rebateFee)
        );
        incrementAddUint(_account, tradingKey[_vault][ACCUM_FEE], _origFee);
        return _discountedFee;
    }

    function getFeeDiscount(address _account)
        external
        view
        override
        returns (uint256)
    {
        return getAddUint(_account, FEE_DISCOUNT_PERCENT);
    }

    function updateIncreaseLogForAccount(
        address _account,
        address _collateralToken,
        uint256 _collateralSize,
        uint256 _positionSize,
        bool /*_isLong*/
    ) external override returns (bool) {
        address _vault = msg.sender;
        _validLogger(_vault);
        if (!hasAddressSet(VALID_VAULTS, _vault)) return false;

        grantAddMpAddressSetForAccount(
            _account,
            tradingKey[_vault][COLLATERAL_TOKEN],
            _collateralToken
        );
        grantAddMpUintSetForAccount(
            _account,
            tradingKey[_vault][COLLATERAL_SIZE],
            _collateralSize
        );
        grantAddMpUintSetForAccount(
            _account,
            tradingKey[_vault][POSITION_SIZE],
            _positionSize
        );
        grantAddMpUintSetForAccount(
            _account,
            tradingKey[_vault][POSITION_TIME],
            block.timestamp
        );
        incrementAddUint(
            _account,
            tradingKey[_vault][ACCUM_POSITIONSIZE],
            _positionSize
        );
        return true;
    }

    function updateTradingScoreForAccount(address _account, uint256 _amount)
        external
        override
    {
        require(
            hasAddressSet(VALID_SCORE_UPDATER, msg.sender),
            "unauthorized updater"
        );
        (address[] memory _par, ) = getReferralForAccount(_account);
        incrementAddUint(_account, ACCUM_TRADING, _amount);
        uint256 _addScore = _amount.div(1000).mul(20).div(
            USD_TO_SCORE_PRECISION
        );
        updateScore(_account, _addScore, 1);
        if (_par.length == 1) {
            uint256 _parAdd = _amount.div(1000).mul(4).div(
                USD_TO_SCORE_PRECISION
            );
            updateScore(_par[0], _parAdd, 11);
        }
    }

    function updateSwapScoreForAccount(address _account, uint256 _amount)
        external
        override
    {
        require(
            hasAddressSet(VALID_SCORE_UPDATER, msg.sender),
            "unauthorized updater"
        );
        (address[] memory _par, ) = getReferralForAccount(_account);
        incrementAddUint(_account, ACCUM_SWAP, _amount);
        uint256 _addScore = _amount.div(1000).mul(15).div(
            USD_TO_SCORE_PRECISION
        );
        updateScore(_account, _addScore, 2);
        if (_par.length == 1)
            updateScore(
                _par[0],
                _amount.div(1000).mul(3).div(USD_TO_SCORE_PRECISION),
                12
            );
    }

    function updateAddLiqScoreForAccount(address _account, uint256 _amount)
        external
        override
    {
        require(
            hasAddressSet(VALID_SCORE_UPDATER, msg.sender),
            "unauthorized updater"
        );
        (address[] memory _par, ) = getReferralForAccount(_account);

        incrementAddUint(_account, ACCUM_ADDLIQUIDITY, _amount);
        updateScore(
            _account,
            _amount.div(1000).mul(10).div(USD_TO_SCORE_PRECISION),
            3
        );
        if (_par.length == 1)
            updateScore(
                _par[0],
                _amount.div(1000).mul(2).div(USD_TO_SCORE_PRECISION),
                13
            );
    }

    function updateStakeEDEScoreForAccount(address _account, uint256 _amount)
        external
        override
    {
        require(
            hasAddressSet(VALID_SCORE_UPDATER, msg.sender),
            "unauthorized updater"
        );
        incrementAddUint(_account, ACCUM_STAKE_EDE, _amount);
        updateScore(
            _account,
            _amount.div(1000).mul(5).div(USD_TO_SCORE_PRECISION),
            4
        );
    }

    function updateScore(
        address _account,
        uint256 _amount,
        uint256 _reasonCode
    ) private {
        uint256 prevTime = getAddUint(_account, ACCUM_SCORE_TIME);
        if (prevTime < 1) prevTime = block.timestamp;
        uint256 timeError = block.timestamp.sub(prevTime);
        uint256 cur_score = getAddUint(_account, ACCUM_SCORE);
        if (timeError > UPDATE_TIME_INTERVAL) {
            uint256 decreaseAmount = cur_score
                .mul(timeError.mul(scoreDecreasePerInverval))
                .div(SCORE_DECREASE_PRECISION);
            setAddUint(_account, ACCUM_SCORE_TIME, block.timestamp);
            decrementAddUint(_account, ACCUM_SCORE, decreaseAmount);
            emit ScoreDecrease(_account, decreaseAmount, timeError);
        }
        incrementAddUint(_account, ACCUM_SCORE, _amount);
        emit ScoreUpdate(_account, _amount, _reasonCode);
    }

    function getScore(address _account) external view returns (uint256) {
        uint256 prevTime = getAddUint(_account, ACCUM_SCORE_TIME);
        if (prevTime < 1) prevTime = block.timestamp;
        uint256 timeError = block.timestamp.sub(prevTime);
        uint256 cur_score = getAddUint(_account, ACCUM_SCORE);

        uint256 decreaseAmount = cur_score
            .mul(timeError.mul(scoreDecreasePerInverval))
            .div(SCORE_DECREASE_PRECISION);

        return cur_score > decreaseAmount ? cur_score.sub(decreaseAmount) : 0;
    }

    function userSize(address _account, address _vault)
        public
        view
        override
        returns (uint256)
    {
        return getAddUint(_account, tradingKey[_vault][ACCUM_POSITIONSIZE]);
    }

    function userSizeSum(address _account)
        public
        view
        override
        returns (uint256)
    {
        address[] memory _vaults = getAddressSetRoles(
            VALID_VAULTS,
            0,
            getAddressSetCount(VALID_VAULTS)
        );
        uint256 _tradeSize = 0;
        for (uint256 k = 0; k < _vaults.length; k++) {
            _tradeSize = _tradeSize.add(userSize(_account, _vaults[k]));
        }
        return _tradeSize;
    }

    function updateProfitForAccount(
        address _account,
        uint256 _profit,
        bool _isProfit
    ) external returns (bool) {
        address _vault = msg.sender;
        _validLogger(_vault);
        if (!hasAddressSet(VALID_VAULTS, _vault)) return false;
        if (_isProfit)
            incrementAddUint(
                _account,
                tradingKey[_vault][ACCUM_PROFIT],
                _profit
            );
        else
            incrementAddUint(_account, tradingKey[_vault][ACCUM_LOSS], _profit);

        return true;
    }

    function _setLogger(address _account, bool _status) internal {
        if (_status && !hasAddressSet(loggerDef[_account], _account))
            grantAddressSet(loggerDef[_account], _account);
        else if (!_status && hasAddressSet(loggerDef[_account], _account))
            revokeAddressSet(loggerDef[_account], _account);
    }

    function _validLogger(address _account) internal view {
        require(hasAddressSet(loggerDef[_account], _account), "invalid logger");
    }

    function _genReferralCode(address _account)
        internal
        returns (string memory)
    {
        if (bytes(refCodeContent[_account]).length == 0) {
            refCodeContent[_account] = string(
                abi.encodePacked(
                    toHexString(createTime[_account].sub(166609643)),
                    toHexString(idOwner[_account])
                )
            );
            refCodeOwner[refCodeContent[_account]] = _account;
        }

        return refCodeContent[_account];
    }

    function getReferralForAccount(address _account)
        public
        view
        override
        returns (address[] memory, address[] memory)
    {
        uint256 childNum = getAddMpAddressSetCount(_account, REFERRAL_CHILD);
        return (
            getAddMpAddressSetRoles(_account, REFERRAL_PARRENT, 0, 1),
            getAddMpAddressSetRoles(_account, REFERRAL_CHILD, 0, childNum)
        );
    }

    function getESBTAddMpUintetRoles(address _mpaddress, bytes32 _key)
        public
        view
        override
        returns (uint256[] memory)
    {
        return
            getAddMpUintetRoles(
                _mpaddress,
                _key,
                0,
                getAddMpUintSetCount(_mpaddress, _key)
            );
    }

    //=================ERC 721 override=================
    /**
     * @dev See {IERC721Metadata-name}.
     */
    function name() public view virtual override returns (string memory) {
        return "EDETrade SoulBoundToken";
    }

    /**
     * @dev See {IERC721Metadata-symbol}.
     */
    function symbol() public view virtual override returns (string memory) {
        return "ESBT";
    }

    /**
     * @dev See {IERC721-approve}.
     */
    function approve(
        address, /*to*/
        uint256 /*tokenId*/
    ) public pure override {
        require(false, "SBT: No approve method");
    }

    /**
     * @dev See {IERC721-getApproved}.
     */
    function getApproved(
        uint256 /*tokenId*/
    ) public pure override returns (address) {
        return address(0);
    }

    /**
     * @dev See {IERC721-setApprovalForAll}.
     */
    function setApprovalForAll(
        address, /*operator*/
        bool /*approved*/
    ) public pure override {
        require(false, "SBT: no approve all");
    }

    /**
     * @dev See {IERC721-isApprovedForAll}.
     */
    function isApprovedForAll(
        address, /*owner*/
        address /*operator*/
    ) public pure override returns (bool) {
        return false;
    }

    function balanceOf(address owner) public view override returns (uint256) {
        require(
            owner != address(0),
            "ERC721: balance query for the zero address"
        );
        return _balances[owner];
    }

    /**
     * @dev See {IERC721-ownerOf}.
     */
    function ownerOf(uint256 tokenId) public view override returns (address) {
        require(_exists(tokenId), "ERC721: owner query for nonexistent token");
        return address(_tokens[tokenId].owner);
    }

    function isOwnerOf(address account, uint256 id) public view returns (bool) {
        address owner = ownerOf(id);
        return owner == account;
    }

    /**
     * @dev See {IERC721-transferFrom}.
     */
    function transferFrom(
        address, /*from*/
        address, /*to*/
        uint256 /*tokenId*/
    ) public pure override {
        require(false, "SoulBoundToken: transfer is not allowed");
    }

    /**
     * @dev See {IERC721-safeTransferFrom}.
     */
    function safeTransferFrom(
        address, /*from*/
        address, /*to*/
        uint256 /*tokenId*/
    ) public pure override {
        require(false, "SoulBoundToken: transfer is not allowed");
    }

    /**
     * @dev See {IERC721-safeTransferFrom}.
     */
    function safeTransferFrom(
        address, /*from*/
        address, /*to*/
        uint256, /*tokenId*/
        bytes memory /*_data*/
    ) public pure override {
        require(false, "SoulBoundToken: transfer is not allowed");
    }

    function _exists(uint256 tokenId) internal view returns (bool) {
        return idAddress[tokenId] != address(0);
    }

    /* ============ Util Functions ============ */
    function setURI(string calldata newURI) external onlyOwner {
        _baseImgURI = newURI;
    }

    function compileAttributes(uint256 tokenId)
        internal
        view
        returns (string memory)
    {
        address _account = ownerOf(tokenId);
        return
            string(
                abi.encodePacked(
                    "[",
                    attributeForTypeAndValue(
                        "FeeDiscount",
                        Strings.toString(
                            getAddUint(_account, FEE_DISCOUNT_PERCENT)
                        )
                    ),
                    ",",
                    attributeForTypeAndValue(
                        "FeeRebate",
                        Strings.toString(
                            getAddUint(_account, FEE_REBATE_PERCENT)
                        )
                    ),
                    ",",
                    attributeForTypeAndValue(
                        "ReferalCode",
                        refCodeContent[_account]
                    ),
                    "]"
                )
            );
    }

    function tokenURI(uint256 tokenId) public view returns (string memory) {
        require(_exists(tokenId), "FTeamNFT: FTeamNFT does not exist");
        string memory metadata = string(
            abi.encodePacked(
                '{"name": "',
                _name,
                " #",
                tokenId.toString(),
                '", "description": "EDE Soul Bound Token", "image": "',
                _baseImgURI,
                '", "attributes":',
                compileAttributes(tokenId),
                "}"
            )
        );
        return
            string(
                abi.encodePacked(
                    "data:application/json;base64,",
                    base64(bytes(metadata))
                )
            );
    }

    function supportsInterface(bytes4 interfaceId)
        public
        pure
        override
        returns (bool)
    {
        return
            interfaceId == type(IERC721).interfaceId ||
            interfaceId == type(IERC721Metadata).interfaceId;
    }
}
