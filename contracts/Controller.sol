// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.7.4;
pragma experimental ABIEncoderV2;

import "./DaoGover.sol";

contract Controller is DaoGover {
    int256 public constant EXP_SCALE = 10**18;
    uint256 public constant UEXP_SCALE = 10**18;

    // if the leverage reaches 130% of target leverage, the token will be rebalanced.
    uint256 public emergencyRebalanceThreshold = (UEXP_SCALE * 333) / 1000;

    // rebalance preceison is 10%
    uint256 public rebalancePrecision = (UEXP_SCALE) / 10;

    // rebalance slippage is 0.3%
    int256 public rebalanceSlippageTolerance = (EXP_SCALE * 3) / 1000;

    // keeper fee is 0.02%
    int256 public rebalanceKeeperFee = (EXP_SCALE * 2) / 10000;

    uint256 public maxTargetLeverage = UEXP_SCALE * 10;

    uint256 public maxRebalanceTime = 2 hours;

    // if keeper == 0, anyone can be the keeper
    address public keeper;

    constructor() {}

    function setEmergencyRebalanceThreshold(uint256 threshold) public onlyDao {
        emergencyRebalanceThreshold = threshold;
    }

    function setRebalancePrecision(uint256 precision) public onlyDao {
        rebalancePrecision = precision;
    }

    function setKeeper(address keeper_) public onlyDao {
        keeper = keeper_;
    }

    function setRebalanceSlippageTolerance(int256 slippage) public onlyDao {
        rebalanceSlippageTolerance = slippage;
    }

    function setRebalanceKeeperFee(int256 fee) public onlyDao {
        rebalanceKeeperFee = fee;
    }

    function setMaxTargetLeverage(uint256 leverage) public onlyDao {
        maxTargetLeverage = leverage;
    }

    function setMaxRebalanceTime(uint256 duration) public onlyDao {
        maxRebalanceTime = duration;
    }
}
