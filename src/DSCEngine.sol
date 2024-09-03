// SPDX-License-Identifier: MIT

// layout of contract:
// version
// imports
// errors
// interfaces, libraries, contracts
// Type declaration
// State Variables
// Events
// Modifiers
// Functions

// Layout of functions
// Constructors
// receive functions (if applicable)
// fallback function (if exists)
// external
// public
// internal
// private
// view and pure functions

pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockV3Aggregator} from "@chainlink/contracts/src/v0.8/tests/MockV3Aggregator.sol";
import {OracleLib} from "./libraries/OracleLib.sol";
/**
 * @title DSCEngine
 * @author Daniel Cha
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg.
 * This stablecoin has the properties:
 * - Exogenous Collateral
 * - Dollar Pegged
 * - Algoritmically Stable
 *
 * It is similar to DAI if DAI has no governance, no fess, and was only backed by WETH and WBTC
 *
 * Our DSC system should always be "overcollateralized". At no point, should the value of all collateral <= the $ backed value of all the DSC)
 *
 * @notice This contract is the core of the DSC System, it handles all the logic for minting and redeeming DSC, as well as depositing and withdrawing collateral
 * @notice thIS CONTRACT IS very LOOSELY BASED ON THE mAKERdao dss (DAI) system.
 */

contract DSCEngine is ReentrancyGuard {
    //////////////
    // Errors//
    //////////////
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressessAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    ///////////////
    // Type//
    //////////////
    using OracleLib for MockV3Aggregator;
    ///////////////
    // State Vars//
    //////////////

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // this means a 10% bonus

    mapping(address token => address priceFeed) private s_priceFeeds; //tokenToPriceFeed
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited; // we are mapping the user to another mapping of the token amount
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    ///////////////
    // Events//
    //////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );

    //////////////
    // Modifiers//
    //////////////
    modifier moreThanZero(uint256 amount) {
        if (amount <= 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        // if token isn't allowed than revert
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    ///////////////
    // Functions//
    //////////////
    constructor(address[] memory tokenAddressess, address[] memory priceFeedAddresses, address dscAddress) {
        // USD Price Feeds
        if (tokenAddressess.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressessAndPriceFeedAddressesMustBeSameLength();
        }
        for (uint256 i = 0; i < tokenAddressess.length; i++) {
            s_priceFeeds[tokenAddressess[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddressess[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    //////////////
    // External Functions//
    //////////////

    /*
    * @param tokenCollateralAddress, The address of the token to deposit as collateral
    * @param amountCollateral The amount of collateral to deposit
    * @param amountDscToMint The amount of decentralized stablecoin to mint
    * @notice this function will deposit your collateral and mint DSC in one transaction
    */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /*
    *notice fllows CEI (Check, effects, interactions)
    * @param tokenCollateralAddress is the address of the token to deposit as collateral
    * @param amountCollateral the amount of collateral to deposit
    */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    // in order to redeem collateral:

    // 1. health factor must be over 1 after collateral pulled
    // CEI: Check, effects, interactions
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /* 
    * @param tokenCollateralAddress The collateral address to redeem
    * @param amountCollateral The amount of collateral to redeem
    * @param amountDscToBurn the amount of DSC to burn
    * this function burns DSC and redeems underlying collateral in one transaction
    */
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
    {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
    }

    /*
    * @notice follows CEI
    @param amountDscToMint The amount of decentralized stablecoin to mint
    @notice they must have more collateral value than the minimum threshold
    */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }
    // Do we need to check if this breaks health factor?

    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // I don't think this would ever hit, the transferFrom already has an error that indicates
    }
    // $100 eth backing $50 dsc
    // $20 eth backing $50 dsc <- dsc isn't worth $1!

    // $75 backing $50 DSC
    // liquidator take take $75 backing and burns off the $50 DSC

    // if someone is almost undercollateralized, we will pay you to liquidate them!

    /*
    * @param collateral the erco20 collateral to liquidate
    * @param user the user who has broken the health factor. Their collateral _healthfactor should be below MIN_HEALTH_FACTOR
    * @param debToCover the amount of DSC you want to burn to improve the users health factor
    * @notice you can partially liquidate a user.
    * @notice you will get a liquidation bonus for taking the users funds
    * This function working assumes the protocol will be roughly 200% overcollateralized
    * in order for this to work
    * @notice a known bug would be if the protocol were 100% or less collateralized, then 
    * we woulnd't be able to incentive the liquidators
    * For example, if the price of the collateral plummeted before anyone could be liquidated
    */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }
        // we want to burn their DSC debt
        // take their collateral
        // Bad User: $140 eth, $100 DSC
        // debtToCover = $100
        // $100 of DSC = ??? ETH?
        // 0.05
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        // and give them a 10% bonus
        // so we are giving the liquidator $110 of WETH for 100 DSC
        // We should implement a feature to liquidate in the event the protocol is insolvent
        // and sweep extra amount into a treasury

        // 0.05 ETH * 0.1 = .0055
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(user, msg.sender, collateral, totalCollateralToRedeem);
        // we need to burn the DSC
        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /////////////////////////////////
    //Private/ & Internal Functions//
    /////////////////////////////////

    /*
    * @dev low-level internal function do not call unless the function callig it is checking for health factors being broken
    */

    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) public {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral)
        private
    {
        //mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited; // we are mapping the user to another mapping of the token amount
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /* 
    * returns how close to liquidation a user is
    * if a user goes below 1, then they can get liquidated
    */
    function _healthFactor(address user) public view returns (uint256) {
        // total DSC minted
        // total collateral value
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        if (totalDscMinted == 0) {
            return type(uint256).max; // Return the highest possible value indicating a "healthy" state
        }
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        // $1000 in eth * 50 = 50,000 / 100 = 500 collateralAdjusted, essentially cutting the collateral by 50%
        // Mints 600 DSC
        // 500 * 5 = 2500/1800 returns a score of 4.16

        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }
    //1. check health factor (do they have enough collateral)
    //2. revert if they dont have a good health factor

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    /////////////////////////////////
    //Public & External View Functions//
    /////////////////////////////////

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        MockV3Aggregator priceFeed = MockV3Aggregator(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION * amount)) / PRECISION;
    }

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        // price of ETH (token)
        // $/ ETH
        // $2000 / ETH, $1000 = 0.5 ETH
        MockV3Aggregator priceFeed = MockV3Aggregator(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // ($10e18 * 1e18 / (2000e8 * 1e10)
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }

    function getDsceBalanceOfUser(address user) external view returns (uint256 totalDscMinted) {
        totalDscMinted = s_DSCMinted[user];
    }

    function getPrecision() external view returns (uint256 precision) {
        precision = PRECISION;
    }

    function getAdditionalFeedPrecision() external view returns (uint256 additionalFeedPrecision) {
        additionalFeedPrecision = ADDITIONAL_FEED_PRECISION;
    }

    function getDsc() external view returns (address dscAddress) {
        dscAddress = address(i_dsc);
    }

    function getCollateralTokens() external view returns (address[] memory collateralTokens) {
        collateralTokens = s_collateralTokens;
    }

    function getLiquidationPrecision() external view returns (uint256 liquidationPrecision) {
        liquidationPrecision = LIQUIDATION_PRECISION;
    }

    function getLiquidationThreshold() external view returns (uint256 liquidationThreshold) {
        liquidationThreshold = LIQUIDATION_THRESHOLD;
    }

    function getMinHealthFactor() external view returns (uint256 healthFactor) {
        healthFactor = MIN_HEALTH_FACTOR;
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256 totalAmount) {
        totalAmount = s_collateralDeposited[user][token];
    }

    function getLiquidationBonus() external view returns (uint256 liquidationBonus) {
        liquidationBonus = LIQUIDATION_BONUS;
    }

    function getCollateralTokenPriceFeed(address token) external view returns (MockV3Aggregator priceFeed) {
        priceFeed = MockV3Aggregator(s_priceFeeds[token]);
    }
}
// uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
// uint256 private constant PRECISION = 1e18;
// uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralized
// uint256 private constant LIQUIDATION_PRECISION = 100;
// uint256 private constant MIN_HEALTH_FACTOR = 1e18;
// uint256 private constant LIQUIDATION_BONUS = 10; // this means a 10% bonus
