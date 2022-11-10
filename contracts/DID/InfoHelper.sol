// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "./interfaces/IESBT.sol";

interface ShaHld {
    function getReferalState(address _account)
        external
        view
        returns (
            uint256,
            uint256[] memory,
            address[] memory,
            uint256[] memory,
            bool[] memory
        );
}

interface IDataStore {
    function getAddressSetCount(bytes32 _key) external view returns (uint256);

    function getAddressSetRoles(
        bytes32 _key,
        uint256 _start,
        uint256 _end
    ) external view returns (address[] memory);

    function getAddUint(address _account, bytes32 key)
        external
        view
        returns (uint256);
}

contract InfoHelper {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    bytes32 public constant ACCUM_REBATE = keccak256("ACCUM_REBATE");
    bytes32 public constant VALID_VAULTS = keccak256("VALID_VAULTS");
    bytes32 public constant ACCUM_SWAP = keccak256("ACCUM_SWAP");
    bytes32 public constant ACCUM_ADDLIQUIDITY =
        keccak256("ACCUM_ADDLIQUIDITY");
    bytes32 public constant ACCUM_TRADING = keccak256("ACCUM_TRADING");

    bytes32 public constant ACCUM_FEE_DISCOUNTED =
        keccak256("ACCUM_FEE_DISCOUNTED");
    bytes32 public constant ACCUM_FEE = keccak256("ACCUM_FEE");

    uint256 private constant PRECISION_COMPLE = 10000;

    function getInvitedUser(address _ESBT, address _account)
        public
        view
        returns (address[] memory, uint256[] memory)
    {
        (, address[] memory childs) = IESBT(_ESBT).getReferralForAccount(
            _account
        );

        uint256[] memory infos = new uint256[](childs.length * 3);

        for (uint256 i = 0; i < childs.length; i++) {
            infos[i * 3] = IESBT(_ESBT).createTime(childs[i]);
            infos[i * 3 + 1] = IESBT(_ESBT).userSizeSum(childs[i]);
            infos[i * 3 + 2] = 0;
        }
        return (childs, infos);
    }

    function getBasicInfo(address _ESBT, address _account)
        public
        view
        returns (string memory, uint256[] memory)
    {
        uint256[] memory infos = new uint256[](7);
        infos[0] = IESBT(_ESBT).getFeeDiscount(_account);
        infos[1] = 0; //rebate

        address[] memory validVaults = IDataStore(_ESBT).getAddressSetRoles(
            VALID_VAULTS,
            0,
            IDataStore(_ESBT).getAddressSetCount(VALID_VAULTS)
        );

        for (uint256 i = 0; i < validVaults.length; i++) {
            infos[2] = infos[3].add(
                IDataStore(_ESBT).getAddUint(
                    _account,
                    IESBT(_ESBT).tradingKey(validVaults[i], ACCUM_SWAP)
                )
            );
            infos[3] = infos[3].add(
                IDataStore(_ESBT).getAddUint(
                    _account,
                    IESBT(_ESBT).tradingKey(validVaults[i], ACCUM_ADDLIQUIDITY)
                )
            );
            infos[4] = infos[4].add(
                IDataStore(_ESBT).getAddUint(
                    _account,
                    IESBT(_ESBT).tradingKey(validVaults[i], ACCUM_TRADING)
                )
            );
            infos[5] = infos[5].add(
                IDataStore(_ESBT).getAddUint(
                    _account,
                    IESBT(_ESBT).tradingKey(
                        validVaults[i],
                        ACCUM_FEE_DISCOUNTED
                    )
                )
            );
            infos[6] = infos[6].add(
                IDataStore(_ESBT).getAddUint(
                    _account,
                    IESBT(_ESBT).tradingKey(validVaults[i], ACCUM_FEE)
                )
            );
        }

        return (IESBT(_ESBT).nickName(_account), infos);
    }

    function needUpdate(address _shareAct, address _account)
        public
        view
        returns (uint256)
    {
        (
            uint256 _refNum,
            uint256[] memory _compList,
            address[] memory _userList,
            ,

        ) = ShaHld(_shareAct).getReferalState(_account);

        if (_refNum == _userList.length) return 0;

        uint256 needUpd = 1;
        for (uint256 i = 0; i < _compList.length; i++) {
            if (_compList[i] < PRECISION_COMPLE) {
                needUpd = i + 1;
                break;
            }
        }
        return needUpd;
    }
}
