// SPDX-License-Identifier: MIT

// Have our invariants

// What are our invaraints?

// 1. Total supply of DSC should always be less than the total value of collateral

// 2. Getter functions should never revert <-- Evergreen invariant

pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralisedStableCoin} from "../../src/DecentralisedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Handler} from "./Handler.t.sol";

contract OpenInvariantsTest is StdInvariant, Test {
    DeployDSC deployer;
    DSCEngine engine;
    DecentralisedStableCoin dsc;
    HelperConfig config;
    Handler handler;
    address weth;
    address wbtc;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, engine, config) = deployer.run();
        (,, weth, wbtc,) = config.activeNetworkConfig();
        // targetContract(address(engine));
        handler = new Handler(engine, dsc);
        targetContract(address(handler));
    }

    function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
        uint256 totalSupply = dsc.totalSupply();
        uint256 totalWethDeposited = IERC20(weth).balanceOf(address(engine));
        uint256 totalBtcDeposited = IERC20(wbtc).balanceOf(address(engine));

        console.log("Total Weth Deposited: ", totalWethDeposited);
        console.log("Total Btc Deposited: ", totalBtcDeposited);

        uint256 wethValue = engine.getUSDValue(weth, totalWethDeposited);
        uint256 wbtcValue = engine.getUSDValue(wbtc, totalBtcDeposited);

        console.log("Weth Value: ", wethValue);
        console.log("Btc Value: ", wbtcValue);
        console.log("Total Supply: ", totalSupply);
        console.log("Times mint is called: ", handler.timesMintIsCalled());

        assert(wethValue + wbtcValue >= totalSupply);
    }

    function invariant_getterFunctionsShouldNeverRevert() public view {
        engine.getCollateralTokens();
        engine.getTokenAmountFromUSD(weth, 100);
        engine.getAccountCollateralValue(address(this));
        engine.getAccountInfo(address(this));
        engine.getUSDValue(weth, 100);
        engine.getHealthFactor(address(this));
    }
}
