// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.7.4;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/math/SignedSafeMath.sol";
import "@openzeppelin/contracts/utils/SafeCast.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./interfaces/ILiquidityPool.sol";
import "./Controller.sol";
import "./ILeveragedToken.sol";

contract LeveragedToken is ILeveragedToken, ERC20, ReentrancyGuard {
    using SignedSafeMath for int256;
    using SafeMath for uint256;
    using SafeCast for uint256;
    using SafeCast for int256;
    using SafeERC20 for IERC20;

    uint256 public constant MAX_UINT256 = uint256(-1);
    int256 public constant EXP_SCALE = 10**18;
    uint256 public constant UEXP_SCALE = 10**18;

    // assume block time is 13.3s
    uint256 public constant PERIODIC_REBALANCE_MIN_INTERVAL_BLOCKS = (uint256(12 hours) * 10) / 133;

    Controller public controller;

    // address of Mai3 liquidity pool
    ILiquidityPool public pool;

    // pereptual index in the liquidity pool
    uint256 public perpetualIndex;

    uint256 public targetLeverage;

    uint256 public lastPeriodicRebalanceBlock;

    bool public isLongToken;
    address public collateralToken;
    uint256 public collateralDecimals;

    bool public isSettled;

    event BuyTokens(address indexed buyer, uint256 amount, uint256 cost);

    event SellTokens(address indexed seller, uint256 amount, uint256 income);

    event Settle(address indexed account, uint256 amount, uint256 collaterals);

    modifier onlyKeeper {
        address keeper = controller.keeper();
        require(keeper == address(0) || msg.sender == keeper, "only Keeper");
        _;
    }

    constructor(
        string memory name_,
        string memory symbol_,
        address liquidityPool_,
        uint256 perpetualIndex_,
        uint256 targetLeverage_,
        bool isLongToken_,
        address controller_
    ) ERC20(name_, symbol_) {
        pool = ILiquidityPool(liquidityPool_);
        perpetualIndex = perpetualIndex_;
        targetLeverage = targetLeverage_;
        isLongToken = isLongToken_;
        (bool isRunning, , address[7] memory addresses, , uint256[4] memory uintNums) =
            pool.getLiquidityPoolInfo();
        require(isRunning, "pool is not running");
        collateralToken = addresses[5];
        collateralDecimals = uintNums[0];
        isSettled = false;
        controller = Controller(controller_);
        require(targetLeverage <= controller.maxTargetLeverage(), "invalid leverage");

        updateAllowances();
    }

    function updateAllowances() public {
        uint256 allowance = IERC20(collateralToken).allowance(address(this), address(pool));
        IERC20(collateralToken).safeIncreaseAllowance(address(pool), MAX_UINT256.sub(allowance));
    }

    function buy(
        uint256 amount,
        uint256 limitPrice,
        uint256 deadline
    ) external override nonReentrant {
        require(!isSettled, "settled");
        pool.forceToSyncState();

        (int256 cost, int256 tradeAmount, int256 tradePrice) = _buyCost(amount.toInt256());
        uint256 realCost = 0;
        if (cost > 0) {
            realCost = uint256(cost);
            require(realCost.mul(UEXP_SCALE).div(amount) <= limitPrice, "limit price");
            uint256 collateralAmount = _collateralTokens(cost);
            IERC20(collateralToken).transferFrom(msg.sender, address(this), collateralAmount);
            pool.deposit(
                perpetualIndex,
                address(this),
                IERC20(collateralToken).balanceOf(address(this)).toInt256()
            );
        }
        pool.trade(perpetualIndex, address(this), tradeAmount, tradePrice, deadline, address(0), 0);
        _mint(msg.sender, amount);
        emit BuyTokens(msg.sender, amount, realCost);
    }

    function buyCost(uint256 amount) external override returns (uint256 cost) {
        require(!isSettled, "settled");
        pool.forceToSyncState();

        (int256 c, , ) = _buyCost(amount.toInt256());

        if (c > 0) {
            cost = uint256(c);
        } else {
            cost = 0;
        }
    }

    function _buyCost(int256 tokenAmount)
        internal
        view
        returns (
            int256 cost,
            int256 tradeAmount,
            int256 tradePrice
        )
    {
        int256 markPrice;
        {
            (PerpetualState state, , int256[39] memory nums) =
                pool.getPerpetualInfo(perpetualIndex);
            require(state == PerpetualState.NORMAL, "perp not noraml");
            markPrice = nums[1];
        }
        int256 totalSupply = totalSupply().toInt256();
        int256 leverage;

        {
            (, int256 position, , int256 margin, , bool isInitialMarginSafe, , , ) =
                pool.getMarginAccount(perpetualIndex, address(this));

            require(isInitialMarginSafe, "position unsafe");

            // first buy, let tradeAmount = tokenAmount
            if (totalSupply == 0) {
                require(position == 0, "position <> 0");

                if (isLongToken) {
                    tradeAmount = tokenAmount;
                    leverage = targetLeverage.toInt256();
                } else {
                    tradeAmount = -tokenAmount;
                    leverage = (-targetLeverage).toInt256();
                }
            } else {
                if (isLongToken) {
                    require(position > 0, "position is wrong");
                } else {
                    require(position < 0, "position is wrong");
                }
                //tradeAmount, leverage and position have the same sign
                tradeAmount = position.mul(tokenAmount).div(totalSupply);
                leverage = markPrice.mul(position).div(margin);
            }
        }

        (int256 deltaCash, ) = pool.queryTradeWithAMM(perpetualIndex, tradeAmount);

        //deltaCash = -avgPrice * tradeAmount, tradeAmount can be negative
        //pnl = (mark - avgPrice) * tradeAmount = mark * tradeAmount + deltaCash
        //cost = mark * tradeAmount / leverage - pnl;
        int256 pnl = markPrice.mul(tradeAmount).div(EXP_SCALE).add(deltaCash);
        cost = markPrice.mul(tradeAmount).div(leverage).sub(pnl);
        tradePrice = deltaCash.mul(-EXP_SCALE).div(tradeAmount);
    }

    function sell(
        uint256 amount,
        uint256 limitPrice,
        uint256 deadline
    ) external override nonReentrant {
        require(!isSettled, "settled");

        pool.forceToSyncState();

        (int256 income, int256 tradeAmount, int256 tradePrice) = _sellIncome(amount.toInt256());
        uint256 realIncome = income.toUint256();
        require(realIncome.mul(UEXP_SCALE).div(amount) >= limitPrice, "limit price");
        pool.trade(perpetualIndex, address(this), tradeAmount, tradePrice, deadline, address(0), 0);
        pool.withdraw(perpetualIndex, address(this), income);

        uint256 collateralAmount = _collateralTokens(income);
        IERC20(collateralToken).transferFrom(address(this), msg.sender, collateralAmount);
        _burn(msg.sender, amount);

        emit SellTokens(msg.sender, amount, realIncome);
    }

    function sellIncome(uint256 amount) external override returns (uint256 income) {
        require(!isSettled, "settled");
        pool.forceToSyncState();

        (int256 i, , ) = _sellIncome(amount.toInt256());

        if (i > 0) {
            income = uint256(i);
        } else {
            income = 0;
        }
    }

    function _sellIncome(int256 tokenAmount)
        internal
        view
        returns (
            int256 income,
            int256 tradeAmount,
            int256 tradePrice
        )
    {
        int256 markPrice;
        {
            (PerpetualState state, , int256[39] memory nums) =
                pool.getPerpetualInfo(perpetualIndex);
            require(state == PerpetualState.NORMAL, "perp not noraml");
            markPrice = nums[1];
        }

        int256 margin;
        int256 position;
        {
            int256 totalSupply = totalSupply().toInt256();
            require(totalSupply >= tokenAmount, "bad amount");
            bool isMarginSafe;
            (, position, , margin, , , , isMarginSafe, ) = pool.getMarginAccount(
                perpetualIndex,
                address(this)
            );

            require(isMarginSafe, "bankrupt");
            require(position != 0, "no postion");

            if (tokenAmount == totalSupply) {
                tradeAmount = -position;
            } else {
                tradeAmount = -position.mul(tokenAmount).div(totalSupply);
            }
        }

        (int256 deltaCash, ) = pool.queryTradeWithAMM(perpetualIndex, tradeAmount);

        //deltaCash = -avgPrice * tradeAmount, tradeAmount can be negative
        //pnl = (avgPrice - mark) * tradeAmount = - (mark * tradeAmount + deltaCash)
        //income = margin * tradeAmount / position + pnl; tradeAmount has the same sign with leverage
        int256 pnl = -(markPrice.mul(tradeAmount).div(EXP_SCALE).add(deltaCash));
        income = margin.mul(tradeAmount).div(position).add(pnl);
        tradePrice = deltaCash.mul(-EXP_SCALE).div(tradeAmount);
    }

    function netAssetValue() external override returns (uint256) {
        pool.forceToSyncState();

        uint256 totalSupply = totalSupply();
        if (totalSupply == 0) {
            return 0;
        }

        (, , , int256 margin, , , , bool isMarginSafe, ) =
            pool.getMarginAccount(perpetualIndex, address(this));

        if (!isMarginSafe) {
            return 0;
        }
        return _collateralTokens(margin.mul(EXP_SCALE).div(totalSupply.toInt256()));
    }

    function _collateralTokens(int256 amount) internal view returns (uint256) {
        return amount.toUint256().div(10**(UEXP_SCALE - collateralDecimals));
    }

    function settle() external override {
        if (!isSettled) {
            pool.forceToSyncState();
            pool.settle(perpetualIndex, address(this));
            isSettled = true;
        }

        address account = msg.sender;
        uint256 amount = balanceOf(account);
        uint256 totalSupply = totalSupply();
        uint256 totalCollateral = IERC20(collateralToken).balanceOf(address(this));
        uint256 collteralAmount = amount.mul(totalCollateral).div(totalSupply);
        IERC20(collateralToken).transfer(account, collteralAmount);
        _burn(account, amount);
        uint256 collaterals = collteralAmount.mul(10**(UEXP_SCALE - collateralDecimals));
        emit Settle(msg.sender, amount, collaterals);
    }

    function perdiocalRebalance(int256 tradeAmount, uint256 deadline)
        external
        onlyKeeper
        nonReentrant
    {
        require(!isSettled, "settled");
        require(
            lastPeriodicRebalanceBlock + PERIODIC_REBALANCE_MIN_INTERVAL_BLOCKS < block.number,
            "too early"
        );
        require(block.timestamp % (1 days) < controller.maxRebalanceTime(), "bad time");

        pool.forceToSyncState();

        int256 markPrice = _getMarkPrice();

        (int256 margin, int256 position) = _getPosition();
        uint256 leverage = _leverage(markPrice, margin, position);

        uint256 leverageCeil = _targetLeverageCeil();
        uint256 leverageFloor = _targetLeverageFloor();

        if (leverage > leverageCeil) {
            uint256 newLeverage =
                _decreaseLeverage(markPrice, position, leverage, tradeAmount, deadline);
            if (newLeverage <= leverageCeil) {
                lastPeriodicRebalanceBlock = block.number;
            }
        } else if (leverage < leverageFloor) {
            uint256 newLeverage =
                _increaseLeverage(markPrice, position, leverage, tradeAmount, deadline);
            if (newLeverage >= leverageFloor) {
                lastPeriodicRebalanceBlock = block.number;
            }
        } else {
            lastPeriodicRebalanceBlock = block.number;
        }
    }

    function emergencyRebalance(int256 tradeAmount, uint256 deadline)
        external
        onlyKeeper
        nonReentrant
    {
        require(!isSettled, "settled");
        pool.forceToSyncState();

        int256 markPrice = _getMarkPrice();

        (int256 margin, int256 position) = _getPosition();
        uint256 leverage = _leverage(markPrice, margin, position);

        uint256 emergencyLeverage = _emergencyLeverage();
        require(leverage >= emergencyLeverage, "not emergency");
        uint256 newLeverage =
            _decreaseLeverage(markPrice, position, leverage, tradeAmount, deadline);
        uint256 emergencyMinLeverage = _emergencyMinLeverage();
        require(newLeverage >= emergencyMinLeverage, "leverage too small");
    }

    function _decreaseLeverage(
        int256 markPrice,
        int256 position,
        uint256 oldLeverage,
        int256 tradeAmount,
        uint256 deadline
    ) internal returns (uint256 newLeverage) {
        require(
            (position > 0 && tradeAmount > 0) || (position < 0 && tradeAmount < 0),
            "bad trade side"
        );
        {
            int256 limitPrice = _rebalanceLimitPrice(tradeAmount, markPrice);
            pool.trade(
                perpetualIndex,
                address(this),
                tradeAmount,
                limitPrice,
                deadline,
                address(0),
                0
            );
        }

        _sendRebalanceFee(markPrice, tradeAmount);
        int256 margin;
        (margin, position) = _getPosition();
        newLeverage = _leverage(markPrice, margin, position);

        require(newLeverage < oldLeverage, "leverage not decrease");
        require(newLeverage >= targetLeverage, "leverage too small");
    }

    function _increaseLeverage(
        int256 markPrice,
        int256 position,
        uint256 oldLeverage,
        int256 tradeAmount,
        uint256 deadline
    ) internal returns (uint256 newLeverage) {
        require(
            (position > 0 && tradeAmount < 0) || (position < 0 && tradeAmount > 0),
            "bad trade side"
        );
        {
            int256 limitPrice = _rebalanceLimitPrice(tradeAmount, markPrice);
            pool.trade(
                perpetualIndex,
                address(this),
                tradeAmount,
                limitPrice,
                deadline,
                address(0),
                0
            );
        }

        _sendRebalanceFee(markPrice, tradeAmount);
        int256 margin;
        (margin, position) = _getPosition();
        newLeverage = _leverage(markPrice, margin, position);

        require(newLeverage > oldLeverage, "leverage not decrease");
        require(newLeverage <= targetLeverage, "leverage too small");
    }

    function _leverage(
        int256 markPrice,
        int256 margin,
        int256 position
    ) internal pure returns (uint256) {
        int256 lev = markPrice.mul(position).div(margin);
        if (lev < 0) {
            return (-lev).toUint256();
        }
        return lev.toUint256();
    }

    function _getMarkPrice() internal view returns (int256) {
        (PerpetualState state, , int256[39] memory nums) = pool.getPerpetualInfo(perpetualIndex);
        require(state == PerpetualState.NORMAL, "perp not noraml");
        return nums[1];
    }

    function _getPosition() internal view returns (int256 margin, int256 position) {
        bool isMarginSafe;
        (, position, , margin, , , , isMarginSafe, ) = pool.getMarginAccount(
            perpetualIndex,
            address(this)
        );
        require(isMarginSafe, "margin unsafe");
        require(margin > 0, "no margin");
        if (isLongToken) {
            require(position > 0, "bad postion");
        } else {
            require(position < 0, "bad postion");
        }
    }

    function _targetLeverageCeil() internal view returns (uint256) {
        return targetLeverage.mul(UEXP_SCALE + controller.rebalancePrecision()).div(UEXP_SCALE);
    }

    function _targetLeverageFloor() internal view returns (uint256) {
        return targetLeverage.mul(UEXP_SCALE - controller.rebalancePrecision()).div(UEXP_SCALE);
    }

    function _rebalanceLimitPrice(int256 tradeAmount, int256 markPrice)
        internal
        view
        returns (int256 limitPrice)
    {
        if (tradeAmount > 0) {
            limitPrice = markPrice.mul(EXP_SCALE + controller.rebalanceSlippageTolerance()).div(
                EXP_SCALE
            );
        } else {
            limitPrice = markPrice.mul(EXP_SCALE - controller.rebalanceSlippageTolerance()).div(
                EXP_SCALE
            );
        }
    }

    function _emergencyLeverage() internal view returns (uint256) {
        return targetLeverage.mul(controller.emergencyLeverageThreshold()).div(UEXP_SCALE);
    }

    function _emergencyMinLeverage() internal view returns (uint256) {
        return targetLeverage.mul(controller.emergencyRebalanceMinLeverageRate()).div(UEXP_SCALE);
    }

    function _sendRebalanceFee(int256 markPrice, int256 tradeAmount) internal {
        if (tradeAmount < 0) {
            tradeAmount = -tradeAmount;
        }
        int256 feeBase = markPrice.mul(tradeAmount).div(EXP_SCALE);
        int256 keeperFee = feeBase.mul(controller.rebalanceKeeperFee()).div(EXP_SCALE);
        pool.withdraw(perpetualIndex, address(this), keeperFee);
        IERC20(collateralToken).transfer(msg.sender, keeperFee.toUint256());
    }
}
