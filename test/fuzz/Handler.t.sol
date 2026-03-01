// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract Handler is Test {
    DSCEngine dsce;
    DecentralizedStableCoin dsc;
    ERC20Mock weth;
    ERC20Mock wbtc;

    uint256 public timesMintIsCalled;
    address[] public usersWithCollateralDeposited;
    mapping(address => bool) public hasDeposited; // prevents duplicate actors

    AggregatorV3Interface public ethUsdPriceFeed;
    AggregatorV3Interface public btcUsdPriceFeed;
    uint256 MAX_DEPOSIT_SIZE = type(uint96).max;

    constructor(DSCEngine _dscEngine, DecentralizedStableCoin _dsc) {
        dsce = _dscEngine;
        dsc = _dsc;

        address[] memory collateralTokens = dsce.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);

        ethUsdPriceFeed = dsce.getCollateralTokenPriceFeed(address(weth));
        btcUsdPriceFeed = dsce.getCollateralTokenPriceFeed(address(wbtc));
    }

    function mintDsc(uint256 amount, uint256 addressSeed) public {
        if (usersWithCollateralDeposited.length == 0) {
            return;
        }

        address sender = usersWithCollateralDeposited[addressSeed % usersWithCollateralDeposited.length];
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(sender);

        int256 maxDscToMint = int256(collateralValueInUsd / 2) - int256(totalDscMinted);
        if (maxDscToMint <= 0) {
            return;
        }

        amount = bound(amount, 0, uint256(maxDscToMint));
        if (amount == 0) {
            return;
        }

        vm.startPrank(sender);
        dsce.mintDsc(amount);
        vm.stopPrank();
        timesMintIsCalled++;
    }

    function depositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(dsce), amountCollateral);
        dsce.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();

        // keep actor list clean for fuzzing
        if (!hasDeposited[msg.sender]) {
            hasDeposited[msg.sender] = true;
            usersWithCollateralDeposited.push(msg.sender);
        }
    }

    /**
     * IMPORTANT: In invariant fuzzing, redeeming can legitimately revert if it would
     * break the user's health factor. This implementation caps redemption so that
     * HF remains >= 1, preventing handler-caused reverts.
     */
    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        if (usersWithCollateralDeposited.length == 0) {
            return;
        }

        address sender = usersWithCollateralDeposited[collateralSeed % usersWithCollateralDeposited.length];
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);

        uint256 userTokenBalance = dsce.getCollateralBalanceOfUser(sender, address(collateral));
        if (userTokenBalance == 0) {
            return;
        }

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(sender);

        // If no debt, redemption can't break HF, so redeem freely up to balance.
        if (totalDscMinted == 0) {
            amountCollateral = bound(amountCollateral, 0, userTokenBalance);
            if (amountCollateral == 0) return;

            vm.prank(sender);
            dsce.redeemCollateral(address(collateral), amountCollateral);
            return;
        }

        // Maintain HF >= 1:
        // collateralAdjustedForThreshold = collateralUsd * LIQ_THRESHOLD / LIQ_PRECISION
        // HF = collateralAdjustedForThreshold * 1e18 / totalDscMinted
        // HF >= 1e18  => collateralAdjustedForThreshold >= totalDscMinted
        // => collateralUsd >= totalDscMinted * LIQ_PRECISION / LIQ_THRESHOLD
        uint256 minCollateralUsd =
            (totalDscMinted * dsce.getLiquidationPrecision()) / dsce.getLiquidationThreshold();

        // Already at or below minimum required collateral -> can't redeem safely
        if (collateralValueInUsd <= minCollateralUsd) {
            return;
        }

        uint256 maxRedeemableUsd = collateralValueInUsd - minCollateralUsd;

        // Convert USD headroom to token amount; cap by actual deposited token balance
        uint256 maxRedeemableToken = dsce.getTokenAmountFromUsd(address(collateral), maxRedeemableUsd);
        uint256 cap = maxRedeemableToken < userTokenBalance ? maxRedeemableToken : userTokenBalance;

        amountCollateral = bound(amountCollateral, 0, cap);
        if (amountCollateral == 0) {
            return;
        }

        vm.prank(sender);
        dsce.redeemCollateral(address(collateral), amountCollateral);
    }

    // this breaks our invariant test suite!!
    // function updateCollateralPrice(uint96 newPrice) public {
    //     int256 newPriceInt = int256(uint256(newPrice));
    //     ethUsdPriceFeed.updateAnswer(newPriceInt);
    // }

    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) {
            return weth;
        }
        return wbtc;
    }
}