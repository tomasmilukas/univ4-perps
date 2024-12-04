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

import "solidity-stringutils/src/strings.sol";

contract PerpDexHook is BaseHook {
    using strings for *;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    uint256 public constant MAX_LEVERAGE = 5;
    uint256 public constant LIQUIDATION_THRESHOLD = 80; // 80%
    uint256 public constant BASE_LEVERAGE_RATE = 1e15; // 0.1% base leverage rate

    address public currency0Address;
    address public currency1Address;

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

    // Only one position per trader
    mapping(address => Position) public livePositions;
    mapping(address => Collateral) public traderCollateral;

    // Underlying reserves in Univ4 pool to calculate total liquidity (USD denominated) for providing collateral
    uint256 public underlyingLiquidityAmountCurrency0;
    uint256 public underlyingLiquidityAmountCurrency1;

    // Locked collateral in underlying pool for leveraged traders
    uint256 public lockedUSDForCollateral;

    // Locked currencies for traders realise profits. Trader realise profits in pools currency, not USD.
    uint256 public traderPayOutRealisedCurrency0;
    uint256 public traderPayOutRealisedCurrency1;

    // OI recorded in USD
    uint256 public longOpenInterest;
    uint256 public shortOpenInterest;

    // LPs set aside 10% of their position as buffer capital for trader payouts so we avoid rebalancing LP positions
    uint256 public bufferCapitalCurrency0;
    uint256 public bufferCapitalCurrency1;

    // Fees for traders to divide between each other for imbalance
    uint256 public fundingFeesCurrency0;
    uint256 public fundingFeesCurrency1;

    // Fees for LPs to earn from renting leverage
    uint256 public leverageFeesCurrency0;
    uint256 public leverageFeesCurrency1;

    // Fees for LPs from traders losing/making money. Can be negative, aka LPs pay out fees.
    uint256 public traderPnLFeesCurrency0;
    uint256 public traderPnLFeesCurrency1;

    // Chainlink specifics
    AggregatorV3Interface public priceFeed;
    uint8 private priceDecimals;
    bool public isBaseCurrency0;

    constructor(
        IPoolManager _poolManager,
        address _priceFeedAddress,
        bool _isBaseCurrency0
    ) BaseHook(_poolManager) {
        priceFeed = AggregatorV3Interface(_priceFeedAddress);
        priceDecimals = priceFeed.decimals();
        isBaseCurrency0 = _isBaseCurrency0;
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
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: true,
                beforeSwap: false,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    // Core hook functions
    function beforeInitialize(
        address sender,
        PoolKey calldata key,
        uint160 sqrtPriceX96
    ) external override returns (bytes4) {
        longOpenInterest = 0;
        shortOpenInterest = 0;
        fundingFeesCurrency0 = 0;
        fundingFeesCurrency1 = 0;

        currency0Address = Currency.unwrap(key.currency0);
        currency1Address = Currency.unwrap(key.currency1);

        // Validate provided price feed direction
        address expectedCurrency = isBaseCurrency0
            ? currency0Address
            : currency1Address;

        require(
            validateFeed(expectedCurrency),
            "Price feed mismatch with token"
        );

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
        if (params.liquidityDelta <= 0) {
            return (this.afterAddLiquidity.selector, toBalanceDelta(0, 0));
        }

        int128 amount0 = delta.amount0();
        int128 amount1 = delta.amount1();

        underlyingLiquidityAmountCurrency0 += uint128(amount0);
        underlyingLiquidityAmountCurrency1 += uint128(amount1);

        int128 buffer0 = (amount0 * 10) / 100;
        int128 buffer1 = (amount1 * 10) / 100;

        return (
            this.afterAddLiquidity.selector,
            toBalanceDelta(buffer0, buffer1)
        );
    }

    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta1,
        BalanceDelta delta2,
        bytes calldata
    ) external override returns (bytes4, BalanceDelta) {
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
                    uint256(currency0Amount)
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
                    uint256(currency1Amount)
                ),
                "Transfer failed"
            );
            traderCollateral[msg.sender].currency1Amount += currency1Amount;
            traderCollateral[msg.sender]
                .fundedAmountCurrency1 += currency1Amount;
        }
    }

    function removeCollateral() external {
        // payout capital available to trader
        uint256 totalPayoutCapitalCurrency0 = bufferCapitalCurrency0 +
            traderPnLFeesCurrency0 +
            leverageFeesCurrency0;

        require(
            traderCollateral[msg.sender].currency0Amount >
                totalPayoutCapitalCurrency0,
            "Not enough capital in pool to pay out. Wait for fee accrual"
        );

        uint256 traderProfit0 = traderCollateral[msg.sender].currency0Amount -
            traderCollateral[msg.sender].fundedAmountCurrency0;

        if (traderProfit0 > 0) {
            if (traderProfit0 - bufferCapitalCurrency0 > 0) {
                bufferCapitalCurrency0 = 0;
                traderProfit0 -= bufferCapitalCurrency0;
            }

            if (traderProfit0 - traderPnLFeesCurrency0 > 0) {
                traderPnLFeesCurrency0 = 0;
                traderProfit0 -= traderPnLFeesCurrency0;
            }

            if (traderProfit0 - leverageFeesCurrency0 > 0) {
                leverageFeesCurrency0 = 0;
                traderProfit0 -= leverageFeesCurrency0;
            }
        }

        IERC20Metadata(currency0Address).transferFrom(
            address(this),
            msg.sender,
            uint256(traderCollateral[msg.sender].currency0Amount)
        );

        // Handle currency 1

        uint256 totalPayoutCapitalCurrency1 = bufferCapitalCurrency1 +
            traderPnLFeesCurrency1 +
            leverageFeesCurrency1;

        require(
            traderCollateral[msg.sender].currency1Amount >
                totalPayoutCapitalCurrency1,
            "Not enough capital in pool to pay out. Wait for fee accrual"
        );

        uint256 traderProfit1 = traderCollateral[msg.sender].currency1Amount -
            traderCollateral[msg.sender].fundedAmountCurrency1;

        if (traderProfit1 > 0) {
            if (traderProfit1 - bufferCapitalCurrency1 > 0) {
                bufferCapitalCurrency1 = 0;
                traderProfit1 -= bufferCapitalCurrency1;
            }

            if (traderProfit1 - traderPnLFeesCurrency1 > 0) {
                traderPnLFeesCurrency1 = 0;
                traderProfit1 -= traderPnLFeesCurrency1;
            }

            if (traderProfit1 - leverageFeesCurrency1 > 0) {
                leverageFeesCurrency1 = 0;
                traderProfit1 -= leverageFeesCurrency1;
            }
        }

        IERC20Metadata(currency1Address).transferFrom(
            address(this),
            msg.sender,
            uint256(traderCollateral[msg.sender].currency1Amount)
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

        // USD denominated position size
        uint256 positionSize = currencyPrice * marginAmount * leverage;

        (, , uint256 totalPoolValueUSD) = getUnderlyingPoolTokenValuesUSD(key);

        require(
            lockedUSDForCollateral + positionSize >= totalPoolValueUSD,
            "Liquidity capacity has been reached. Can't open new positions."
        );

        // Update position tracking
        livePositions[msg.sender] = Position({
            trader: msg.sender,
            sizeUSD: positionSize,
            marginAmount: marginAmount,
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

    function closePosition(
        address traderAddress,
        PoolKey calldata key
    ) external {
        Position memory position = livePositions[traderAddress];
        uint256 currency0Price = getCurrentPrice(key, currency0Address);
        uint256 currency1Price = getCurrentPrice(key, currency1Address);

        uint256 entryPrice = position.entryPriceUSD;
        uint256 exitPrice = position.currencyBettingOn == currency0Address
            ? currency0Price
            : currency1Price;

        uint256 profit;

        bool marginCurrencyIs0 = currency0Address == position.marginCurrency
            ? true
            : false;

        // Longs logic for payouts
        if (position.isLong) {
            uint256 priceShift = exitPrice - entryPrice;
            profit = (priceShift * position.sizeUSD) / entryPrice;
        } else {
            uint256 priceShift = entryPrice - exitPrice;
            profit = (priceShift * position.sizeUSD) / entryPrice;
        }

        if (profit > 0) {
            // Add collateral back + increase collateral with profits. Also lock up the liquidity for trader payouts.
            if (marginCurrencyIs0) {
                uint256 currency0ToPayOut = profit / currency0Price;

                traderPayOutRealisedCurrency0 += currency0ToPayOut;

                traderCollateral[msg.sender].currency0Amount +=
                    position.marginAmount +
                    currency0ToPayOut;
            } else {
                uint256 currency1ToPayOut = profit / currency1Price;

                traderPayOutRealisedCurrency1 += currency1ToPayOut;

                traderCollateral[msg.sender].currency1Amount +=
                    position.marginAmount +
                    currency1ToPayOut;
            }
        }

        if (profit < 0) {
            // Take out collateral and losses and add it to pools fees.
            if (marginCurrencyIs0) {
                uint256 currency0ToTakeOut = profit / currency0Price;

                traderCollateral[msg.sender]
                    .currency0Amount -= currency0ToTakeOut;

                traderPnLFeesCurrency0 +=
                    position.marginAmount +
                    currency0ToTakeOut;
            } else {
                uint256 currency1ToTakeOut = profit / currency1Price;

                traderCollateral[msg.sender]
                    .currency1Amount -= currency1ToTakeOut;

                traderPnLFeesCurrency1 +=
                    position.marginAmount +
                    currency1ToTakeOut;
            }
        }

        if (position.isLong) {
            longOpenInterest -= position.sizeUSD;
        } else {
            shortOpenInterest -= position.sizeUSD;
        }

        delete livePositions[msg.sender];

        emit PositionClosed(
            msg.sender,
            position.isLong,
            position.currencyBettingOn,
            position.entryPriceUSD,
            exitPrice,
            profit
        );
    }

    // This fn has to take into account collateral given by trader. Since if they have a ton of collateral, we shouldnt just close positions?
    function liquidatePosition(
        address traderAddress,
        PoolKey calldata key
    ) external {
        Position memory position = livePositions[traderAddress];
        require(position.trader != address(0), "Position doesn't exist");

        // int256 currentPrice = getCurrentPrice();
        // int256 pnl = calculatePnL(position, currentPrice);
        // require(
        //     pnl <= -int256((position.margin * LIQUIDATION_THRESHOLD) / 100),
        //     "Cannot liquidate"
        // );

        // Perform liquidation
        // TODO: Implementation
    }

    function getUnderlyingPoolTokenValuesUSD(
        PoolKey calldata key
    ) public view returns (uint256, uint256, uint256) {
        uint256 currency0Price = getCurrentPrice(key, currency0Address);
        uint256 currency1Price = getCurrentPrice(key, currency1Address);

        uint256 currency0Value = currency0Price *
            underlyingLiquidityAmountCurrency0;
        uint256 currency1Value = currency1Price *
            underlyingLiquidityAmountCurrency1;

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
        uint256 poolPrice = (uint160(sqrtPriceX96) * uint160(sqrtPriceX96)) >> 192;

        if (isBaseCurrency0) {
            // Chainlink base is currency0 (ETH)
            if (currencyAddress == currency1Address) {
                // Pool is Base/Quote (ETH/PEPE), poolPrice = PEPE per ETH
                // PEPE/USD = ETH/USD / (PEPE/ETH)
                return (uint256(chainlinkBasePrice) * 1e18) / poolPrice;
            }
        } else {
            // Chainlink base is currency1 (PEPE)
            if (currencyAddress == currency0Address) {
                // Pool is Quote/Base (PEPE/ETH), poolPrice = ETH per PEPE
                // PEPE/USD = ETH/USD * (ETH/PEPE)
                return (uint256(chainlinkBasePrice) * poolPrice) / 1e18;
            }
        }

        revert("Invalid currency address");
    }

    function getLeverageRate(
        address traderAddress,
        uint256 utilizationRate
    ) public view returns (uint256) {
        return
            (BASE_LEVERAGE_RATE *
                livePositions[traderAddress].leverage *
                (utilizationRate * 10)) / 1e4;
    }

    function getImbalanceRate() public view returns (uint256) {
        return
            (100 * (longOpenInterest - shortOpenInterest)) /
            (longOpenInterest + shortOpenInterest);
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
        uint256 profit
    );
    event PositionLiquidated(address indexed trader, uint256 margin);
    event FundingPaid(address indexed trader, uint256 amount);
}
