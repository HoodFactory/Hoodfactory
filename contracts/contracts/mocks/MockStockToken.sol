// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockStockToken
/// @notice Stand-in for a Robinhood Chain Stock Token (mTSLA, mAAPL, ...) so the
///         stock-pair launch flow can be exercised on testnet, where the real
///         tokenized equities do not exist. Decimals are configurable because
///         real Stock Tokens are not guaranteed to use 18.
/// @dev Test and testnet only. Never deployed to mainnet.
contract MockStockToken is ERC20 {
    uint8 private immutable _decimals;

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_
    ) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// @notice Open faucet so testers can obtain the quote asset freely.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
