// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.10;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";

library PoolLibrary {
    using SafeMath for uint256;

    uint256 public constant PRICE_PRECISION = 1e6;

    struct MintFFParams {
        uint256 stockPrice;
        uint256 colPriceUsd;
        uint256 stockAmount;
        uint256 collateralAmount;
        uint256 colRatio;
    }

    struct BuybackStockParams {
        uint256 excessCollateralDollarValueD18;
        uint256 stockPrice;
        uint256 colPriceUsd;
        uint256 stockAmount;
    }

    function calcMint1t1Stable(uint256 colPrice, uint256 collateralAmountD18) public pure returns (uint256) {
        return (collateralAmountD18.mul(colPrice)).div(1e6);
    }

    function calcMintAlgorithmicStable(uint256 stockPrice, uint256 _amount) public pure returns (uint256) {
        return _amount.mul(stockPrice).div(1e6);
    }

    function calcMintFractionalStable(MintFFParams memory params) internal pure returns (uint256, uint256) {
        uint256 stockDollarValueD18;
        uint256 cDollarValueD18;

        // Scoping for stack concerns
        {
            stockDollarValueD18 = params.stockAmount.mul(params.stockPrice).div(1e6);
            cDollarValueD18 = params.collateralAmount.mul(params.colPriceUsd).div(1e6);
        }
        uint256 calculatedStockDollarValueD18 = (cDollarValueD18.mul(1e6).div(params.colRatio)).sub(
            cDollarValueD18
        );

        uint256 calculatedStockNeeded = calculatedStockDollarValueD18.mul(1e6).div(params.stockPrice);

        return (cDollarValueD18.add(calculatedStockDollarValueD18), calculatedStockNeeded);
    }

    function calcRedeem1t1Stable(uint256 colPriceUsd, uint256 _amount) public pure returns (uint256) {
        return _amount.mul(1e6).div(colPriceUsd);
    }

    // Must be internal because of the struct
    function calcBuyBackStock(BuybackStockParams memory params) internal pure returns (uint256) {
        // If the total collateral value is higher than the amount required at the current collateral ratio then buy back up to the possible FXS with the desired collateral
        require(params.excessCollateralDollarValueD18 > 0, "No excess collateral to buy back!");

        // Make sure not to take more than is available
        uint256 stockDollarValueD18 = params.stockAmount.mul(params.stockPrice).div(1e6);
        require(
            stockDollarValueD18 <= params.excessCollateralDollarValueD18,
            "You are trying to buy back more than the excess!"
        );

        uint256 collateralEquivalentD18 = stockDollarValueD18.mul(1e6).div(params.colPriceUsd);

        return (collateralEquivalentD18);
    }

    // Returns value of collateral that must increase to reach recollateralization target (if 0 means no recollateralization)
    function recollateralizeAmount(
        uint256 totalSupply,
        uint256 globalCollateralRatio,
        uint256 globalCollatValue
    ) public pure returns (uint256) {
        uint256 targetCollatValue = totalSupply.mul(globalCollateralRatio).div(1e6);
        // We want 18 decimals of precision so divide by 1e6; total_supply is 1e18 and globalCollateralRatio is 1e6
        // Subtract the current value of collateral from the target value needed, if higher than 0 then system needs to recollateralize
        return targetCollatValue.sub(globalCollatValue);
        // If recollateralization is not needed, throws a subtraction underflow
        // return(recollateralization_left);
    }

    function calcRecollateralizeStableInner(
        uint256 collateralAmount,
        uint256 colPrice,
        uint256 globalCollatValue,
        uint256 stableTotalSupply,
        uint256 globalCollateralRatio
    ) public pure returns (uint256, uint256) {
        uint256 collatValueAttempted = collateralAmount.mul(colPrice).div(1e6);
        uint256 effectiveCollateralRatio = globalCollatValue.mul(1e6).div(stableTotalSupply);
        //returns it in 1e6
        uint256 recollatPossible = (
        globalCollateralRatio.mul(stableTotalSupply).sub(stableTotalSupply.mul(effectiveCollateralRatio))
        ).div(1e6);

        uint256 amountRecollat;
        if (collatValueAttempted <= recollatPossible) {
            amountRecollat = collatValueAttempted;
        } else {
            amountRecollat = recollatPossible;
        }

        return (amountRecollat.mul(1e6).div(colPrice), amountRecollat);
    }
}
