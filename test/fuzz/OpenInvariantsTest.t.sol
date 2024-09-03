// // SPDX-License-identifier: MIT
// // Have our invariants aka properties of the system

// // What are our invariants? What are the properties of the system that should always hold?

// //1. The total supply of DSC should be less than the total value of collateral
// //2. Getter view functions should never revert <- evergreen invariant

// pragma solidity ^0.8.18;

// import {Test, console} from "forge-std/Test.sol";
// import {StdInvariant} from "forge-std/StdInvariant.sol";
// import {DeployDsc} from "../../script/DeployDSC.s.sol";
// import {DSCEngine} from "../../src/DSCEngine.sol";
// import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
// import {HelperConfig} from "../../script/HelperConfig.s.sol";
// import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// contract OpenInvariantsTest is StdInvariant, Test {
//     DeployDsc deployer;
//     DSCEngine dsce;
//     DecentralizedStableCoin dsc;
//     HelperConfig config;
//     address weth;
//     address wbtc;

//     function setUp() external {
//         deployer = new DeployDsc();
//         (dsc, dsce, config) = deployer.run();
//         (,, weth, wbtc,) = config.activeNetworkConfig();
//         targetContract(address(dsce)); // <- just by adding this, we're telling foundtry to just kinda go wild on this contract.
//     }

//     function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
//         // get the value of all the collateral in the protocol
//         // compare it to all the debt in (dsc)
//         uint256 totalSupply = dsc.totalSupply(); // total supply of dsc in the entire world, only way to mint dsc is through the engine
//         uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dsce)); // Total amount of weth sent to the contract
//         uint256 totalBtcDeposited = IERC20(wbtc).balanceOf(address(dsce)); // Total amount of btc deposited in the contract

//         uint256 wethValue = dsce.getUsdValue(weth, totalWethDeposited);
//         uint256 wbtcValue = dsce.getUsdValue(wbtc, totalBtcDeposited);

//         console.log("weth value", wethValue);
//         console.log("wbtc value", wbtcValue);
//         console.log("total supply", totalSupply);

//         assert(wethValue + wbtcValue >= totalSupply);
//     }
// }
