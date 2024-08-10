//SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralisedStableCoin} from "../../src/DecentralisedStableCoin.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";
import {MockMoreDebtDSC} from "../mocks/MockMoreDebtDSC.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralisedStableCoin dsc;
    DSCEngine engine;
    HelperConfig config;
    address ethUSDPriceFeed;
    address btcUSDPriceFeed;
    address weth;

    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_BALANCE = 100 ether;
    uint256 amountToMint = 100 ether;

    // Liquidator
    address public liquidator = makeAddr("liquidator");
    uint256 public collateralToCover = 20 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, engine, config) = deployer.run();
        (ethUSDPriceFeed, btcUSDPriceFeed, weth,,) = config.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_BALANCE);
    }

    ///////////////////////
    // Constructor Tests //
    ///////////////////////

    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeed() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUSDPriceFeed);
        priceFeedAddresses.push(btcUSDPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    /////////////////
    // Price Tests //
    /////////////////
    function testgetUSDValue() public view {
        uint256 ethAmount = 15e18;
        // 15e18 * 2000/ETH = 30000e18
        uint256 expectedUSDValue = 30000e18;
        uint256 usdValue = engine.getUSDValue(weth, ethAmount);
        assertEq(usdValue, expectedUSDValue);
    }

    function testGetTokenAmountFromUSD() public view {
        uint256 usdAmount = 100 ether;
        // $2000 / ETH, $100 USD = 0.05 ETH
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = engine.getTokenAmountFromUSD(weth, usdAmount);
        assertEq(actualWeth, expectedWeth);
    }

    ////////////////////////////
    // depositCollateral Tests //
    ////////////////////////////
    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__MustBeGreaterThanZero.selector);
        engine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock("RanToken", "RAN", USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        engine.depositCollateral(address(ranToken), STARTING_BALANCE);
        vm.stopPrank();
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 dscMinted, uint256 collateralValue) = engine.getAccountInfo(USER);

        uint256 expectedTotalDSCMinted = 0;
        uint256 expectedDepositAmount = engine.getTokenAmountFromUSD(weth, collateralValue);

        assertEq(dscMinted, expectedTotalDSCMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
    }

    ////////////////////////////
    // redeemCollateral Tests //
    ////////////////////////////
    function testRevertsIfRedeemCollateralZero() public {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__MustBeGreaterThanZero.selector);
        engine.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsIfRedeemCollateralIsMoreThanUserHas() public {
        vm.startPrank(USER);
        vm.expectRevert();
        engine.redeemCollateral(weth, 100e18);
        vm.stopPrank();
    }

    function testCanRedeemCollateral() public depositedCollateral {
        vm.prank(USER);
        engine.redeemCollateral(weth, AMOUNT_COLLATERAL);

        uint256 userBalance = ERC20Mock(weth).balanceOf(USER);
        assertEq(userBalance, STARTING_BALANCE);
    }

    //////////////////////////////////
    // redeemCollateralForDSC Tests //
    //////////////////////////////////
    function testMustRedeemMoreThanZero() public depositedCollateralAndMintedDSC {
        vm.startPrank(USER);
        dsc.approve(address(engine), amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine__MustBeGreaterThanZero.selector);
        engine.redeemCollateralForDSC(weth, 0, amountToMint);
        vm.stopPrank();
    }

    function testCanRedeemCollateralForDSC() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), amountToMint);
        engine.depositCollateralAndMintDSC(weth, AMOUNT_COLLATERAL, amountToMint);
        dsc.approve(address(engine), amountToMint);
        engine.redeemCollateralForDSC(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    ////////////////////////
    // healthFactor Tests //
    ////////////////////////

    function testProperlyReportsHealthFactor() public depositedCollateralAndMintedDSC {
        uint256 expectedHealthFactor = 100 ether;
        uint256 healthFactor = engine.getHealthFactor(USER);
        // $100 minted with $20,000 collateral at 50% liquidation threshold
        // means that we must have $200 collatareral at all times.
        // 20,000 * 0.5 = 10,000
        // 10,000 / 100 = 100 health factor
        assertEq(healthFactor, expectedHealthFactor);
    }

    function testHealthFactorCanGoBelowOne() public depositedCollateralAndMintedDSC {
        int256 ethUsdUpdatedPrice = 18e8;

        MockV3Aggregator(ethUSDPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        uint256 userHealthFactor = engine.getHealthFactor(USER);
        // 180*50 (LIQUIDATION_THRESHOLD) / 100 (LIQUIDATION_PRECISION) / 100 (PRECISION) = 90 / 100 (totalDscMinted) =
        // 0.9
        assert(userHealthFactor == 0.9 ether);
    }

    ///////////////////
    // mintDSC Tests //
    ///////////////////
    modifier depositedCollateralAndMintedDSC() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateralAndMintDSC(weth, AMOUNT_COLLATERAL, amountToMint);
        console.log(dsc.balanceOf(USER));
        vm.stopPrank();
        _;
    }

    function testRevertsIfMintAmountIsZero() public {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__MustBeGreaterThanZero.selector);
        engine.mintDSC(0);
        vm.stopPrank();
    }

    function testdscIsUpdatedAfterMint() public depositedCollateral {
        vm.startPrank(USER);
        uint256 dscToMint = 10e18;
        engine.mintDSC(dscToMint);
        (uint256 dscMintedAfterMint,) = engine.getAccountInfo(USER);
        vm.stopPrank();

        assertEq(dscMintedAfterMint, dscToMint);
    }

    function testRevertsIfHealthFactorIsBroken() public {
        vm.startPrank(USER);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, 0));
        engine.mintDSC(amountToMint);
        vm.stopPrank();
    }

    function testMintDSC() public depositedCollateral {
        // Check if the mintDSC() function works
        vm.startPrank(USER);

        uint256 dscToMint = 10e18;
        engine.mintDSC(dscToMint);
        (uint256 dscMintedAfterMint,) = engine.getAccountInfo(USER);
        vm.stopPrank();
        assertEq(dscMintedAfterMint, dscToMint);
    }

    ///////////////////
    // burnDSC Tests //
    //////////////////

    // Complete this first

    function testRevertsIfBurnAmountIsZero() public {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__MustBeGreaterThanZero.selector);
        engine.burnDSC(0);
        vm.stopPrank();
    }

    function testCantBurnMoreThanUserHas() public {
        vm.prank(USER);
        vm.expectRevert();
        engine.burnDSC(100e18);
    }

    function testCanBurnDSC() public depositedCollateralAndMintedDSC {
        vm.startPrank(USER);

        dsc.approve(address(engine), amountToMint);
        engine.burnDSC(amountToMint - 1);

        console.log("Burnt Sucessful");
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(USER);
        console.log(dsc.balanceOf(USER));
        assertEq(userBalance, 1);
    }

    /////////////////////
    // liquidate Tests //
    /////////////////////

    function testRevertsIfLiquidateAmountIsZero() public {
        vm.prank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__MustBeGreaterThanZero.selector);
        engine.liquidate(weth, USER, 0);
    }

    function testLiquidateRevertsIfHealthFactorIsOkay() public depositedCollateralAndMintedDSC {
        vm.prank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOkay.selector);
        engine.liquidate(weth, USER, 1);
    }

    function testLiquidateImprovesHealthFactor() public {
        // Arrange - Setup
        MockMoreDebtDSC mockDSC = new MockMoreDebtDSC(address(ethUSDPriceFeed));
        tokenAddresses = [weth];
        priceFeedAddresses = [ethUSDPriceFeed];
        address owner = msg.sender;
        vm.prank(owner);
        DSCEngine mockEngine = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockDSC));
        mockDSC.transferOwnership(address(mockEngine));

        // Arrange - User
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(mockEngine), AMOUNT_COLLATERAL);
        // console.log(mockDSC.balanceOf(USER));
        ERC20Mock(weth).mint(USER, STARTING_BALANCE);
        // console.log(mockDSC.balanceOf(USER));
        mockEngine.depositCollateralAndMintDSC(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();

        // Arrange - Liquidator
        collateralToCover = 1 ether;
        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(mockEngine), AMOUNT_COLLATERAL);
        uint256 debtToCover = 10e18;
        mockEngine.depositCollateralAndMintDSC(weth, collateralToCover, debtToCover);
        mockDSC.approve(address(mockEngine), debtToCover);

        // Act
        int256 ethUSDUpdatedPrice = 18e8;
        MockV3Aggregator(ethUSDPriceFeed).updateAnswer(ethUSDUpdatedPrice);

        // Assert
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorNotImproved.selector);
        mockEngine.liquidate(weth, USER, debtToCover);
        vm.stopPrank();
    }

    /////////////////////////////////////
    // getAccountCollateralValue Tests //
    /////////////////////////////////////

    function testGetAccountCollateralValue() public {
        uint256 expectedCollateralValue = 10 * 2000;
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(weth, 10);
        uint256 collateralValue = engine.getAccountCollateralValue(USER);
        vm.stopPrank();
        assertEq(collateralValue, expectedCollateralValue);
    }
}

// NOTES
// For each function, check all the inputs(edge cases) and flow of execution
// Check if the function is reverting when it is supposed to
// Do this for all the functions
