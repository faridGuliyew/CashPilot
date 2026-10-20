// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title MockUSDC
/// @notice Testnet-only stablecoin with 6 decimals. Only the admin (owner) can mint.
contract MockUSDC is ERC20, Ownable {
    constructor(address admin) ERC20("Mock USD Coin", "mUSDC") Ownable(admin) {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}
