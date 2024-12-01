// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AggregatorV3Interface} from "chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "stringutils/strings.sol";

contract PerpDexHook is BaseHook {
    uint256 public constant MAX_LEVERAGE = 5;
    uint256 public constant LIQUIDATION_THRESHOLD = 80; // 80%
    uint256 public constant BASE_LEVERAGE_RATE = 1e15; // 0.1% base leverage rate

    address public currency0Address;
    address public currency1Address;

    struct Position {
        address trader;
        uint256 size;
        uint256 margin;
        uint256 leverage;
        int256 entryPrice;
        bool isLong;
        uint256 timestamp;
    }

    struct Collateral {
        uint256 currency0;
        uint256 currency1;
    }

    // Only one position per trader
    mapping(address => Position) public livePositions;
    mapping(address => Collateral) public traderCollateral;

    uint256 public totalLiquidity;
    uint256 public lockedLiquidity;
    uint256 public longOpenInterest;
    uint256 public shortOpenInterest;
    // Fees for traders to divide between each other for imbalance
    uint256 public imbalanceFees;

    // Fees for LPs to earn from renting leverage
    uint256 public leverageFees;
    // Fees for LPs from traders losing/making money. Can be negative, aka LPs pay out fees.
    uint256 public traderPnLFees;

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
        lockedLiquidity = 0;
        longOpenInterest = 0;
        shortOpenInterest = 0;
        imbalanceFees = 0;

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
        require(
            totalLiquidity - uint256(-params.liquidityDelta) >= lockedLiquidity,
            "Cannot remove locked liquidity"
        );

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
            traderCollateral[trader].currency0 += currency0;
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
            traderCollateral[trader].currency1 += currency1;
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
        uint256 marginAmount,
        uint256 leverage,
        bool isLong
    ) external {
        require(leverage <= MAX_LEVERAGE, "Leverage too high");
        uint256 positionSize = marginAmount * leverage;

        // Check available liquidity
        require(
            totalLiquidity - lockedLiquidity >= positionSize,
            "Insufficient liquidity"
        );
        require(
            traderCollateral[msg.sender] >= marginAmount,
            "Insufficient trader collateral"
        );
        require(
            livePositions[msg.sender].trader == address(0),
            "A position already exists for this trader"
        );

        int256 entryPrice = getCurrentPrice();

        // Update position tracking
        livePositions[msg.sender] = Position({
            trader: msg.sender,
            size: positionSize,
            margin: marginAmount,
            leverage: leverage,
            entryPrice: entryPrice,
            isLong: isLong,
            timestamp: block.timestamp
        });

        // Update global state
        lockedLiquidity += positionSize;
        if (isLong) {
            longOpenInterest += positionSize;
        } else {
            shortOpenInterest += positionSize;
        }

        traderCollateral[msg.sender] -= marginAmount;

        emit PositionOpened(
            msg.sender,
            entryPrice,
            positionSize,
            leverage,
            isLong
        );
    }

    function closePosition(address traderAddress) external {
        Position memory position = livePositions[traderAddress];
        uint256 entryPrice = uint256(position.entryPrice);
        uint256 exitPrice = uint256(getCurrentPrice());
        uint256 originalPositionSize = position.margin * position.leverage;

        uint256 currPositionSize;
        uint256 profit;

        if (exitPrice >= entryPrice && position.isLong) {
            uint256 priceIncrease = exitPrice - entryPrice;
            profit = (priceIncrease * originalPositionSize) / entryPrice;

            traderPnLFees -= profit;

            currPositionSize = originalPositionSize + profit;
        } else if (position.isLong) {
            uint256 priceDecrease = exitPrice - entryPrice;
            profit = (priceDecrease * originalPositionSize) / entryPrice;

            traderPnLFees += profit;

            currPositionSize = originalPositionSize - profit;
        }

        require(
            totalLiquidity - lockedLiquidity >= currPositionSize,
            "Insufficient liquidity"
        );

        traderCollateral[msg.sender] += position.margin + profit;

        lockedLiquidity -= originalPositionSize;
        if (position.isLong) {
            longOpenInterest -= originalPositionSize;
        } else {
            shortOpenInterest -= originalPositionSize;
        }

        delete livePositions[msg.sender];

        emit PositionClosed(
            msg.sender,
            position.isLong,
            int256(exitPrice),
            profit
        );
    }

    // This fn has to take into account collateral given by trader. Since if they have a ton of collateral, we shouldnt just close positions?
    function liquidatePosition(address traderAddress) external {
        Position memory position = livePositions[traderAddress];
        require(position.trader != address(0), "Position doesn't exist");

        int256 currentPrice = getCurrentPrice();
        // int256 pnl = calculatePnL(position, currentPrice);
        // require(
        //     pnl <= -int256((position.margin * LIQUIDATION_THRESHOLD) / 100),
        //     "Cannot liquidate"
        // );

        // Perform liquidation
        // TODO: Implementation
    }

    // Helper functions
    function getCurrentPrice() internal view returns (int256) {
        // TODO: Implementation
        return 0;
    }

    function getLeverageRate(
        PoolKey calldata key,
        address traderAddress
    ) public view returns (uint256) {
        return
            (BASE_LEVERAGE_RATE *
                livePositions[traderAddress].leverage *
                (getUtilizationRate(key) * 10)) / 1e4;
    }

    function getUtilizationRate(
        PoolKey calldata key
    ) public view returns (uint256) {
        return (lockedLiquidity * 1e4) / totalLiquidity;
    }

    function getImbalanceRate(
        PoolKey calldata key
    ) public view returns (uint256) {
        return
            (longOpenInterest - shortOpenInterest) /
            (longOpenInterest + shortOpenInterest);
    }

    function validateFeed(address tokenAddress) internal view returns (bool) {
        try priceFeed.description() returns (string memory desc) {
            bytes32 tokenSymbol = keccak256(abi.encodePacked(desc));
            bytes32 addressSymbol = keccak256(
                abi.encodePacked(IERC20Metadata(tokenAddress).symbol())
            );
            return tokenSymbol == addressSymbol;
        } catch {
            return false;
        }
    }

    event PositionOpened(
        address indexed trader,
        int256 entryPrice,
        uint256 size,
        uint256 leverage,
        bool isLong
    );
    event PositionClosed(
        address indexed trader,
        bool isLong,
        int256 exitPrice,
        uint256 profit
    );
    event PositionLiquidated(address indexed trader, uint256 margin);
    event FundingPaid(address indexed trader, uint256 amount);
}
