// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import "./AggregatorV3Interface.sol";

contract ChainlinkETHUSDPriceConsumer {
    AggregatorV3Interface internal _priceFeed;

    constructor(address _aggregator) public {
        _priceFeed = AggregatorV3Interface(_aggregator);
    }

    /**
     * Returns the latest price
     */
    function getLatestPrice() public view returns (int256) {
        (uint80 roundID, int256 price, , uint256 updatedAt, uint80 answeredInRound) = _priceFeed.latestRoundData();
        require(price >= 0 && updatedAt != 0 && answeredInRound >= roundID, "Invalid chainlink price");

        return price;
    }

    function getDecimals() public view returns (uint8) {
        return _priceFeed.decimals();
    }
}
