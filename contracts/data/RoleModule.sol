// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.0;
import "@openzeppelin/contracts/access/Ownable.sol";

import "./RoleStore.sol";
import "./Role.sol";

contract RoleModule is Ownable {
    RoleStore public roleStore;

    constructor(RoleStore _roleStore) {
        roleStore = _roleStore;
    }

    modifier onlyRouterPlugin() {
        require(
            roleStore.hasRole(msg.sender, Role.ROUTER_PLUGIN),
            "Role: ROUTER_PLUGIN"
        );
        _;
    }

    modifier onlyMarketKeeper() {
        require(
            roleStore.hasRole(msg.sender, Role.MARKET_KEEPER),
            "Role: MARKET_KEEPER"
        );
        _;
    }

    modifier onlyOrderKeeper() {
        require(
            roleStore.hasRole(msg.sender, Role.ORDER_KEEPER),
            "Role: ORDER_KEEPER"
        );
        _;
    }

    modifier onlyPricingKeeper() {
        require(
            roleStore.hasRole(msg.sender, Role.PRICING_KEEPER),
            "Role: PRICING_KEEPER"
        );
        _;
    }

    modifier onlyLiquidationKeeper() {
        require(
            roleStore.hasRole(msg.sender, Role.LIQUIDATION_KEEPER),
            "Role: LIQUIDATION_KEEPER"
        );
        _;
    }
}
