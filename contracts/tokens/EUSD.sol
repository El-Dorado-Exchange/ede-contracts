// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract EUSD is ERC20, Ownable {
    constructor() ERC20("EUSD", "EUSD") {}

    mapping(address => bool) public isMinter;

    modifier onlyMinter() {
        require(isMinter[msg.sender], "MintableBaseToken: forbidden");
        _;
    }

    function setMinter(address _minter, bool _isActive) external onlyOwner {
        isMinter[_minter] = _isActive;
    }

    function mint(address _account, uint256 _amount) external onlyMinter {
        _mint(_account, _amount);
    }

    function burn(address _account, uint256 _amount) external onlyMinter {
        require(msg.sender == _account, "invalid address");
        _burn(_account, _amount);
    }
}
