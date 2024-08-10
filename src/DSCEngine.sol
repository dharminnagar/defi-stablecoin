//SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {DecentralisedStableCoin} from "./DecentralisedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

/*
 * @title DSCEngine
 * @author Dharmin Nagar
 *
 * This system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg.
 * This stable coin has the properties:
 * - Exogenous Collateral
 * - Dollar pegged
 * - Algorithmically Stable
 *
 * Our system should always be "overcollaterized" to ensure that system can always pay back the DSC tokens minted. At no point, should the value of all collateral <= the $ backed value of all DSC tokens
 *
 * It is similar to DAI if DAI had no governance, no fees, and was only backed by wETH and wBTC
 *
 * @notice This contract is the core of the DSC system. It handles all the logic of minting and redeeming DSC, as well as depositing and withdrawing collateral
 * @notice This contract is VERY loosely based on the MakerDAO DSS (DAI) system
 */
contract DSCEngine is ReentrancyGuard {
    ////////////
    // Errors //
    ////////////
    error DSCEngine__MustBeGreaterThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__DepositCollateralFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__TansferFailed();
    error DSCEngine__HealthFactorOkay();
    error DSCEngine__HealthFactorNotImproved();

    ///////////
    // Types //
    ///////////
    using OracleLib for AggregatorV3Interface;

    ///////////////
    // Constants //
    //////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10;

    /////////////
    // Storage //
    /////////////
    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256) private s_dscMinted;
    address[] private s_collateralTokens;

    DecentralisedStableCoin private immutable i_dsc;

    /////////////
    // Events //
    ////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );

    ///////////////
    // Modifiers /
    //////////////
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__MustBeGreaterThanZero();
        }
        _;
    }

    modifier isAllowedToken(address tokenAddress) {
        if (s_priceFeeds[tokenAddress] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    ///////////////
    // Functions //
    ///////////////
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddress, address DSCAddress) {
        // USD Price Feeds
        if (tokenAddresses.length != priceFeedAddress.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddress[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }

        i_dsc = DecentralisedStableCoin(DSCAddress);
    }

    ////////////////////////
    // External Functions //
    ////////////////////////

    /*
     * @param tokenCollateralAddress The address of the token to be deposited as collateral
     * @param amountCollateral The amount of the token to be deposited as collateral
     * @notice This function will deposit collateral and mint DSC in one function
    */
    function depositCollateralAndMintDSC(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountToMint)
        external
    {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDSC(amountToMint);
    }

    /*
     * @notice Follows CEI(Checks-Effects-Interactions) pattern
     * @param tokenCollateralAddress The address of the token to be deposited as collateral
     * @param amountCollateral The amount of the token to be deposited as collateral
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        (bool success) = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);

        if (!success) {
            revert DSCEngine__DepositCollateralFailed();
        }
    }

    /*
     * @param collateralAddress The address of the token to be redeemed
     * @param amountCollateral The amount of the token to be redeemed
     * @param amountDSCToBurn The amount of DSC to burn
     * This functions redeems collateral and burns DSC in one function
     */
    function redeemCollateralForDSC(address collateralAddress, uint256 amountCollateral, uint256 amountDSCToBurn)
        external
    {
        burnDSC(amountDSCToBurn);
        redeemCollateral(collateralAddress, amountCollateral);
        // Redeem Collateral already checks health factor
    }

    // In order to redeem collateral:
    // 1. Health factor must be above 1 after redeeming

    function redeemCollateral(address collateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, collateralAddress, amountCollateral);

        _revertIfHealthFactorIsBroken(msg.sender);
    }

    // Do we need to check Health Factor? No, because we are burning DSC. It removes the debt, how can removing the debt make the health factor worse?
    function burnDSC(uint256 amount) public moreThanZero(amount) {
        _burnDSC(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // I don't think it'll ever hit this...
    }

    /*
    * @notice Follows CEI(Checks-Effects-Interactions) pattern
    * @param amountToMint The amount of DSC to mint
    * @notice They must have more collateral value than the DSC minted 
    */
    function mintDSC(uint256 amountToMint) public moreThanZero(amountToMint) nonReentrant {
        s_dscMinted[msg.sender] += amountToMint;

        _revertIfHealthFactorIsBroken(msg.sender);

        bool minted = i_dsc.mint(msg.sender, amountToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    // If we do start getting undercollateralized, we need to liquidate their position
    // $100ETH -> $50DSC
    // $20ETH -> $50DSC then we need to liquidate

    // $75ETH -> $50DSC
    // Liquidator takes $75ETH and burns off the $50 DSC

    // If someone is almost undercollateraised, we will pay you to liquidate them!

    /**
     * @param collateralAddress The ERC20 collateral address to be liquidated
     * @param user User which has broken health factor. Their _healthfactor should be under MIN_HEALTH_FACTOR
     * @param debtToCover Amount of DSC to have to burn to improve users health factor
     * @notice You can partially liquidate a user
     * @notice You will get a liquidation bonus for taking a user's fund
     * @notice This function working assumes the protocol will be 200% overcollateralized in order for this to work
     * @notice A known bug is that if the protocol were 100% collateralized, this function would not work, then we wouldn't be able to incentivize liquidators
     * For example, if the price of the collateral plummeted before anyone could be liquidated
     *
     * Follows CEI: Checks-Effects-Interactions pattern
     */
    function liquidate(address collateralAddress, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        // Need to check health factor of the user
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOkay();
        }

        // We need to burn their DSC "debt"
        // And take their collateral
        // Bad User: $140ETH -> $100DSC
        // debtToCover = $100
        // $100DSC == ??? ETH
        // 0.05 ETH
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUSD(collateralAddress, debtToCover);
        // And give them 10% bonus
        // So we are giving the liquidator 110% of WETH for 100 DSC
        // We should implement a feature to liquidate in the event the protocol is insolvent
        // And sweep extra amounts to the treasury
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;

        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(user, msg.sender, collateralAddress, totalCollateralToRedeem);

        // Burn the DSC
        _burnDSC(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor < startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }

        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function healthFactor() external view {}

    ///////////////////////////////////////
    // Private & Internal View Functions //
    ///////////////////////////////////////

    function _getAccountInfo(address user) private view returns (uint256 dscMinted, uint256 collateralValue) {
        // 1. Get the amount of DSC minted by the user
        // 2. Get the value of all collateral deposited by the user

        dscMinted = s_dscMinted[user];
        collateralValue = getAccountCollateralValue(user);
    }

    function _redeemCollateral(address from, address to, address collateralAddress, uint256 amountCollateral) private {
        s_collateralDeposited[from][collateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, collateralAddress, amountCollateral);
        bool success = IERC20(collateralAddress).transfer(to, amountCollateral);

        if (!success) {
            revert DSCEngine__TansferFailed();
        }
    }

    /**
     * @dev Low - Level Internal Function, do not call until function calling it is checking health factors being broken
     */
    function _burnDSC(uint256 amount, address onBehalfOf, address dscFrom) private {
        s_dscMinted[onBehalfOf] -= amount;

        bool success = i_dsc.transferFrom(dscFrom, address(this), amount);
        // This is hypothetically unreachable, but it's good to have
        if (!success) {
            revert DSCEngine__TansferFailed();
        }
        i_dsc.burn(amount);
    }

    /* 
    * Returns how close to liquidation the user is
    * If a user goes below 1, they are liquidated
    */
    function _healthFactor(address user) private view returns (uint256) {
        // 1. Calculate the value of all collateral
        // 2. Calculate the value of all DSC minted
        // 3. Return the ratio of collateral value to DSC minted value

        (uint256 dscMinted, uint256 collateralValue) = _getAccountInfo(user);

        return _calculateHealthFactor(dscMinted, collateralValue);
    }

    function _calculateHealthFactor(uint256 dscMinted, uint256 collateralValueInUSD) internal pure returns (uint256) {
        if (dscMinted == 0) return type(uint256).max;

        uint256 collateralAdjusted = (collateralValueInUSD * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return ((collateralAdjusted * PRECISION) / dscMinted);
    }

    // 1. Check health factor (do they have enough collateral?)
    // 2. Revert if they don't
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    ///////////////////////////////////////
    // Public & External View Functions //
    ///////////////////////////////////////

    function getTokenAmountFromUSD(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();

        return ((usdAmountInWei * PRECISION) / uint256(price)) / ADDITIONAL_FEED_PRECISION;
    }

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValue) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValue += getUSDValue(token, amount);
        }
        return totalCollateralValue;
    }

    function getUSDValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();

        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function getAccountInfo(address user) external view returns (uint256 dscMinted, uint256 collateralValue) {
        (dscMinted, collateralValue) = _getAccountInfo(user);
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }
}
