// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import "../Oracle/AggregatorV3Interface.sol";

contract MockChainLink is AggregatorV3Interface {
    int256 public lastAnswer = 1;

    function setAnswer(int256 _answer) external {
        lastAnswer = _answer;
    }

    function getRoundData(uint80 _roundId)
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return (1, lastAnswer, 1, 1, 1);
    }

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return (1, lastAnswer, 1, 1, 1);
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function description() external pure returns (string memory) {
        return "";
    }

    function version() external pure returns (uint256) {
        return 1;
    }
}
