// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "./interfaces/ITimelockTarget.sol";
import "./interfaces/ITimelock.sol";
import "../core/interfaces/IVault.sol";
import "../core/interfaces/IVaultUtils.sol";
import "../core/interfaces/IElpManager.sol";
import "../tokens/interfaces/IUSDX.sol";

contract Timelock is ITimelock, Ownable {
    using SafeMath for uint256;

    uint256 public constant PRICE_PRECISION = 10 ** 30;
    uint256 public constant MAX_BUFFER = 5 days;

    uint256 public buffer;
    uint256 public marginFeeBasisPoints;
    uint256 public maxMarginFeeBasisPoints;
    bool public shouldToggleIsLeverageEnabled;

    mapping(bytes32 => uint256) public pendingActions;

    mapping(address => bool) public isHandler;
    mapping(address => bool) public isKeeper;

    event SignalPendingAction(bytes32 action);
    event SignalApprove(
        address token,
        address spender,
        uint256 amount,
        bytes32 action
    );
    event SignalWithdrawToken(
        address target,
        address token,
        address receiver,
        uint256 amount,
        bytes32 action
    );
    event SignalMint(
        address token,
        address receiver,
        uint256 amount,
        bytes32 action
    );
    event SignalSetMinter(
        address token,
        address minter,
        bool status,
        bytes32 action
    );
    event SignalSetGov(address target, address gov, bytes32 action);
    event SignalSetHandler(
        address target,
        address handler,
        bool isActive,
        bytes32 action
    );
    event SignalSetPriceFeed(address vault, address priceFeed, bytes32 action);
    event SignalRedeemUsdx(address vault, address token, uint256 amount);
    event SignalVaultSetTokenConfig(
        address vault,
        address token,
        uint256 tokenDecimals,
        uint256 tokenWeight,
        uint256 minProfitBps,
        uint256 maxUsdxAmount,
        bool isStable,
        bool isShortable
    );
    event ClearAction(bytes32 action);

    modifier onlyHandlerAndAbove() {
        require(
            msg.sender == owner() || isHandler[msg.sender],
            "Timelock: forbidden"
        );
        _;
    }

    modifier onlyKeeperAndAbove() {
        require(
            msg.sender == owner() ||
                isHandler[msg.sender] ||
                isKeeper[msg.sender],
            "Timelock: forbidden"
        );
        _;
    }

    constructor(
        uint256 _buffer,
        uint256 _marginFeeBasisPoints,
        uint256 _maxMarginFeeBasisPoints
    ) {
        require(_buffer <= MAX_BUFFER, "Timelock: invalid _buffer");
        buffer = _buffer;
        marginFeeBasisPoints = _marginFeeBasisPoints;
        maxMarginFeeBasisPoints = _maxMarginFeeBasisPoints;
    }

    function setContractHandler(
        address _handler,
        bool _isActive
    ) external onlyOwner {
        isHandler[_handler] = _isActive;
    }

    function setKeeper(address _keeper, bool _isActive) external onlyOwner {
        isKeeper[_keeper] = _isActive;
    }

    function setBuffer(uint256 _buffer) external onlyOwner {
        require(_buffer <= MAX_BUFFER, "Timelock: invalid _buffer");
        require(_buffer > buffer, "Timelock: buffer cannot be decreased");
        buffer = _buffer;
    }

    function setRouter(address _vault, address _router) external onlyOwner {
        IVault(_vault).setRouter(_router);
    }

    function setMaxLeverage(
        address _vault,
        uint256 _maxLeverage
    ) external onlyOwner {
        IVaultUtils vaultUtils = IVaultUtils(
            IVault(_vault).vaultUtilsAddress()
        );
        IVaultUtils(vaultUtils).setMaxLeverage(_maxLeverage);
    }

    function setFundingRate(
        address _vault,
        uint256 _fundingInterval,
        uint256 _fundingRateFactor,
        uint256 _stableFundingRateFactor
    ) external onlyKeeperAndAbove {
        IVault(_vault).setFundingRate(
            _fundingInterval,
            _fundingRateFactor,
            _stableFundingRateFactor
        );
    }

    function setShouldToggleIsLeverageEnabled(
        bool _shouldToggleIsLeverageEnabled
    ) external onlyHandlerAndAbove {
        shouldToggleIsLeverageEnabled = _shouldToggleIsLeverageEnabled;
    }

    function setMarginFeeBasisPoints(
        uint256 _marginFeeBasisPoints,
        uint256 _maxMarginFeeBasisPoints
    ) external onlyHandlerAndAbove {
        marginFeeBasisPoints = _marginFeeBasisPoints;
        maxMarginFeeBasisPoints = _maxMarginFeeBasisPoints;
    }

    function setSwapFees(
        address _vault,
        uint256 _taxBasisPoints,
        uint256 _stableTaxBasisPoints,
        uint256 _mintBurnFeeBasisPoints,
        uint256 _swapFeeBasisPoints,
        uint256 _stableSwapFeeBasisPoints
    ) external onlyKeeperAndAbove {
        IVault vault = IVault(_vault);
        IVaultUtils vaultUtils = IVaultUtils(vault.vaultUtilsAddress());
        vaultUtils.setFees(
            _taxBasisPoints,
            _stableTaxBasisPoints,
            _mintBurnFeeBasisPoints,
            _swapFeeBasisPoints,
            _stableSwapFeeBasisPoints,
            maxMarginFeeBasisPoints,
            vaultUtils.liquidationFeeUsd(),
            vaultUtils.minProfitTime(),
            vaultUtils.hasDynamicFees()
        );
    }

    // assign _marginFeeBasisPoints to this.marginFeeBasisPoints
    // because enableLeverage would update Vault.marginFeeBasisPoints to this.marginFeeBasisPoints
    // and disableLeverage would reset the Vault.marginFeeBasisPoints to this.maxMarginFeeBasisPoints
    function setFees(
        address _vault,
        uint256 _taxBasisPoints,
        uint256 _stableTaxBasisPoints,
        uint256 _mintBurnFeeBasisPoints,
        uint256 _swapFeeBasisPoints,
        uint256 _stableSwapFeeBasisPoints,
        uint256 _marginFeeBasisPoints,
        uint256 _liquidationFeeUsd,
        uint256 _minProfitTime,
        bool _hasDynamicFees
    ) external onlyKeeperAndAbove {
        marginFeeBasisPoints = _marginFeeBasisPoints;
        IVaultUtils vaultUtils = IVaultUtils(
            IVault(_vault).vaultUtilsAddress()
        );

        vaultUtils.setFees(
            _taxBasisPoints,
            _stableTaxBasisPoints,
            _mintBurnFeeBasisPoints,
            _swapFeeBasisPoints,
            _stableSwapFeeBasisPoints,
            maxMarginFeeBasisPoints,
            _liquidationFeeUsd,
            _minProfitTime,
            _hasDynamicFees
        );
    }

    function enableLeverage(
        address _vault
    ) external override onlyHandlerAndAbove {
        IVault vault = IVault(_vault);
        IVaultUtils vaultUtils = IVaultUtils(
            IVault(_vault).vaultUtilsAddress()
        );

        if (shouldToggleIsLeverageEnabled) {
            vault.setIsLeverageEnabled(true);
        }

        vaultUtils.setFees(
            vaultUtils.taxBasisPoints(),
            vaultUtils.stableTaxBasisPoints(),
            vaultUtils.mintBurnFeeBasisPoints(),
            vaultUtils.swapFeeBasisPoints(),
            vaultUtils.stableSwapFeeBasisPoints(),
            marginFeeBasisPoints,
            vaultUtils.liquidationFeeUsd(),
            vaultUtils.minProfitTime(),
            vaultUtils.hasDynamicFees()
        );
    }

    function disableLeverage(
        address _vault
    ) external override onlyHandlerAndAbove {
        IVault vault = IVault(_vault);
        IVaultUtils vaultUtils = IVaultUtils(
            IVault(_vault).vaultUtilsAddress()
        );

        if (shouldToggleIsLeverageEnabled) {
            vault.setIsLeverageEnabled(false);
        }

        vaultUtils.setFees(
            vaultUtils.taxBasisPoints(),
            vaultUtils.stableTaxBasisPoints(),
            vaultUtils.mintBurnFeeBasisPoints(),
            vaultUtils.swapFeeBasisPoints(),
            vaultUtils.stableSwapFeeBasisPoints(),
            maxMarginFeeBasisPoints, // marginFeeBasisPoints
            vaultUtils.liquidationFeeUsd(),
            vaultUtils.minProfitTime(),
            vaultUtils.hasDynamicFees()
        );
    }

    function setIsLeverageEnabled(
        address _vault,
        bool _isLeverageEnabled
    ) external override onlyHandlerAndAbove {
        IVault(_vault).setIsLeverageEnabled(_isLeverageEnabled);
    }

    function setTokenConfig(
        address _vault,
        address _token,
        uint256 _tokenWeight,
        uint256 _minProfitBps,
        uint256 _maxUsdxAmount,
        uint256 _bufferAmount,
        uint256 _usdxAmount
    ) external onlyKeeperAndAbove {
        require(_minProfitBps <= 500, "Timelock: invalid _minProfitBps");
        IVault vault = IVault(_vault);
        uint256 tokenDecimals = vault.tokenDecimals(_token);
        bool isStable = vault.stableTokens(_token);
        bool isShortable = vault.shortableTokens(_token);

        IVault(_vault).setTokenConfig(
            _token,
            tokenDecimals,
            _tokenWeight,
            _minProfitBps,
            _maxUsdxAmount,
            isStable,
            isShortable
        );

        IVault(_vault).setBufferAmount(_token, _bufferAmount);
        IVault(_vault).setUsdxAmount(_token, _usdxAmount);
    }

    function setUsdxAmounts(
        address _vault,
        address[] memory _tokens,
        uint256[] memory _usdxAmounts
    ) external onlyKeeperAndAbove {
        for (uint256 i = 0; i < _tokens.length; i++) {
            IVault(_vault).setUsdxAmount(_tokens[i], _usdxAmounts[i]);
        }
    }

    function setMaxGlobalShortSize(
        address _vault,
        address _token,
        uint256 _amount
    ) external onlyKeeperAndAbove {
        IVault(_vault).setMaxGlobalShortSize(_token, _amount);
    }

    function setIsSwapEnabled(
        address _vault,
        bool _isSwapEnabled
    ) external onlyKeeperAndAbove {
        IVault(_vault).setIsSwapEnabled(_isSwapEnabled);
    }

    function setVaultUtils(
        address _vault,
        address _vaultUtils
    ) external onlyOwner {
        IVault(_vault).setVaultUtils(_vaultUtils);
    }

    function setInPrivateLiquidationMode(
        address _vault,
        bool _inPrivateLiquidationMode
    ) external onlyOwner {
        IVault(_vault).setInPrivateLiquidationMode(_inPrivateLiquidationMode);
    }

    function setVaultLiquidator(
        address _vault,
        address _liquidator,
        bool _isActive
    ) external onlyKeeperAndAbove {
        IVault(_vault).setLiquidator(_liquidator, _isActive);
    }

    function transferIn(
        address _sender,
        address _token,
        uint256 _amount
    ) external onlyKeeperAndAbove {
        IERC20(_token).transferFrom(_sender, address(this), _amount);
    }

    function setVaultManager(
        address _vault,
        address _user
    ) external onlyKeeperAndAbove {
        IVault(_vault).setManager(_user, true);
    }

    function setPositionKeeper(
        address _target,
        address _keeper,
        bool _status
    ) external onlyKeeperAndAbove {
        ITimelockTarget(_target).setPositionKeeper(_keeper, _status);
    }

    function setMinExecutionFee(
        address _target,
        uint256 _minExecutionFee
    ) external onlyKeeperAndAbove {
        ITimelockTarget(_target).setMinExecutionFee(_minExecutionFee);
    }

    function setCooldownDuration(
        address _target,
        uint256 _cooldownDuration
    ) external onlyKeeperAndAbove {
        ITimelockTarget(_target).setCooldownDuration(_cooldownDuration);
    }

    function setOrderKeeper(
        address _target,
        address _account,
        bool _isActive
    ) external onlyKeeperAndAbove {
        ITimelockTarget(_target).setOrderKeeper(_account, _isActive);
    }

    function setLiquidator(
        address _target,
        address _account,
        bool _isActive
    ) external onlyKeeperAndAbove {
        ITimelockTarget(_target).setLiquidator(_account, _isActive);
    }

    function setPartner(
        address _target,
        address _account,
        bool _isActive
    ) external onlyKeeperAndAbove {
        ITimelockTarget(_target).setPartner(_account, _isActive);
    }

    //For Router:
    function setESBT(
        address _target,
        address _esbt
    ) external onlyKeeperAndAbove {
        ITimelockTarget(_target).setESBT(_esbt);
    }

    function setInfoCenter(
        address _target,
        address _infCenter
    ) external onlyKeeperAndAbove {
        ITimelockTarget(_target).setInfoCenter(_infCenter);
    }

    function addPlugin(
        address _target,
        address _plugin
    ) external onlyKeeperAndAbove {
        ITimelockTarget(_target).addPlugin(_plugin);
    }

    function removePlugin(
        address _target,
        address _plugin
    ) external onlyKeeperAndAbove {
        ITimelockTarget(_target).removePlugin(_plugin);
    }

    //----------------------------- Timelock functions
    function signalApprove(
        address _token,
        address _spender,
        uint256 _amount
    ) external onlyOwner {
        bytes32 action = keccak256(
            abi.encodePacked("approve", _token, _spender, _amount)
        );
        _setPendingAction(action);
        emit SignalApprove(_token, _spender, _amount, action);
    }

    function approve(
        address _token,
        address _spender,
        uint256 _amount
    ) external onlyOwner {
        bytes32 action = keccak256(
            abi.encodePacked("approve", _token, _spender, _amount)
        );
        _validateAction(action);
        _clearAction(action);
        IERC20(_token).approve(_spender, _amount);
    }

    function signalWithdrawToken(
        address _target,
        address _receiver,
        address _token,
        uint256 _amount
    ) external onlyOwner {
        bytes32 action = keccak256(
            abi.encodePacked(
                "withdrawToken",
                _target,
                _receiver,
                _token,
                _amount
            )
        );
        _setPendingAction(action);
        emit SignalWithdrawToken(_target, _token, _receiver, _amount, action);
    }

    function withdrawToken(
        address _target,
        address _receiver,
        address _token,
        uint256 _amount
    ) external onlyOwner {
        bytes32 action = keccak256(
            abi.encodePacked(
                "withdrawToken",
                _target,
                _receiver,
                _token,
                _amount
            )
        );
        _validateAction(action);
        _clearAction(action);
        ITimelockTarget(_target).withdrawToken(_receiver, _token, _amount);
    }

    function signalSetMinter(
        address _token,
        address _minter,
        bool _status
    ) external onlyOwner {
        bytes32 action = keccak256(
            abi.encodePacked("mint", _token, _minter, _status)
        );
        _setPendingAction(action);
        emit SignalSetMinter(_token, _minter, _status, action);
    }

    function setMinter(
        address _token,
        address _minter,
        bool _status
    ) external onlyOwner {
        bytes32 action = keccak256(
            abi.encodePacked("mint", _token, _minter, _status)
        );
        _validateAction(action);
        _clearAction(action);
        ITimelockTarget(_token).setMinter(_minter, _status);
    }

    function signalMint(
        address _token,
        address _receiver,
        uint256 _amount
    ) external onlyOwner {
        bytes32 action = keccak256(
            abi.encodePacked("mint", _token, _receiver, _amount)
        );
        _setPendingAction(action);
        emit SignalMint(_token, _receiver, _amount, action);
    }

    function mint(
        address _token,
        address _receiver,
        uint256 _amount
    ) external onlyOwner {
        bytes32 action = keccak256(
            abi.encodePacked("mint", _token, _receiver, _amount)
        );
        _validateAction(action);
        _clearAction(action);
        ITimelockTarget(_token).mint(_receiver, _amount);
    }

    function signalSetGov(
        address _target,
        address _gov
    ) external override onlyOwner {
        bytes32 action = keccak256(abi.encodePacked("setGov", _target, _gov));
        _setPendingAction(action);
        emit SignalSetGov(_target, _gov, action);
    }

    function setGov(address _target, address _gov) external onlyOwner {
        bytes32 action = keccak256(abi.encodePacked("setGov", _target, _gov));
        _validateAction(action);
        _clearAction(action);
        ITimelockTarget(_target).setGov(_gov);
    }

    function signalTransOwner(
        address _target,
        address _gov
    ) external override onlyOwner {
        bytes32 action = keccak256(
            abi.encodePacked("transOwner", _target, _gov)
        );
        _setPendingAction(action);
        emit SignalSetGov(_target, _gov, action);
    }

    function transOwner(address _target, address _gov) external onlyOwner {
        bytes32 action = keccak256(
            abi.encodePacked("transOwner", _target, _gov)
        );
        _validateAction(action);
        _clearAction(action);
        ITimelockTarget(_target).transferOwnership(_gov);
    }

    function signalSetHandler(
        address _target,
        address _handler,
        bool _isActive
    ) external onlyOwner {
        bytes32 action = keccak256(
            abi.encodePacked("setHandler", _target, _handler, _isActive)
        );
        _setPendingAction(action);
        emit SignalSetHandler(_target, _handler, _isActive, action);
    }

    function setHandler(
        address _target,
        address _handler,
        bool _isActive
    ) external onlyOwner {
        bytes32 action = keccak256(
            abi.encodePacked("setHandler", _target, _handler, _isActive)
        );
        _validateAction(action);
        _clearAction(action);
        ITimelockTarget(_target).setHandler(_handler, _isActive);
        emit SignalSetHandler(_target, _handler, _isActive, action);
    }

    function signalSetPriceFeed(
        address _vault,
        address _priceFeed
    ) external onlyOwner {
        bytes32 action = keccak256(
            abi.encodePacked("setPriceFeed", _vault, _priceFeed)
        );
        _setPendingAction(action);
        emit SignalSetPriceFeed(_vault, _priceFeed, action);
    }

    function setPriceFeed(
        address _vault,
        address _priceFeed
    ) external onlyOwner {
        bytes32 action = keccak256(
            abi.encodePacked("setPriceFeed", _vault, _priceFeed)
        );
        _validateAction(action);
        _clearAction(action);
        IVault(_vault).setPriceFeed(_priceFeed);
    }

    function cancelAction(bytes32 _action) external onlyOwner {
        _clearAction(_action);
    }

    function _setPendingAction(bytes32 _action) private {
        require(
            pendingActions[_action] == 0,
            "Timelock: action already signalled"
        );
        pendingActions[_action] = block.timestamp.add(buffer);
        emit SignalPendingAction(_action);
    }

    function _validateAction(bytes32 _action) private view {
        require(pendingActions[_action] != 0, "Timelock: action not signalled");
        require(
            pendingActions[_action] < block.timestamp,
            "Timelock: action time not yet passed"
        );
    }

    function _clearAction(bytes32 _action) private {
        require(pendingActions[_action] != 0, "Timelock: invalid _action");
        delete pendingActions[_action];
        emit ClearAction(_action);
    }
}
