pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {PerpDexHook} from "../src/PerpDexHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

contract SimulatePerpDex is Script {
    PerpDexHook hook;
    address operator = address(1);
    address mockPoolManager = address(2);
    address mockPriceFeed = address(3);

    function setUp() public {
        // Create local setup
        hook = new PerpDexHook(
            IPoolManager(mockPoolManager),
            mockPriceFeed,
            true,
            operator
        );
    }

    function run() public {
        vm.startBroadcast();

        console.log("\n=== PerpDex Demo Simulation ===\n");

        // Scenario 1: Basic Market
        console.log("Scenario 1: Market Setup");
        console.log("-----------------------");
        simulateBasicMarket();

        // Scenario 2: Funding Payments
        console.log("\nScenario 2: Funding Rate Impact");
        console.log("-----------------------------");
        simulateFundingPayments();

        vm.stopBroadcast();
    }

    function simulateBasicMarket() internal {
        // Add initial liquidity
        // Open some positions
        // Print state
        console.log("Long Interest: %s", hook.longOpenInterest());
        console.log("Short Interest: %s", hook.shortOpenInterest());
        console.log("Buffer Capital: %s", hook.bufferCapitalCurrency0());
    }

    function simulateFundingPayments() internal {
        // Add imbalanced positions
        // Run funding payments
        // Show profit/loss
    }
}
