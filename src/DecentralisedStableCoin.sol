//SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/*
 * @title DecentralisedStableCoin
 * @author Dharmin Nagar
 * Collateral: Exogenous (ETH & BTC)
 * Minting: Algorithmic
 * Relative Stability: Pegged to USD
 *
 * This is the contract meant to be governed by DSCEngine. This contract is just the ERC20 implementation of the Stable Coin System
 * .
 */
contract DecentralisedStableCoin is ERC20Burnable, Ownable {
    constructor() ERC20("DecentralisedStableCoin", "DSC") Ownable(msg.sender) {}

    error DecentralisedStableCoin__MustBeGreaterThanZero();
    error DecentralisedStableCoin__InsufficientBalance();
    error DecentralisedStableCoin__NotValidAddress();

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        if (_amount <= 0) {
            revert DecentralisedStableCoin__MustBeGreaterThanZero();
        }

        if (_amount > balance) {
            revert DecentralisedStableCoin__InsufficientBalance();
        }

        super.burn(_amount);
    }

    function mint(
        address _to,
        uint256 _amount
    ) external onlyOwner returns (bool) {
        if (_to == address(0)) {
            revert DecentralisedStableCoin__NotValidAddress();
        }

        if (_amount <= 0) {
            revert DecentralisedStableCoin__MustBeGreaterThanZero();
        }

        _mint(_to, _amount);
        return true;
    }
}
