// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.7.4;
pragma experimental ABIEncoderV2;

import "./interfaces/ILiquidityPool.sol";
import "./Controller.sol";
import "./LeveragedToken.sol";

contract LeveragedTokenFactory {
    uint256 public constant UEXP_SCALE = 10**18;
    address public defaultController;

    mapping(bytes32 => address) public tokens;

    event CreateLeveragedToken(
        address liquidityPool_,
        uint256 perpetualIndex_,
        uint256 targetLeverage_,
        bool isLongToken_,
        address token
    );

    modifier onlyDao {
        require(msg.sender == Controller(defaultController).dao(), "only dao");
        _;
    }

    constructor(address controller) {
        defaultController = controller;
    }

    function setDefaultController(address controller) public onlyDao {
        defaultController = controller;
    }

    function createLeverageToken(
        address liquidityPool_,
        uint256 perpetualIndex_,
        uint256 targetLeverage_,
        bool isLongToken_
    ) public {
        require(targetLeverage_ % UEXP_SCALE == 0, "leverage is not int");

        bytes32 nameHash =
            tokenNameHash(liquidityPool_, perpetualIndex_, targetLeverage_, isLongToken_);

        require(tokens[nameHash] == address(0), "already created");

        ILiquidityPool pool = ILiquidityPool(liquidityPool_);
        (PerpetualState state, address oracle, ) = pool.getPerpetualInfo(perpetualIndex_);
        require(state == PerpetualState.NORMAL, "perp not normal");
        string memory asset = IOracle(oracle).underlyingAsset();
        string memory lev = _uint256ToString(targetLeverage_);
        bytes memory symbol;
        bytes memory name;
        if (isLongToken_) {
            symbol = abi.encodePacked(asset, "Bull", lev, "x");
            name = abi.encodePacked(asset, " Bull Leveraged Token ", lev, "x");
        } else {
            symbol = abi.encodePacked(asset, "Bear", lev, "x");
            name = abi.encodePacked(asset, " Bear Leveraged Token ", lev, "x");
        }
        LeveragedToken token =
            new LeveragedToken(
                string(symbol),
                string(name),
                liquidityPool_,
                perpetualIndex_,
                targetLeverage_,
                isLongToken_,
                defaultController
            );
        tokens[nameHash] = address(token);
        emit CreateLeveragedToken(
            liquidityPool_,
            perpetualIndex_,
            targetLeverage_,
            isLongToken_,
            address(token)
        );
    }

    function tokenNameHash(
        address liquidityPool_,
        uint256 perpetualIndex_,
        uint256 targetLeverage_,
        bool isLongToken_
    ) public pure returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(liquidityPool_, perpetualIndex_, targetLeverage_, isLongToken_)
            );
    }

    function _uint256ToString(uint256 v) internal pure returns (string memory str) {
        uint256 maxlength = 20;
        bytes memory reversed = new bytes(maxlength);
        uint256 i = 0;
        v /= UEXP_SCALE;
        while (v != 0) {
            uint8 remainder = uint8(v % 10);
            v = v / (10 * UEXP_SCALE);
            reversed[i++] = byte(48 + remainder);
        }
        bytes memory s = new bytes(i + 1);
        for (uint256 j = 0; j <= i; j++) {
            s[j] = reversed[i - j];
        }
        str = string(s);
    }
}
