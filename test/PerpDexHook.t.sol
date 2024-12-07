// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PerpDexHook} from "../src/PerpDexHook.sol";
import {Deployers} from "lib/v4-periphery/lib/v4-core/test/utils/Deployers.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockPriceFeed} from "./mocks/MockPriceFeed.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {LiquidityAmounts} from "lib/v4-periphery/lib/v4-core/test/utils/LiquidityAmounts.sol";

import "forge-std/console.sol";

contract PerpDexHookTest is Test, Deployers {
    PerpDexHook public hook;
    MockERC20 public token0;
    MockERC20 public token1;
    MockPriceFeed public mockFeed;

    address public operator;
    address public mockPriceFeed;

    uint256 constant LP1_AMOUNT = 2e18;
    int256 constant INITIAL_PRICE = 1000e18; // $1000 base price
    int24 constant STARTING_TICK = 0;

    // Test accounts
    address lp1 = makeAddr("lp1");
    address lp2 = makeAddr("lp2");

    address trader1 = makeAddr("trader1");
    address trader2 = makeAddr("trader2");

    function setUp() public {
        deployFreshManagerAndRouters();
        (
            Currency _token0,
            Currency _token1
        ) = deployMintAndApprove2Currencies();

        token0 = MockERC20(Currency.unwrap(_token0));
        token1 = MockERC20(Currency.unwrap(_token1));

        operator = makeAddr("operator");

        // Deploy mock price feed
        mockFeed = new MockPriceFeed("WBTC/USDT");
        mockPriceFeed = address(mockFeed);
        mockFeed.setLatestAnswer(INITIAL_PRICE);

        // Deploy the hook
        address hookAddress = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG |
                    Hooks.AFTER_ADD_LIQUIDITY_FLAG |
                    Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG |
                    Hooks.AFTER_REMOVE_LIQUIDITY_FLAG |
                    Hooks.AFTER_SWAP_FLAG |
                    Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG
            )
        );

        deployCodeTo(
            "PerpDexHook.sol",
            abi.encode(manager, mockPriceFeed, true, operator),
            hookAddress
        );
        hook = PerpDexHook(hookAddress);

        // Approve tokens for hook
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);

        // Initialize pool
        (key, ) = initPool(
            _token0,
            _token1,
            hook,
            3000,
            TickMath.getSqrtPriceAtTick(STARTING_TICK)
        );

        // Deal LP1 tokens
        deal(address(token0), lp1, LP1_AMOUNT);
        deal(address(token1), lp1, LP1_AMOUNT);

        vm.startPrank(lp1);

        // Approve tokens for router
        token0.approve(address(modifyLiquidityRouter), LP1_AMOUNT);
        token1.approve(address(modifyLiquidityRouter), LP1_AMOUNT);

        int256 liquidityDelta = int128(
            calculateLiquidity(STARTING_TICK, -60, 60, LP1_AMOUNT, LP1_AMOUNT)
        );

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager
            .ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: liquidityDelta,
                salt: bytes32(0)
            });

        modifyLiquidityRouter.modifyLiquidity(key, params, ZERO_BYTES);

        vm.stopPrank();

        // deal tokens for others
        deal(address(token0), trader1, 100e18);
        deal(address(token1), trader1, 100e18);
        deal(address(token0), trader2, 100e18);
        deal(address(token1), trader2, 100e18);
    }

    // Open positions, locks collateral and LP cant withdraw since he is alone in the pool
    function test_openPosition() public {
        uint256 marginAmount = 1e18;
        uint256 leverage = 2;
        bool isLong = true;
        address currencyBettingOn = address(token0);
        address marginCurrency = address(token0);

        uint256 initialLongOI = hook.longOpenInterest();
        uint256 initialShortOI = hook.shortOpenInterest();
        uint256 initialLockedUSD = hook.lockedUSDForCollateral();

        // Add collateral to the trader
        vm.prank(trader1);
        token0.transfer(address(this), marginAmount);
        hook.addCollateral(marginAmount, 0);

        // Open the position
        hook.openPosition(
            key,
            currencyBettingOn,
            marginAmount,
            marginCurrency,
            leverage,
            isLong
        );
        PerpDexHook.Position memory position = hook.getPositionDetails(
            address(this)
        );

        assertEq(position.trader, address(this), "Trader address mismatch");
        assertEq(
            position.marginAmount,
            marginAmount - marginAmount / 10000, // opening fee is 0.01%
            "Margin amount mismatch"
        );
        assertEq(position.leverage, leverage, "Leverage mismatch");
        assertEq(position.isLong, isLong, "Position type mismatch");
        assertEq(
            position.currencyBettingOn,
            currencyBettingOn,
            "Betting currency mismatch"
        );

        // Verify updated metrics
        uint256 updatedLongOI = hook.longOpenInterest();
        uint256 updatedShortOI = hook.shortOpenInterest();
        uint256 updatedLockedUSD = hook.lockedUSDForCollateral();

        assertTrue(updatedLongOI > initialLongOI, "Long OI should increase");
        assertEq(
            updatedShortOI,
            initialShortOI,
            "Short OI should remain unchanged"
        );
        assertTrue(
            updatedLockedUSD > initialLockedUSD,
            "Locked USD should increase"
        );

        // Verify collateral was deducted
        (uint256 fundedAmountCurrency0, , uint256 currency0Amount, ) = hook
            .traderCollateral(address(this));

        assertEq(
            fundedAmountCurrency0,
            marginAmount,
            "Trader's token0 collateral mismatch"
        );
        assertEq(currency0Amount, 0, "Trader's token0 collateral mismatch");

        // Attempt to withdraw liquidity as LP and expect a revert
        vm.startPrank(lp1);

        IPoolManager.ModifyLiquidityParams memory removeParams = IPoolManager
            .ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: -int256(
                    int128(
                        calculateLiquidity(
                            STARTING_TICK,
                            -60,
                            60,
                            LP1_AMOUNT,
                            LP1_AMOUNT
                        )
                    )
                ), // Remove all liquidity
                salt: bytes32(0)
            });

        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(key, removeParams, ZERO_BYTES);

        vm.stopPrank();
    }

    // This test showcases openPosition + closePosition, but price moved down and LPs got the margin profit from trader. LP also withdraws and takes profit.
    function test_priceDecreaseAndCollateralLoss() public {
        uint256 marginAmount = 1e18;
        uint256 leverage = 2;
        bool isLong = true;
        address currencyBettingOn = address(token0);
        address marginCurrency = address(token0);

        // Initial metrics
        uint256 initialLockedUSD = hook.lockedUSDForCollateral();
        uint256 initialLPFeesToken0 = hook
            .getLPFeesDetails()
            .traderPnLFeesCurrency0;

        // Add collateral to the trader
        vm.startPrank(trader1);
        token0.approve(address(hook), marginAmount);
        hook.addCollateral(marginAmount, 0);

        // Open the position
        hook.openPosition(
            key,
            currencyBettingOn,
            marginAmount,
            marginCurrency,
            leverage,
            isLong
        );

        // Simulate price decrease (mock feed value reduced)
        int256 newPrice = (7 * INITIAL_PRICE) / 10; // Price decreases by 30%
        mockFeed.setLatestAnswer(newPrice);

        // Close the position
        hook.closePosition(key);

        // Fetch trader collateral after position close
        (, , uint256 currency0Amount, ) = hook.traderCollateral(trader1);

        // Updated metrics
        uint256 updatedLockedUSD = hook.lockedUSDForCollateral();
        uint256 updatedLPFeesToken0 = hook
            .getLPFeesDetails()
            .traderPnLFeesCurrency0;

        // Assertions
        // Verify trader collateral has decreased
        assertTrue(
            currency0Amount < marginAmount,
            "Trader's collateral should decrease due to loss"
        );
        assertTrue(
            currency0Amount > 0,
            "Trader has remaining collateral after loss"
        );

        // Verify LP fees increased
        assertTrue(
            updatedLPFeesToken0 > initialLPFeesToken0,
            "LP fees in token0 should increase due to trader loss"
        );

        // Verify locked collateral decreased after position close
        assertTrue(
            updatedLockedUSD == initialLockedUSD,
            "Nothing should be locked"
        );

        // Remove collateral so LP can withdraw profits
        hook.removeCollateral();
        vm.stopPrank();

        vm.startPrank(address(hook));
        token0.approve(address(manager), type(uint256).max);
        token1.approve(address(manager), type(uint256).max);

        token0.allowance(address(hook), address(manager));
        token1.allowance(address(hook), address(manager));
        vm.stopPrank();

        vm.startPrank(lp1);

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager
            .ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: -int256(
                    int128(
                        calculateLiquidity(
                            STARTING_TICK,
                            -60,
                            60,
                            LP1_AMOUNT,
                            LP1_AMOUNT
                        )
                    )
                ), // Remove all liquidity
                salt: bytes32(0)
            });

        modifyLiquidityRouter.modifyLiquidity(key, params, abi.encode(lp1));

        vm.stopPrank();

        // Verify LP profits exceed their initial deposit amount
        assertTrue(
            token0.balanceOf(lp1) - LP1_AMOUNT > 0,
            "LP profit in token0 should exceed initial deposit"
        );
    }

    // This test showcases the same as the one above but the price moved up and the trader profited and took out the profits from LPs fees.
    // If fees didnt exist, in this design trader has to wait for fees, but i initially planned to create buffer capital which will be implemented post hookathon.
    function test_priceIncreaseAndTraderProfits() public {
        uint256 marginAmount = 1e18;
        uint256 leverage = 2;
        bool isLong = true;
        address currencyBettingOn = address(token0);
        address marginCurrency = address(token0);

        // Open and close trades from trader2 to generate fees for trader1 profitable trade.
        // This is only being done because i didnt implement buffer capital bcos of afterAddLiquidityReturnDelta struggle.
        vm.startPrank(trader2);
        token0.approve(address(hook), marginAmount);
        hook.addCollateral(marginAmount, 0);

        hook.openPosition(
            key,
            currencyBettingOn,
            marginAmount,
            marginCurrency,
            leverage,
            isLong
        );
        hook.closePosition(key);
        hook.openPosition(
            key,
            currencyBettingOn,
            marginAmount / 2,
            marginCurrency,
            leverage,
            isLong
        );
        hook.closePosition(key);
        vm.stopPrank();

        // Trader 1 will be profitable so this where the real test begins
        vm.startPrank(trader1);
        token0.approve(address(hook), marginAmount);
        hook.addCollateral(marginAmount, 0);

        // Open the position
        hook.openPosition(
            key,
            currencyBettingOn,
            marginAmount,
            marginCurrency,
            leverage,
            isLong
        );

        int256 newPrice = (1001 * INITIAL_PRICE) / 1000; // Price increases by 0.1%
        mockFeed.setLatestAnswer(newPrice);

        // Close the position
        hook.closePosition(key);

        // Fetch trader collateral after position close
        (, , uint256 currency0Amount, ) = hook.traderCollateral(trader1);

        assertTrue(
            currency0Amount > marginAmount,
            "Trader's collateral increased since they started"
        );

        hook.removeCollateral();

        assertTrue(
            token0.balanceOf(trader2) > marginAmount,
            "Trader withdrew profits successfully, profiting from LP fees"
        );

        vm.stopPrank();
    }

    // This test showcases how payments are made between longs and shorts
    function test_fundingPaymentsBetweenTraders() public {
        uint256 marginAmount = 1e18;
        uint256 leverage = 2;
        bool isLong = true;
        address currencyBettingOn = address(token0);
        address marginCurrency = address(token0);

        // open a short as trader2
        vm.startPrank(trader2);
        token0.approve(address(hook), marginAmount);
        hook.addCollateral(marginAmount, 0);

        hook.openPosition(
            key,
            currencyBettingOn,
            (9 * marginAmount) / 10, // commit 90% to have collateral for funding payments
            marginCurrency,
            leverage,
            false
        );
        vm.stopPrank();

        // Open a long as trader1
        vm.startPrank(trader1);
        token0.approve(address(hook), marginAmount);
        hook.addCollateral(marginAmount, 0);

        hook.openPosition(
            key,
            currencyBettingOn,
            marginAmount / 2, // half the position size to create imbalance
            marginCurrency,
            leverage,
            isLong
        );

        int256 newPrice = (1010 * INITIAL_PRICE) / 1000; // Price increases by 1%
        mockFeed.setLatestAnswer(newPrice);

        vm.stopPrank();

        (, , uint256 currency0AmountPreFundingT2, ) = hook.traderCollateral(
            trader2
        );
        (, , uint256 currency0AmountPreFundingT1, ) = hook.traderCollateral(
            trader1
        );

        // warp for funding payments
        vm.warp(block.timestamp + 8 hours);

        vm.startPrank(operator);
        hook.distributeFunding(key);

        (, , uint256 currency0AmountPostFundingT2, ) = hook.traderCollateral(
            trader2
        );
        (, , uint256 currency0AmountPostFundingT1, ) = hook.traderCollateral(
            trader1
        );

        assertTrue(
            currency0AmountPostFundingT2 < currency0AmountPreFundingT2,
            "Trader 2 had to pay funding"
        );
        assertTrue(
            currency0AmountPostFundingT1 > currency0AmountPreFundingT1,
            "Trader 1 had to receive funding"
        );
    }

    // This test showcases traders being liquidated due to price movement
    function test_liquidateTrader() public {
        uint256 marginAmount = 1e18;
        uint256 leverage = 2;
        bool isLong = true;
        address currencyBettingOn = address(token0);
        address marginCurrency = address(token0);

        // Open a long as trader1
        vm.startPrank(trader1);
        token0.approve(address(hook), marginAmount);
        hook.addCollateral(marginAmount, 0);

        hook.openPosition(
            key,
            currencyBettingOn,
            marginAmount,
            marginCurrency,
            leverage,
            isLong
        );

        int256 newPrice = INITIAL_PRICE / 10; // Price decreasess by 90%
        mockFeed.setLatestAnswer(newPrice);
        vm.stopPrank();

        vm.startPrank(operator);
        hook.liquidatePosition(trader1, key);

        PerpDexHook.Position memory position = hook.getPositionDetails(trader1);
        PerpDexHook.LPFees memory lpFees = hook.getLPFeesDetails();

        assertTrue(
            position.trader == address(0),
            "liquidiated, position doesnt exist anymore"
        );
        assertTrue(
            lpFees.leverageFeesCurrency0 +
                lpFees.traderPnLFeesCurrency0 +
                lpFees.tradingFeesCurrency0 ==
                marginAmount,
            "full margin is spread accross LP fees"
        );
    }

    // This test showcases how traders keeping realised profits locks up LPers
    function test_tradersKeepingRealisedProfits() public {}

    // HELPERS

    function calculateLiquidity(
        int24 currentTick,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) internal pure returns (uint128 liquidity) {
        // Compute sqrt price of lower and upper ticks
        uint160 sqrtPriceCurrentX96 = TickMath.getSqrtPriceAtTick(currentTick);
        uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(tickUpper);

        // Calculate liquidity using the Uniswap V3 formula
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceCurrentX96,
            sqrtPriceLowerX96,
            sqrtPriceUpperX96,
            amount0Desired,
            amount1Desired
        );
    }
}
