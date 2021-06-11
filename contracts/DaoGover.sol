// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.7.4;
pragma experimental ABIEncoderV2;

abstract contract DaoGover {
    address public dao;
    address public guard;

    modifier onlyDao {
        require(dao == msg.sender, "only dao");
        _;
    }

    modifier onlyDaoOrGuard {
        require(msg.sender == dao || msg.sender == guard, "only dao or guardian");
        _;
    }

    constructor() {
        dao = msg.sender;
        guard = msg.sender;
    }

    function setDao(address dao_) external onlyDao {
        dao = dao_;
    }

    function setGuard(address guard_) external onlyDao {
        guard = guard_;
    }
}
