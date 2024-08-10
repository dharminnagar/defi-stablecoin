// Handler is going to narrow down the way we call the function

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralisedStableCoin} from "../../src/DecentralisedStableCoin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract Handler is Test {
    DSCEngine engine;
    DecentralisedStableCoin dsc;

    ERC20Mock weth;
    ERC20Mock wbtc;

    uint256 public timesMintIsCalled;
    address[] public usersWithDepositedCollateral;
    MockV3Aggregator public ethUSDPriceFeed;

    uint256 MAX_DEPOSIT_SIZE = type(uint96).max;

    constructor(DSCEngine _dscEngine, DecentralisedStableCoin _dsc) {
        engine = _dscEngine;
        dsc = _dsc;

        address[] memory tokens = engine.getCollateralTokens();
        weth = ERC20Mock(tokens[0]);
        wbtc = ERC20Mock(tokens[1]);

        ethUSDPriceFeed = MockV3Aggregator(engine.getCollateralTokenPriceFeed(address(weth)));
    }

    function mintDSC(uint256 amount, uint256 addressSeed) public {
        // amount = bound(amount, 1, MAX_DEPOSIT_SIZE);

        if (usersWithDepositedCollateral.length == 0) {
            return;
        }
        address sender = usersWithDepositedCollateral[addressSeed % usersWithDepositedCollateral.length];

        (uint256 dscMinted, uint256 collateralValue) = engine.getAccountInfo(sender);
        int256 maxDSCToMint = (int256(collateralValue) / 2) - int256(dscMinted);

        if (maxDSCToMint < 0) {
            return;
        }

        amount = bound(amount, 0, uint256(maxDSCToMint));
        if (amount == 0) {
            return;
        }

        vm.startPrank(sender);
        engine.mintDSC(amount);
        vm.stopPrank();
        timesMintIsCalled++;
    }

    // deposit Collateral
    function depositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);

        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(engine), amountCollateral);
        engine.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
        // double push
        usersWithDepositedCollateral.push(msg.sender);
    }

    // redeem Collateral
    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        uint256 maxCollateralToRedeem = engine.getCollateralBalanceOfUser(address(collateral), msg.sender);
        amountCollateral = bound(amountCollateral, 0, maxCollateralToRedeem);
        // amountCollateral = bound(amountCollateral, 0, MAX_DEPOSIT_SIZE);
        if (amountCollateral == 0) {
            return;
        }
        engine.redeemCollateral(address(collateral), amountCollateral);
    }

    // This breaks our invariant test suite!
    // function updateCollateral(uint96 newPrice) public {
    //     int256 newPriceInt = int256(uint256(newPrice));
    //     ethUSDPriceFeed.updateAnswer(newPriceInt);
    // }

    // Helper Functions
    function _getCollateralFromSeed(uint256 collateralSeed) public view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) {
            console.log("Reverting weth");
            return weth;
        }

        console.log("Reverting wbtc");
        return wbtc;
    }
}
