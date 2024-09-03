// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";

import {DeployDsc} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "@chainlink/contracts/src/v0.8/tests/MockV3Aggregator.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DSCEngineTest is Test {
    DeployDsc deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;

    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant MORE_THAN_COLLATERAL = 11 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant AMOUNT_MINTED = 5 ether;
    uint256 public constant AMOUNT_BURNED = 1 ether;
    uint256 public constant BREAK_HEALTH_FACTOR = 6 ether;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant PRECISION = 1e18;

    function setUp() public {
        deployer = new DeployDsc();
        (dsc, dsce, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth,,) = config.activeNetworkConfig();
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    ////////////////////////
    //Constructor Tests/////
    ////////////////////////
    address[] public tokenAddresses;
    address[] public priceFeedAddressess;

    function testRevertIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddressess.push(ethUsdPriceFeed);
        priceFeedAddressess.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressessAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddressess, address(dsc));
    }

    function testRevertsIfWrongToken() public {
        // create an instance of ERC20 that is not allowed
        ERC20Mock wrongToken = new ERC20Mock("WrongToken", "WRONG", USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        wrongToken.approve(address(dsce), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dsce.depositCollateral(address(wrongToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    //////////////////
    //Price Tests/////
    //////////////////

    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18; // 15 eth
        // 15e18 * 2000/ETH = 30,000e18;
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmount = 100 ether;
        // $2000 per ETH, 100...
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = dsce.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedWeth, actualWeth);
    }

    ///////////////////////////////////
    //Redeem Collateral Tests//
    //////////////////////////////////

    function testGetAccountInformation() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_MINTED);
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        uint256 expectedTotalDscMinted = 5 ether;
        uint256 expectedCollateralValueInUsd = dsce.getAccountCollateralValue(USER);
        assertEq(expectedTotalDscMinted, totalDscMinted);
        assertEq(expectedCollateralValueInUsd, collateralValueInUsd);
        vm.stopPrank();
    }
    // 20000000000000000000000
    // 20000000000000000000

    // function getAccountInformation(address user)
    //     external
    //     view
    //     returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    // {
    //     (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
    // }
    function testRevertIfTransferFails() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.expectRevert();
        dsce.redeemCollateral(weth, MORE_THAN_COLLATERAL);
    }

    function testRedeemCollateralSuccessful() public {
        vm.startPrank(USER);
        // record initial weth balance
        uint256 initialBalance = ERC20Mock(weth).balanceOf(USER);

        // Approve an deposit weth as collateral
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);

        //check users balance after redemption
        dsce.redeemCollateral(weth, AMOUNT_COLLATERAL);
        uint256 finalBalance = ERC20Mock(weth).balanceOf(USER);
        assertEq(finalBalance, initialBalance);
    }
    // 10000000000000000000
    // 10000000000000000000

    /////////////////////////////
    //Deposit Collateral Tests//
    /////////////////////////////

    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock("RAN", "RAN", USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dsce.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totaldscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);

        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(expectedTotalDscMinted, totaldscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
    }

    function testCanDepositCollateralWithoutMinting() public depositedCollateral {
        // modifier, user deposits ETH but hasn't minted yet
        // test is asserting that the user DSCE balance is 0, while still having the option to push DSCE.
        uint256 userDsceBalance = dsce.getDsceBalanceOfUser(USER);
        assertEq(userDsceBalance, 0);
    }

    ///////////////////////////////////
    //DepositCollateralandMintDsc Tests//
    //////////////////////////////////

    // Modifier to account for minting collateral

    modifier depositedCollateralandMintedDsce() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_MINTED);
        vm.stopPrank();
        _;
    }

    function testUserSuccessfullyMinted() public depositedCollateralandMintedDsce {
        uint256 userDsceBalance = dsce.getDsceBalanceOfUser(USER);
        assertEq(userDsceBalance, AMOUNT_MINTED);
    }

    // function testRevertsIfMintedDscBreaksHealthFactor() public {
    //     (, int256 price,,,) = AggregatorV3Interface(ethUsdPriceFeed).latestRoundData(); // This is gathering the price of our ETH to USD
    //    uint256 amountToMint = (AMOUNT_COLLATERAL * (uint256(price) * dsce.getAdditionalFeedPrecision())) / dsce.getPrecision();
    //     vm.startPrank(USER);
    //     ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

    //     uint256 expectedHealthFactor =
    //     dsce._healthFactor(amountToMint, dsce.getUsdValue(weth, AMOUNT_COLLATERAL));
    //     vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
    //     dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
    //     vm.stopPrank();
    // }

    ///////////////////////////////////
    //MintDsc Tests//
    //////////////////////////////////
    function testRevertsIfMintAmountIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_MINTED);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.mintDsc(0);
        vm.stopPrank();
    }
    // amount collateral, amount_minted

    function testIfMintBalanceIncreases() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_MINTED);
        dsce.mintDsc(AMOUNT_MINTED);
        uint256 userDsceBalance = dsce.getDsceBalanceOfUser(USER);
        assertEq(userDsceBalance, AMOUNT_MINTED * 2);
        vm.stopPrank();
    }

    function testRevertIfMintReverts() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_MINTED);
        vm.mockCall(address(dsc), abi.encodeWithSelector(DecentralizedStableCoin.mint.selector), abi.encode(false));
        vm.expectRevert(DSCEngine.DSCEngine__MintFailed.selector);
        dsce.mintDsc(1000 ether);
        vm.stopPrank();
    }

    ////////////////////
    /////burnDsc Tests//
    ////////////////////
    function testIfDsceIsBurned() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        dsce.mintDsc(AMOUNT_MINTED);
        dsc.approve(address(dsce), AMOUNT_BURNED);
        dsce.burnDsc(AMOUNT_BURNED);
        uint256 userDsceBalance = dsce.getDsceBalanceOfUser(USER);
        assertEq(userDsceBalance, (AMOUNT_MINTED - AMOUNT_BURNED));
        vm.stopPrank();
    }

    function testRevertBurnIfHealthFactorIsBroken() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);

        dsce.mintDsc(AMOUNT_MINTED);

        dsc.approve(address(dsce), BREAK_HEALTH_FACTOR); // because of our transfer error, this should already fail from not our _burnDsc custom error, but the transfer one from ERC20
        // This expect revert will ensure if the burn amount is the same as the mint or is more than the mint, then we revert
        vm.expectRevert();
        dsce.burnDsc(BREAK_HEALTH_FACTOR);
        vm.stopPrank();
    }

    ////////////////////
    //healthFactor Tests//
    ////////////////////

    function testHealthFactorCalulcationBeforeMinting() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        uint256 expectedHealthBeforeDeposit = type(uint256).max;
        assertEq(expectedHealthBeforeDeposit, dsce._healthFactor(USER));
        vm.stopPrank();
    }

    function testCollateralAdjustedForThreshold() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_MINTED);
        uint256 collateralValueInUsd = dsce.getUsdValue(weth, AMOUNT_COLLATERAL);
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        uint256 expectedHealthFactor = (collateralAdjustedForThreshold * PRECISION) / AMOUNT_MINTED;
        uint256 actualHealthFactor = dsce._healthFactor(USER);
        assertEq(expectedHealthFactor, actualHealthFactor);
        vm.stopPrank();
    }

    ////////////////////
    //Important Getters Tests//
    ////////////////////
    function testGetDsc() public {
        address dscAddress = dsce.getDsc();
        assertEq(dscAddress, address(dsc));
    }

    function testGetCollateralToken() public {
        address[] memory firstCollateralTokens = dsce.getCollateralTokens();
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        assertEq(firstCollateralTokens[0], weth);
    }

    function testLiquidationPrecision() public {
        uint256 expectedLiquidationPrecision = 100;
        uint256 actualLiquidationPrecision = dsce.getLiquidationPrecision();
        assertEq(expectedLiquidationPrecision, actualLiquidationPrecision);
    }

    function testPrecisionValues() public {
        uint256 expectedPrecision = 1e18;
        uint256 expectedAdditionalPrecision = 1e10;
        uint256 actualPrecision = dsce.getPrecision();
        uint256 actualAdditionalPrecision = dsce.getAdditionalFeedPrecision();
        assertEq(expectedPrecision, actualPrecision);
        assertEq(expectedAdditionalPrecision, actualAdditionalPrecision);
    }

    function testLiquidationThreshold() public {
        uint256 expectedLiquidationThreshold = 50;
        uint256 actualLiquidationThreshold = dsce.getLiquidationThreshold();
        assertEq(expectedLiquidationThreshold, actualLiquidationThreshold);
    }

    function testMinHealthFactor() public {
        uint256 expectedMinHealthFactor = 1e18;
        uint256 actualMinHealthFactor = dsce.getMinHealthFactor();
        assertEq(expectedMinHealthFactor, actualMinHealthFactor);
    }
}
// uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
// uint256 private constant PRECISION = 1e18;
//    function getPrecision() external view returns (uint256 precision) {
//         precision = PRECISION;
//     }

//     function getAdditionalFeedPrecision() external view returns (uint256 additionalFeedPrecision) {
//         additionalFeedPrecision = ADDITIONAL_FEED_PRECISION;
//     }

// uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralized
// uint256 private constant LIQUIDATION_PRECISION = 100;
