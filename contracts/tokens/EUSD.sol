// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../tokens/MintableBaseToken.sol";

contract EUSD is MintableBaseToken {
    constructor() MintableBaseToken("EDE USD", "EUSD", 0) {}

    function id() external pure returns (string memory _name) {
        return "EUSD";
    }
}
