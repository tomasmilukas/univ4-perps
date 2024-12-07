// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AggregatorV3Interface} from "chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {LiquidityAmounts} from "lib/v4-periphery/lib/v4-core/test/utils/LiquidityAmounts.sol";

import "solidity-stringutils/src/strings.sol";

// REMOVE BEFORE SUBMISSION
import "forge-std/console.sol";

contract PerpDexHook is BaseHook {
    using strings for *;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    uint256 public constant MAX_LEVERAGE = 5;
    uint256 public constant LIQUIDATION_THRESHOLD = 80; // 80%
    uint256 public constant BASE_LEVERAGE_RATE = 1e15;

    uint256 public constant FUNDING_INTERVAL = 8 hours;
    uint256 public lastFundingTime;
    uint256 public constant BASE_FUNDING_RATE = 1e14; // 0.01% base rate
    uint256 public constant MAX_FUNDING_RATE = 2e15; // 0.2% max rate

    // offchain bot that triggers funding and liquidations
    address public immutable operator;

    address public currency0Address;
    address public currency1Address;

    Currency public currency0;
    Currency public currency1;

    struct Position {
        address trader;
        uint256 sizeUSD;
        uint256 marginAmount;
        address marginCurrency;
        uint256 leverage;
        address currencyBettingOn;
        uint256 entryPriceUSD;
        bool isLong;
        uint256 timestamp;
    }

    struct Collateral {
        uint256 fundedAmountCurrency0;
        uint256 fundedAmountCurrency1;
        uint256 currency0Amount;
        uint256 currency1Amount;
    }

    struct FeeShare {
        uint256 token0Deposited;
        uint256 token1Deposited;
    }

    // LP fees are for LPs earning for providing capital. If traders are in profit, we deduct from these fees and buffer capital
    struct LPFees {
        // Fees for LPs to earn from renting leverage
        uint256 leverageFeesCurrency0;
        uint256 leverageFeesCurrency1;
        // Fees for LPs from traders losing money
        uint256 traderPnLFeesCurrency0;
        uint256 traderPnLFeesCurrency1;
        // Fees for opening and closing positions
        uint256 tradingFeesCurrency0;
        uint256 tradingFeesCurrency1;
    }

    // keeping track of traders
    address[] public activeTraders;
    mapping(address => uint256) public traderIndex;

    // Only one position per trader
    mapping(address => Position) public livePositions;
    mapping(address => Collateral) public traderCollateral;

    // Track deposits to share fees when withdrawing
    mapping(address => FeeShare) public shares;

    uint256 public totalCurrency0Deposited;
    uint256 public totalCurrency1Deposited;

    LPFees public lpFees;

    // Underlying reserves in Univ4 pool to calculate total liquidity (USD denominated) for providing collateral
    uint256 public underlyingLiquidityAmountCurrency0;
    uint256 public underlyingLiquidityAmountCurrency1;

    // Locked collateral in underlying pool for leveraged traders
    uint256 public lockedUSDForCollateral;

    // OI recorded in USD
    uint256 public longOpenInterest;
    uint256 public shortOpenInterest;

    // Was planning to implement buffer capital but didnt figure out the afterAddLiquidity delta on time, will do it after hookathon.
    // // LPs set aside 10% of their position as buffer capital for trader payouts so we avoid rebalancing LP positions
    // uint256 public bufferCapitalCurrency0;
    // uint256 public bufferCapitalCurrency1;

    // Chainlink specifics
    AggregatorV3Interface public priceFeed;
    bool public isBaseCurrency0;

    constructor(
        IPoolManager _poolManager,
        address _priceFeedAddress,
        bool _isBaseCurrency0,
        address _operator
    ) BaseHook(_poolManager) {
        priceFeed = AggregatorV3Interface(_priceFeedAddress);
        isBaseCurrency0 = _isBaseCurrency0;
        operator = _operator;

        lpFees = LPFees({
            leverageFeesCurrency0: 0,
            leverageFeesCurrency1: 0,
            traderPnLFeesCurrency0: 0,
            traderPnLFeesCurrency1: 0,
            tradingFeesCurrency0: 0,
            tradingFeesCurrency1: 0
        });
    }

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: true,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: true,
                beforeRemoveLiquidity: true,
                afterRemoveLiquidity: true,
                beforeSwap: false,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: true,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    // Core hook functions
    function beforeInitialize(
        address sender,
        PoolKey calldata key,
        uint160 sqrtPriceX96
    ) external override returns (bytes4) {
        currency0Address = Currency.unwrap(key.currency0);
        currency1Address = Currency.unwrap(key.currency1);

        currency0 = key.currency0;
        currency1 = key.currency1;

        // Validate provided price feed direction
        address expectedCurrency = isBaseCurrency0
            ? currency0Address
            : currency1Address;

        // require(
        //     validateFeed(expectedCurrency),
        //     "Price feed mismatch with token"
        // );

        // Initialize pool parameters
        return this.beforeInitialize.selector;
    }

    function afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata
    ) external override returns (bytes4, BalanceDelta) {
        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(key.toId());

        (uint256 amount0, uint256 amount1) = LiquidityAmounts
            .getAmountsForLiquidity(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(params.tickLower),
                TickMath.getSqrtPriceAtTick(params.tickUpper),
                uint128(int128(params.liquidityDelta))
            );

        totalCurrency0Deposited += uint128(amount0);
        totalCurrency1Deposited += uint128(amount1);

        shares[sender].token0Deposited = uint128(amount0);
        shares[sender].token1Deposited = uint128(amount1);

        underlyingLiquidityAmountCurrency0 += uint128(amount0);
        underlyingLiquidityAmountCurrency1 += uint128(amount1);

        return (this.afterAddLiquidity.selector, toBalanceDelta(0, 0));
    }

    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata
    ) external override returns (bytes4) {
        (, , uint256 totalPoolValueUSD) = getUnderlyingPoolTokenValuesUSD(
            key,
            underlyingLiquidityAmountCurrency0,
            underlyingLiquidityAmountCurrency1
        );

        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(key.toId());

        // amounts to be removed
        (uint256 amount0, uint256 amount1) = LiquidityAmounts
            .getAmountsForLiquidity(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(params.tickLower),
                TickMath.getSqrtPriceAtTick(params.tickUpper),
                uint128(int128(-params.liquidityDelta))
            );

        uint256 currPrice0 = getCurrentPrice(key, currency0Address);
        uint256 currPrice1 = getCurrentPrice(key, currency1Address);

        require(
            lockedUSDForCollateral + getNetOIExposure() <=
                totalPoolValueUSD -
                    (currPrice0 * amount0 + currPrice1 * amount1),
            "All liquidity is locked, must wait for traders to close positions or other LPers to join."
        );

        return this.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta1,
        BalanceDelta delta2,
        bytes calldata data
    ) external override returns (bytes4, BalanceDelta) {
        FeeShare memory share = shares[sender];
        LPFees storage fees = lpFees;

        uint256 totalFees0 = fees.leverageFeesCurrency0 +
            fees.traderPnLFeesCurrency0 +
            fees.tradingFeesCurrency0;
        uint256 totalFees1 = fees.leverageFeesCurrency1 +
            fees.traderPnLFeesCurrency1 +
            fees.tradingFeesCurrency1;

        console.log(
            "MEOW",
            IERC20Metadata(currency0Address).balanceOf(address(this))
        );

        if (
            (totalFees0 * share.token0Deposited) / totalCurrency0Deposited > 0
        ) {
            console.log(
                "DIVISION HOW MUCH TO TRANSFER:",
                (totalFees0 * share.token0Deposited) / totalCurrency0Deposited
            );
            IERC20Metadata(currency0Address).transfer(
                abi.decode(data, (address)),
                ((totalFees0 * share.token0Deposited) / totalCurrency0Deposited)
            );
        }

        if (
            (totalFees1 * share.token1Deposited) / totalCurrency1Deposited > 0
        ) {
            IERC20Metadata(currency0Address).transfer(
                abi.decode(data, (address)),
                (totalFees1 * share.token1Deposited) / totalCurrency1Deposited
            );
        }

        // Update fees with inline calculations
        fees.leverageFeesCurrency0 =
            fees.leverageFeesCurrency0 -
            ((fees.leverageFeesCurrency0 * share.token0Deposited) /
                totalCurrency0Deposited);
        fees.leverageFeesCurrency1 =
            fees.leverageFeesCurrency1 -
            ((fees.leverageFeesCurrency1 * share.token1Deposited) /
                totalCurrency1Deposited);
        fees.traderPnLFeesCurrency0 =
            fees.traderPnLFeesCurrency0 -
            ((fees.traderPnLFeesCurrency0 * share.token0Deposited) /
                totalCurrency0Deposited);
        fees.traderPnLFeesCurrency1 =
            fees.traderPnLFeesCurrency1 -
            ((fees.traderPnLFeesCurrency1 * share.token1Deposited) /
                totalCurrency1Deposited);
        fees.tradingFeesCurrency0 =
            fees.tradingFeesCurrency0 -
            ((fees.tradingFeesCurrency0 * share.token0Deposited) /
                totalCurrency0Deposited);
        fees.tradingFeesCurrency1 =
            fees.tradingFeesCurrency1 -
            ((fees.tradingFeesCurrency1 * share.token1Deposited) /
                totalCurrency1Deposited);

        delete shares[sender];

        return (this.afterRemoveLiquidity.selector, delta1);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override returns (bytes4, int128) {
        // Update our tracked reserves based on swap delta
        if (delta.amount0() > 0) {
            underlyingLiquidityAmountCurrency0 += uint128(delta.amount0());
        } else {
            underlyingLiquidityAmountCurrency0 -= uint128(-delta.amount0());
        }

        if (delta.amount1() > 0) {
            underlyingLiquidityAmountCurrency1 += uint128(delta.amount1());
        } else {
            underlyingLiquidityAmountCurrency1 -= uint128(-delta.amount1());
        }

        return (this.afterRemoveLiquidity.selector, 0);
    }

    function addCollateral(
        uint256 currency0Amount,
        uint256 currency1Amount
    ) external payable {
        if (currency0Amount > 0) {
            require(
                IERC20Metadata(currency0Address).transferFrom(
                    msg.sender,
                    address(this),
                    currency0Amount
                ),
                "Transfer failed"
            );
            traderCollateral[msg.sender].currency0Amount += currency0Amount;
            traderCollateral[msg.sender]
                .fundedAmountCurrency0 += currency0Amount;
        }

        if (currency1Amount > 0) {
            require(
                IERC20Metadata(currency1Address).transferFrom(
                    msg.sender,
                    address(this),
                    currency1Amount
                ),
                "Transfer failed"
            );
            traderCollateral[msg.sender].currency1Amount += currency1Amount;
            traderCollateral[msg.sender]
                .fundedAmountCurrency1 += currency1Amount;
        }
    }

    function removeCollateral() external {
        Collateral memory collateral = traderCollateral[msg.sender];
        LPFees storage fees = lpFees;

        if (collateral.fundedAmountCurrency0 > collateral.currency0Amount) {
            IERC20Metadata(currency0Address).transfer(
                msg.sender,
                uint256(collateral.currency0Amount)
            );

            collateral.currency0Amount = 0;
        }

        if (collateral.fundedAmountCurrency1 > collateral.currency1Amount) {
            IERC20Metadata(currency1Address).transfer(
                msg.sender,
                uint256(collateral.currency1Amount)
            );

            collateral.currency1Amount = 0;
        }

        // everything has been paid out
        if (
            collateral.currency0Amount == 0 || collateral.currency1Amount == 0
        ) {
            delete traderCollateral[msg.sender];

            return;
        }

        // payout capital available to trader
        uint256 totalPayoutCapitalCurrency0 = fees.traderPnLFeesCurrency0 +
            fees.leverageFeesCurrency0 +
            fees.tradingFeesCurrency0;

        console.log(
            "REMOVE COLLATERAL INFO:",
            totalPayoutCapitalCurrency0,
            IERC20Metadata(currency0Address).balanceOf(address(this)),
            collateral.currency0Amount
        );

        require(
            collateral.currency0Amount <
                totalPayoutCapitalCurrency0 +
                    IERC20Metadata(currency0Address).balanceOf(address(this)),
            "Not enough capital in pool to pay out. Wait for fee accrual"
        );

        uint256 traderProfit0 = collateral.currency0Amount -
            collateral.fundedAmountCurrency0;

        if (traderProfit0 > 0) {
            if (traderProfit0 > fees.traderPnLFeesCurrency0) {
                fees.traderPnLFeesCurrency0 = 0;
                traderProfit0 -= fees.traderPnLFeesCurrency0;
            }

            if (traderProfit0 > fees.leverageFeesCurrency0) {
                fees.leverageFeesCurrency0 = 0;
                traderProfit0 -= fees.leverageFeesCurrency0;
            }

            if (traderProfit0 > fees.tradingFeesCurrency0) {
                fees.tradingFeesCurrency0 = 0;
                traderProfit0 -= fees.tradingFeesCurrency0;
            }
        }

        IERC20Metadata(currency0Address).transfer(
            msg.sender,
            uint256(collateral.currency0Amount)
        );

        // Handle currency 1

        uint256 totalPayoutCapitalCurrency1 = fees.traderPnLFeesCurrency1 +
            fees.leverageFeesCurrency1 +
            fees.tradingFeesCurrency1;

        require(
            collateral.currency1Amount > totalPayoutCapitalCurrency1,
            "Not enough capital in pool to pay out. Wait for fee accrual"
        );

        uint256 traderProfit1 = collateral.currency1Amount -
            collateral.fundedAmountCurrency1;

        if (traderProfit1 > 0) {
            if (traderProfit1 > fees.traderPnLFeesCurrency1) {
                fees.traderPnLFeesCurrency1 = 0;
                traderProfit1 -= fees.traderPnLFeesCurrency1;
            }

            if (traderProfit1 > fees.leverageFeesCurrency1) {
                fees.leverageFeesCurrency1 = 0;
                traderProfit1 -= fees.leverageFeesCurrency1;
            }

            if (traderProfit1 > fees.tradingFeesCurrency1) {
                fees.tradingFeesCurrency1 = 0;
                traderProfit1 -= fees.tradingFeesCurrency1;
            }
        }

        IERC20Metadata(currency0Address).transfer(
            msg.sender,
            uint256(collateral.currency0Amount)
        );

        delete traderCollateral[msg.sender];
    }

    // Trading functions
    function openPosition(
        PoolKey calldata key,
        address currencyBettingOn,
        uint256 marginAmount,
        address marginCurrency,
        uint256 leverage,
        bool isLong
    ) external {
        require(leverage <= MAX_LEVERAGE, "Leverage too high");
        require(
            livePositions[msg.sender].trader == address(0),
            "A position already exists for this trader"
        );

        require(
            (marginCurrency == currency0Address &&
                traderCollateral[msg.sender].currency0Amount >= marginAmount) ||
                (marginCurrency == currency1Address &&
                    traderCollateral[msg.sender].currency1Amount >=
                    marginAmount),
            "Must fund collateral to open position"
        );

        require(
            currencyBettingOn != currency0Address ||
                currencyBettingOn != currency1Address,
            "Must bet on either currency0 or currency1"
        );
        require(
            marginCurrency == currency0Address ||
                marginCurrency == currency1Address,
            "Insufficient currency0 or curency1 trader collateral"
        );

        require(
            (marginCurrency == currency0Address &&
                traderCollateral[msg.sender].currency0Amount >= marginAmount) ||
                (marginCurrency == currency1Address &&
                    traderCollateral[msg.sender].currency1Amount >=
                    marginAmount),
            "Insufficient currency0 or curency1 trader collateral"
        );

        uint256 currencyPrice = getCurrentPrice(key, marginCurrency);

        uint256 openingFee = marginAmount / 10000;
        if (marginCurrency == currency0Address) {
            lpFees.tradingFeesCurrency0 += openingFee;
        } else {
            lpFees.tradingFeesCurrency1 += openingFee;
        }

        uint256 effectiveMargin = (marginAmount - openingFee);

        // USD denominated position size
        uint256 positionSize = currencyPrice * effectiveMargin * leverage;

        (, , uint256 totalPoolValueUSD) = getUnderlyingPoolTokenValuesUSD(
            key,
            underlyingLiquidityAmountCurrency0,
            underlyingLiquidityAmountCurrency1
        );

        require(
            lockedUSDForCollateral + positionSize < totalPoolValueUSD,
            "Liquidity capacity has been reached. Can't open new positions."
        );

        // Update position tracking
        livePositions[msg.sender] = Position({
            trader: msg.sender,
            sizeUSD: positionSize,
            marginAmount: effectiveMargin,
            marginCurrency: marginCurrency,
            currencyBettingOn: currencyBettingOn,
            leverage: leverage,
            entryPriceUSD: currencyPrice,
            isLong: isLong,
            timestamp: block.timestamp
        });

        if (isLong) {
            longOpenInterest += positionSize;
        } else {
            shortOpenInterest += positionSize;
        }

        if (marginCurrency == currency0Address) {
            traderCollateral[msg.sender].currency0Amount -= marginAmount;
        } else {
            traderCollateral[msg.sender].currency1Amount -= marginAmount;
        }

        lockedUSDForCollateral += positionSize;

        emit PositionOpened(
            msg.sender,
            marginCurrency,
            marginAmount,
            currencyBettingOn,
            currencyPrice,
            positionSize,
            leverage,
            isLong
        );
    }

    function closePosition(PoolKey calldata key) external {
        LPFees storage fees = lpFees;
        Position memory position = livePositions[msg.sender];

        int256 currency0Price = int256(getCurrentPrice(key, currency0Address));
        int256 currency1Price = int256(getCurrentPrice(key, currency1Address));

        int256 entryPrice = int256(position.entryPriceUSD);
        int256 exitPrice = position.currencyBettingOn == currency0Address
            ? currency0Price
            : currency1Price;

        int256 profit;

        bool marginCurrencyIs0 = currency0Address == position.marginCurrency
            ? true
            : false;

        // Longs logic for payouts
        if (position.isLong) {
            int256 priceShift = exitPrice - entryPrice;

            profit = (priceShift * int256(position.sizeUSD)) / entryPrice;
        } else {
            int256 priceShift = entryPrice - exitPrice;
            profit = (priceShift * int256(position.sizeUSD)) / entryPrice;
        }

        if (profit > 0) {
            // Add collateral back + increase collateral with profits. Also deduct trader payout from buffer.
            if (marginCurrencyIs0) {
                uint256 currency0ToPayOut = uint256(profit / currency0Price);

                traderCollateral[msg.sender].currency0Amount +=
                    position.marginAmount +
                    currency0ToPayOut;
            } else {
                uint256 currency1ToPayOut = uint256(profit / currency1Price);

                traderCollateral[msg.sender].currency1Amount +=
                    position.marginAmount +
                    currency1ToPayOut;
            }
        }

        if (profit < 0) {
            // Add back remaining collateral and add losses to pool fees.
            if (marginCurrencyIs0) {
                uint256 currency0ToTakeOut = uint256(-profit / currency0Price);

                traderCollateral[msg.sender].currency0Amount +=
                    position.marginAmount -
                    currency0ToTakeOut;

                fees.traderPnLFeesCurrency0 += currency0ToTakeOut;
            } else {
                uint256 currency1ToTakeOut = uint256(-profit / currency1Price);

                traderCollateral[msg.sender].currency1Amount +=
                    position.marginAmount -
                    currency1ToTakeOut;

                fees.traderPnLFeesCurrency1 += currency1ToTakeOut;
            }
        }

        if (position.isLong) {
            longOpenInterest -= position.sizeUSD;
        } else {
            shortOpenInterest -= position.sizeUSD;
        }

        lockedUSDForCollateral -= position.sizeUSD;

        delete livePositions[msg.sender];

        emit PositionClosed(
            msg.sender,
            position.isLong,
            position.currencyBettingOn,
            position.entryPriceUSD,
            uint256(exitPrice),
            profit
        );
    }

    function liquidatePosition(
        address traderAddress,
        PoolKey calldata key
    ) public {
        require(msg.sender == operator, "Only operator");

        Position memory position = livePositions[traderAddress];
        require(position.trader != address(0), "Position doesn't exist");

        uint256 currency0Price = getCurrentPrice(key, currency0Address);
        uint256 currency1Price = getCurrentPrice(key, currency1Address);

        int256 entryPrice = int256(position.entryPriceUSD);
        int256 exitPrice = position.currencyBettingOn == currency0Address
            ? int256(currency0Price)
            : int256(currency1Price);

        int256 profit;

        if (position.isLong) {
            int256 priceShift = exitPrice - entryPrice;
            profit = (priceShift * int256(position.sizeUSD)) / entryPrice;
        } else {
            int256 priceShift = entryPrice - exitPrice;
            profit = (priceShift * int256(position.sizeUSD)) / entryPrice;
        }

        // Check if liquidatable (loss > 80% of margin)
        require(
            profit <=
                -int256((position.marginAmount * LIQUIDATION_THRESHOLD) / 100),
            "Not liquidatable"
        );

        LPFees storage fees = lpFees;

        // Full margin goes to LP fees
        if (position.marginCurrency == currency0Address) {
            fees.traderPnLFeesCurrency0 += position.marginAmount;
        } else {
            fees.traderPnLFeesCurrency1 += position.marginAmount;
        }

        if (position.isLong) {
            longOpenInterest -= position.sizeUSD;
        } else {
            shortOpenInterest -= position.sizeUSD;
        }

        delete livePositions[traderAddress];
        removeTrader(traderAddress);

        emit PositionLiquidated(
            traderAddress,
            position.marginAmount,
            position.isLong,
            uint256(exitPrice),
            profit
        );
    }

    function removeTrader(address trader) internal {
        uint256 index = traderIndex[trader];
        uint256 lastIndex = activeTraders.length - 1;

        if (index != lastIndex) {
            address lastTrader = activeTraders[lastIndex];
            activeTraders[index] = lastTrader;
            traderIndex[lastTrader] = index;
        }

        activeTraders.pop();
        delete traderIndex[trader];
    }

    function distributeFunding(PoolKey calldata key) external {
        require(
            block.timestamp >= lastFundingTime + FUNDING_INTERVAL,
            "Too early"
        );
        require(
            msg.sender == operator,
            "Only operator off chain bot can call this fn"
        );

        uint256 fundingRate = calculateFundingRate();
        bool longsPayShorts = longOpenInterest > shortOpenInterest;

        // Track total fees
        uint256 totalFeesCurrency0;
        uint256 totalFeesCurrency1;
        LPFees storage fees = lpFees;

        uint256 currentPriceCurr0 = getCurrentPrice(key, currency0Address);
        uint256 currentPriceCurr1 = getCurrentPrice(key, currency1Address);

        // Collect fees from paying side
        for (uint i = 0; i < activeTraders.length; i++) {
            address trader = activeTraders[i];
            Position storage pos = livePositions[trader];
            if (pos.trader == address(0)) continue;
            uint256 fundingFee = (pos.sizeUSD * fundingRate) / 1e18;

            if (pos.isLong == longsPayShorts) {
                // Convert to tokens and deduct from their margin currency
                if (pos.marginCurrency == currency0Address) {
                    uint256 feeInToken = fundingFee / currentPriceCurr0;
                    if (traderCollateral[trader].currency0Amount < feeInToken) {
                        liquidatePosition(trader, key);
                        continue;
                    }
                    traderCollateral[trader].currency0Amount -= feeInToken;
                    totalFeesCurrency0 += feeInToken;
                } else {
                    uint256 feeInToken = fundingFee / currentPriceCurr1;
                    if (traderCollateral[trader].currency1Amount < feeInToken) {
                        liquidatePosition(trader, key);
                        continue;
                    }
                    traderCollateral[trader].currency1Amount -= feeInToken;
                    totalFeesCurrency1 += feeInToken;
                }
            }
        }

        // Take 5% LP fee
        uint256 lpFee0 = totalFeesCurrency0 / 20;
        uint256 lpFee1 = totalFeesCurrency1 / 20;
        fees.traderPnLFeesCurrency0 += lpFee0;
        fees.traderPnLFeesCurrency1 += lpFee1;
        totalFeesCurrency0 -= lpFee0;
        totalFeesCurrency1 -= lpFee1;

        // Distribute remaining fees to receiving side based only on position size
        uint256 receivingSideInterest = longsPayShorts
            ? shortOpenInterest
            : longOpenInterest;
        if (receivingSideInterest > 0) {
            for (uint i = 0; i < activeTraders.length; i++) {
                address trader = activeTraders[i];
                Position storage pos = livePositions[trader];
                if (pos.trader == address(0)) continue;

                if (pos.isLong != longsPayShorts) {
                    // Distribute proportional share of both currencies regardless of margin currency
                    uint256 share = (pos.sizeUSD * 1e18) /
                        receivingSideInterest;
                    uint256 reward0 = (totalFeesCurrency0 * share) / 1e18;
                    uint256 reward1 = (totalFeesCurrency1 * share) / 1e18;

                    // Add to their respective collateral balances
                    traderCollateral[trader].currency0Amount += reward0;
                    traderCollateral[trader].currency1Amount += reward1;
                }
            }
        } else {
            // No counterparties, redirect all fees to LPs
            fees.traderPnLFeesCurrency0 += totalFeesCurrency0;
            fees.traderPnLFeesCurrency1 += totalFeesCurrency1;
        }

        lastFundingTime = block.timestamp;
        emit FundingPaid(
            longsPayShorts,
            fundingRate,
            totalFeesCurrency0,
            totalFeesCurrency1
        );
    }

    //helpers

    function getUnderlyingPoolTokenValuesUSD(
        PoolKey calldata key,
        uint256 amountCurrency0,
        uint256 amountCurrency1
    ) public view returns (uint256, uint256, uint256) {
        uint256 currency0Price = getCurrentPrice(key, currency0Address);
        uint256 currency1Price = getCurrentPrice(key, currency1Address);

        uint256 currency0Value = currency0Price * amountCurrency0;
        uint256 currency1Value = currency1Price * amountCurrency1;

        return (
            currency0Value,
            currency1Value,
            currency0Value + currency1Value // total pool value in USD at this moment
        );
    }

    function getCurrentPrice(
        PoolKey calldata key,
        address currencyAddress
    ) internal view returns (uint256) {
        (, int256 chainlinkBasePrice, , , ) = priceFeed.latestRoundData();
        require(chainlinkBasePrice > 0, "Invalid base price from Chainlink");

        if (
            (isBaseCurrency0 && currencyAddress == currency0Address) ||
            (!isBaseCurrency0 && currencyAddress == currency1Address)
        ) {
            return uint256(chainlinkBasePrice);
        }

        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(key.toId());
        uint256 poolPrice = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) >>
            192;

        if (isBaseCurrency0) {
            // Chainlink base is currency0 (ETH)
            if (currencyAddress == currency1Address) {
                // Pool is Base/Quote (ETH/PEPE), poolPrice = PEPE per ETH
                // PEPE/USD = ETH/USD / (PEPE/ETH)
                return uint256(chainlinkBasePrice) / poolPrice;
            }
        } else {
            // Chainlink base is currency1 (PEPE)
            if (currencyAddress == currency0Address) {
                // Pool is Quote/Base (PEPE/ETH), poolPrice = ETH per PEPE
                // PEPE/USD = ETH/USD * (ETH/PEPE)
                return uint256(chainlinkBasePrice) * poolPrice;
            }
        }

        revert("Invalid currency address");
    }

    function getLeverageRate(
        PoolKey calldata key,
        address traderAddress
    ) public view returns (uint256) {
        return
            BASE_LEVERAGE_RATE *
            livePositions[traderAddress].leverage *
            getUtilizationRate(key);
    }

    function getUtilizationRate(
        PoolKey calldata key
    ) public view returns (uint256) {
        (, , uint256 totalPoolValueUSD) = getUnderlyingPoolTokenValuesUSD(
            key,
            underlyingLiquidityAmountCurrency0,
            underlyingLiquidityAmountCurrency1
        );

        return
            (lockedUSDForCollateral + getNetOIExposure()) / totalPoolValueUSD;
    }

    function calculateFundingRate() public view returns (uint256) {
        if (longOpenInterest == 0 || shortOpenInterest == 0) {
            return MAX_FUNDING_RATE;
        }

        uint256 maxInterest = longOpenInterest > shortOpenInterest
            ? longOpenInterest
            : shortOpenInterest;
        uint256 minInterest = longOpenInterest > shortOpenInterest
            ? shortOpenInterest
            : longOpenInterest;

        uint256 imbalanceRatio = ((maxInterest - minInterest) * 1e18) /
            maxInterest;

        uint256 additionalRate = ((MAX_FUNDING_RATE - BASE_FUNDING_RATE) *
            imbalanceRatio) / 1e18;

        return BASE_FUNDING_RATE + additionalRate;
    }

    function getNetOIExposure() public view returns (uint256) {
        return
            longOpenInterest > shortOpenInterest
                ? longOpenInterest - shortOpenInterest
                : shortOpenInterest - longOpenInterest;
    }

    function validateFeed(address tokenAddress) internal view returns (bool) {
        try priceFeed.description() returns (string memory desc) {
            string memory tokenSymbol = IERC20Metadata(tokenAddress).symbol();

            // Convert strings to slices
            strings.slice memory descSlice = desc.toSlice();
            strings.slice memory delimiter = "/".toSlice();
            strings.slice memory symbolSlice = tokenSymbol.toSlice();

            strings.slice memory baseSlice = descSlice.split(delimiter);
            strings.slice memory quoteSlice = descSlice;

            return
                symbolSlice.equals(baseSlice) || symbolSlice.equals(quoteSlice);
        } catch {
            return false;
        }
    }

    function getPositionDetails(
        address trader
    ) public view returns (Position memory) {
        Position memory position = livePositions[trader];
        return position;
    }

    function getLPFeesDetails() public view returns (LPFees memory) {
        return lpFees;
    }

    event PositionOpened(
        address indexed trader,
        address marginCurrency,
        uint256 marginAmount,
        address currencyBettingOn,
        uint256 entryPrice,
        uint256 size,
        uint256 leverage,
        bool isLong
    );
    event PositionClosed(
        address indexed trader,
        bool isLong,
        address currencyBettingOn,
        uint256 entryPrice,
        uint256 exitPrice,
        int256 profit
    );
    event PositionLiquidated(
        address indexed trader,
        uint256 marginAmount,
        bool isLong,
        uint256 currentPrice,
        int256 pnlUSD
    );
    event FundingPaid(
        bool longsPayShorts,
        uint256 fundingRate,
        uint256 totalFeesCurrency0,
        uint256 totalFeesCurrency1
    );
}
