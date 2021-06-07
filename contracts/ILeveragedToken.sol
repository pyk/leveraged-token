// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.7.4;
pragma experimental ABIEncoderV2;

interface ILeveragedToken {
    function buy(
        uint256 amount,
        uint256 limitPrice,
        uint256 deadline
    ) external;

    function buyCost(uint256 amount) external returns (uint256 cost);

    function sell(
        uint256 amount,
        uint256 limitPrice,
        uint256 deadline
    ) external;

    function sellIncome(uint256 amount) external returns (uint256 income);

    function netAssetValue() external returns (uint256 nav);

    function settle() external;
}
