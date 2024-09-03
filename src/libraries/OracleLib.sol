// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {MockV3Aggregator} from "@chainlink/contracts/src/v0.8/tests/MockV3Aggregator.sol";

/*
* @title OracleLib
* @author Daniel Cha
* @notice This library is used to check the CL oracle for stable data.
* If a price is stable, the function will revert and render the DSCEngine unstable
* We want DSCEngine to freeze if prices become stale.
* If the chainlink netowrk explodes and you have a lot of money locked in the protocol...sorry!
*/

library OracleLib {
    error OrcaleLib__StalePrice();

    uint256 private constant TIMEOUT = 3 hours; // 3 * 60 * 60 = 10800 seconds or 3 hours

    function staleCheckLatestRoundData(MockV3Aggregator priceFeed)
        public
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            priceFeed.latestRoundData();
        uint256 secondsSince = block.timestamp - updatedAt; // seconds since pricefeed updated
        if (secondsSince > TIMEOUT) revert OrcaleLib__StalePrice();
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}
