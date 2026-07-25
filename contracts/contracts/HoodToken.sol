// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title HoodToken
/// @notice Fixed-supply token launched through HoodLaunchpad on Robinhood Chain. The launchpad
///         sends 20% to its configured creatorVestingWallet and deposits 80%
///         as permanently locked, single-sided V3 liquidity at creation.
///         No owner, no further minting, no pause, and no blacklist.
contract HoodToken is ERC20 {
    address public immutable launchpad;

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 supply_
    ) ERC20(name_, symbol_) {
        launchpad = msg.sender;
        _mint(msg.sender, supply_);
    }

    /// @notice Burn caller's tokens voluntarily. Launchpad fee accounting does
    ///         not burn collected token-side LP fees.
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}
