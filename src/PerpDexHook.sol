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
import "solidity-stringutils/src/strings.sol";

contract PerpDexHook is BaseHook {
    using strings for *;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

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
        uint256 currency0Amount;
        uint256 currency1Amount;
    }

    // Only one position per trader
    mapping(address => Position) public livePositions;
    mapping(address => Collateral) public traderCollateral;

    uint256 public totalLiquidity;

    // Locked currencies for traders realise profits.
    uint256 public traderPayOutLockedCurrency0;
    uint256 public traderPayOutLockedCurrency1;

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
                afterInitialize: true,
                beforeAddLiquidity: true,
                afterAddLiquidity: true,
                beforeRemoveLiquidity: true,
                afterRemoveLiquidity: true,
                beforeSwap: false,
                afterSwap: false,
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
        totalLiquidity = 0;
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

    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata
    ) external override returns (bytes4) {
        if (params.liquidityDelta > 0) {
            totalLiquidity += uint256(params.liquidityDelta);
        }

        return this.beforeAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata
    ) external override returns (bytes4) {
        // require(
        //     totalLiquidity - uint256(-params.liquidityDelta) >= lockedLiquidity,
        //     "Cannot remove locked liquidity"
        // );

        if (params.liquidityDelta > 0) {
            totalLiquidity -= uint256(params.liquidityDelta);
        }

        return this.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta1,
        BalanceDelta delta2,
        bytes calldata
    ) external override returns (bytes4, BalanceDelta) {
        uint256 lpersLiquidity = uint256(params.liquidityDelta);

        return (this.afterRemoveLiquidity.selector, delta1);
    }

    function addCollateral(
        address trader,
        uint256 currency0,
        uint256 currency1
    ) external payable {
        if (currency0 > 0) {
            require(
                IERC20Metadata(currency0Address).transferFrom(
                    msg.sender,
                    address(this),
                    currency0
                ),
                "Transfer failed"
            );
            traderCollateral[trader].currency0Amount += currency0;
        }

        if (currency1 > 0) {
            require(
                IERC20Metadata(currency1Address).transferFrom(
                    msg.sender,
                    address(this),
                    currency1
                ),
                "Transfer failed"
            );
            traderCollateral[trader].currency1Amount += currency1;
        }
    }

    function removeCollateral() external {
        // if (USDC.balanceOf(address(this)) > traderCollateral[msg.sender]) {
        //     require(
        //         USDC.transferFrom(
        //             address(this),
        //             msg.sender,
        //             traderCollateral[msg.sender]
        //         ),
        //         "USDC transfer failed"
        //     );
        // } else {
        //     // trigger the process for removing from funding fees + buffer capital + LP funds
        // }

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
        // FIX THIS ONE BELOW. TOTAL LIQUIDITY SHOULD BE THE RESERVERS OF TOKEN 0 AND TOKEN 1. LONG AND OPEN INTEREST ARE ALSO MORE FLUCTUATING DEPENDING ON PNL OR JUST MARGIN?
        require(
            shortOpenInterest + longOpenInterest >= 2 * totalLiquidity,
            "The size of open interest on this pool has been reached"
        );
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

                traderPayOutLockedCurrency0 += currency0ToPayOut;

                traderCollateral[msg.sender].currency0Amount +=
                    position.marginAmount +
                    currency0ToPayOut;
            } else {
                uint256 currency1ToPayOut = profit / currency1Price;

                traderPayOutLockedCurrency1 += currency1ToPayOut;

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
        address traderAddress
    ) public view returns (uint256) {
        return
            (BASE_LEVERAGE_RATE *
                livePositions[traderAddress].leverage *
                (getUtilizationRate() * 10)) / 1e4;
    }

    // FIX THIS WITH USD AND STUFF. USED UP RESERVERS DIVIDED BY TOTAL RESERVES.
    function getUtilizationRate() public view returns (uint256) {
        return (0 * 1e4) / totalLiquidity;
    }

    function getImbalanceRate() public view returns (uint256) {
        return
            (longOpenInterest - shortOpenInterest) /
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
