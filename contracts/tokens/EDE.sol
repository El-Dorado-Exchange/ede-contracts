// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../tokens/MintableBaseToken.sol";

contract EDE is MintableBaseToken {
    constructor() MintableBaseToken("EDE Token", "EDE", 0) {}

    function id() external pure returns (string memory _name) {
        return "ELD";
    }
}
