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

import "forge-std/console.sol";

contract PerpDexHookTest is Test, Deployers {
    PerpDexHook public hook;
    MockERC20 public token0;
    MockERC20 public token1;
    MockPriceFeed public mockFeed;

    address public operator;
    address public mockPriceFeed;

    uint256 constant LP1_AMOUNT = 1000 ether;
    int256 constant INITIAL_PRICE = 1000e18; // $1000 base price

    // Test accounts
    address lp1 = makeAddr("lp1");
    address lp2 = makeAddr("lp2");

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
                    Hooks.AFTER_SWAP_FLAG
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
        (key, ) = initPool(_token0, _token1, hook, 3000, SQRT_PRICE_1_1);

        // Deal LP1 tokens
        deal(address(token0), lp1, LP1_AMOUNT);
        deal(address(token1), lp1, LP1_AMOUNT);

        vm.startPrank(lp1);

        // Approve tokens for router
        token0.approve(address(modifyLiquidityRouter), LP1_AMOUNT);
        token1.approve(address(modifyLiquidityRouter), LP1_AMOUNT);

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager
            .ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: int256(LP1_AMOUNT),
                salt: bytes32(0)
            });

        modifyLiquidityRouter.modifyLiquidity(key, params, ZERO_BYTES);

        // // Add liquidity using the router
        // IPoolManager.ModifyLiquidityParams memory params = IPoolManager
        //     .ModifyLiquidityParams({
        //         tickLower: -60,
        //         tickUpper: 60,
        //         liquidityDelta: int256(LP1_AMOUNT), // Add liquidity
        //         salt: bytes32(0)
        //     });

        // modifyLiquidityRouter.modifyLiquidity(key, params, ZERO_BYTES);

        vm.stopPrank();
    }

    function test_afterAddLiquidity_simple() public {
        uint256 liquidityAmountToken0 = 1e18; 
        address lp = lp1;

        deal(address(token0), lp, liquidityAmountToken0);
        vm.startPrank(lp);
        token0.approve(address(modifyLiquidityRouter), liquidityAmountToken0);

        uint256 initialBufferCapital0 = hook.bufferCapitalCurrency0();
        uint256 initialHookBalanceToken0 = token0.balanceOf(address(hook));

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager
            .ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: int256(liquidityAmountToken0),
                salt: bytes32(0)
            });
        modifyLiquidityRouter.modifyLiquidity(key, params, ZERO_BYTES);

        uint256 updatedBufferCapital0 = hook.bufferCapitalCurrency0();
        uint256 updatedHookBalanceToken0 = token0.balanceOf(address(hook));

        assertTrue(
            updatedBufferCapital0 > initialBufferCapital0,
            "Buffer capital mismatch"
        );

        assertTrue(
            updatedHookBalanceToken0 > initialHookBalanceToken0,
            "Hook token balance mismatch"
        );

        vm.stopPrank();
    }

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
        vm.prank(lp1);
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
        assertEq(position.marginAmount, marginAmount, "Margin amount mismatch");
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
        vm.prank(lp1);
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

        // Simulate price decrease (mock feed value reduced)
        int256 newPrice = (7 * INITIAL_PRICE) / 10; // Price decreases by 30%
        mockFeed.setLatestAnswer(newPrice);

        // Fetch the position details before closing
        PerpDexHook.Position memory positionBeforeClose = hook
            .getPositionDetails(address(this));

        // Close the position
        hook.closePosition(address(this), key);

        // Fetch trader collateral after position close
        (, , uint256 currency0Amount, ) = hook.traderCollateral(address(this));

        // Updated metrics
        uint256 updatedLockedUSD = hook.lockedUSDForCollateral();
        uint256 updatedLPFeesToken0 = hook
            .getLPFeesDetails()
            .traderPnLFeesCurrency0;

        // Assertions
        // Verify trader collateral has decreased
        assertTrue(
            currency0Amount < positionBeforeClose.marginAmount,
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
    }
}

/*

3. funding payments between longs and shorts + liquidate if margin depleted
4. dynamic fees for utilization, imbalnance, etc
5. LPs earning fees in the mean time
6. simulate pool prices going up or down and positions surviving
7. simulate pool value USD going up or down in eth/uni example to showcase its in USD
8. showcase realised profits are locked in some fashion
9. show traders can withdraw profit successfully
10. show LPs cant withdraw when locked, then show traders closign and LPs being able to withdraw

*/
