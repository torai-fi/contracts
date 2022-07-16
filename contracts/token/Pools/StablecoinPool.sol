// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.10;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

import "../../interface/IAMOMinter.sol";
import "../../tools/TransferHelper.sol";
import "../../token/Rusd.sol";
import "../../Oracle/UniswapPairOracle.sol";
import "./PoolLibrary.sol";
import "../../tools/Multicall.sol";
import "../../tools/AbstractPausable.sol";
import "../stock/Stock.sol";

contract StablecoinPool is AbstractPausable, Multicall {
    using SafeMath for uint256;


    // Constants for various precisions

    uint256 public constant COLLATERAL_RATIO_PRECISION = 1e6;
    uint256 public constant COLLATERAL_RATIO_MAX = 1e6;


    // Number of decimals needed to get to 18
    uint256 public immutable missingDecimals;

    ERC20 public immutable collateralToken;

    Stock public immutable stock;
    RStablecoin public immutable stable;

    UniswapPairOracle public collatEthOracle;
    address public weth;

    uint256 public mintingFee;
    uint256 public redemptionFee;
    uint256 public buybackFee;
    uint256 public recollatFee;

    mapping(address => uint256) public redeemStockBalances;
    mapping(address => uint256) public redeemCollateralBalances;
    uint256 public unclaimedPoolCollateral;
    uint256 public unclaimedPoolStock;


    // Pool_ceiling is the total units of collateral that a pool contract can hold
    uint256 public poolCeiling = 0;

    // Stores price of the collateral, if price is paused
    uint256 public pausedPrice = 0;

    uint256 public bonusRate = 7500;

    // Number of blocks to wait before being able to collectRedemption()
    uint256 public redemptionDelay = 1;

    mapping(address => bool) public amoMinterAddresses; // minter address -> is it enabled

    constructor(
        address _operatorMsg,
        address _stableContract,
        address _stockContract,
        address _collateralAddress,
        uint256 _poolCeiling
    ) public AbstractPausable(_operatorMsg) {
        require(
            (_stableContract != address(0)) &&
            (_stockContract != address(0)) &&
            (_collateralAddress != address(0)),
            "0 address"
        );
        stable = RStablecoin(_stableContract);
        stock = Stock(_stockContract);
        collateralToken = ERC20(_collateralAddress);
        poolCeiling = _poolCeiling;
        missingDecimals = uint256(18).sub(collateralToken.decimals());
    }

    modifier onlyAMOMinters() {
        require(amoMinterAddresses[msg.sender], "Not an AMO Minter");
        _;
    }

    function addAMOMinter(address amoMinter) external onlyOperator {
        require(amoMinter != address(0), "0 address");

        // Make sure the AMO Minter has collatDollarBalance()
        uint256 collatValE18 = IAMOMinter(amoMinter).collatDollarBalance();
        require(collatValE18 >= 0, "Invalid AMO");

        amoMinterAddresses[amoMinter] = true;

        emit AMOMinterAdded(amoMinter);
    }

    function removeAMOMinter(address amoMinter) external onlyOperator {
        amoMinterAddresses[amoMinter] = false;

        emit AMOMinterRemoved(amoMinter);
    }


    // Returns dollar value of collateral held in this Stable pool
    function collatDollarBalance() public view returns (uint256) {
        if (paused() == true) {
            return
            (collateralToken.balanceOf(address(this)).sub(unclaimedPoolCollateral))
            .mul(10 ** missingDecimals)
            .mul(pausedPrice)
            .div(PoolLibrary.PRICE_PRECISION);
        } else {
            uint256 ethUsdPrice = stable.ethUsdPrice();
            uint256 ethCollatPrice = collatEthOracle.consult(
                weth,
                (PoolLibrary.PRICE_PRECISION * (10 ** missingDecimals))
            );

            uint256 collatUsdPrice = ethUsdPrice.mul(PoolLibrary.PRICE_PRECISION).div(ethCollatPrice);
            return
            (collateralToken.balanceOf(address(this)).sub(unclaimedPoolCollateral))
            .mul(10 ** missingDecimals)
            .mul(collatUsdPrice)
            .div(PoolLibrary.PRICE_PRECISION);
            //.mul(getCollateralPrice()).div(1e6);
        }
    }


    function availableExcessCollatDV() public view returns (uint256) {
        uint256 totalSupply = stable.totalSupply();
        uint256 globalCollateralRatio = stable.globalCollateralRatio();
        uint256 globalCollatValue = stable.globalCollateralValue();

        if (globalCollateralRatio > COLLATERAL_RATIO_PRECISION) globalCollateralRatio = COLLATERAL_RATIO_PRECISION;
        // Handles an overcollateralized contract with CR > 1
        uint256 requiredCollatDollarValueD18 = (totalSupply.mul(globalCollateralRatio)).div(
            COLLATERAL_RATIO_PRECISION
        );
        // Calculates collateral needed to back each 1 FRAX with $1 of collateral at current collat ratio
        if (globalCollatValue > requiredCollatDollarValueD18)
            return globalCollatValue.sub(requiredCollatDollarValueD18);
        else return 0;
    }



    // Returns the price of the pool collateral in USD
    function getCollateralPrice() public view returns (uint256) {
        if (paused() == true) {
            return pausedPrice;
        } else {
            uint256 ethUsdPrice = stable.ethUsdPrice();
            return
            ethUsdPrice.mul(PoolLibrary.PRICE_PRECISION).div(
                collatEthOracle.consult(weth, PoolLibrary.PRICE_PRECISION * (10 ** missingDecimals))
            );
        }
    }

    function setCollatETHOracle(address _collateralEthOracleAddress, address _weth) external onlyOperator {
        collatEthOracle = UniswapPairOracle(_collateralEthOracleAddress);
        weth = _weth;
    }

    // We separate out the 1t1, fractional and algorithmic minting functions for gas efficiency
    function mint1t1Stable(uint256 collateralAmount, uint256 outMin) external whenNotPaused {
        uint256 collateralAmountD18 = collateralAmount * (10 ** missingDecimals);

        require(stable.globalCollateralRatio() >= COLLATERAL_RATIO_MAX, "Collateral ratio must be >= 1");
        require(
            (collateralToken.balanceOf(address(this))).sub(unclaimedPoolCollateral).add(collateralAmount) <=
            poolCeiling,
            "[Pool's Closed]: Ceiling reached"
        );

        uint256 stableAmount = PoolLibrary.calcMint1t1Stable(getCollateralPrice(), collateralAmountD18);
        //1 Stable for each $1 worth of collateral

        stableAmount = (stableAmount.mul(uint256(1e6).sub(mintingFee))).div(1e6);
        //remove precision at the end
        require(outMin <= stableAmount, "Slippage limit reached");

        TransferHelper.safeTransferFrom(address(collateralToken), msg.sender, address(this), collateralAmount);
        stable.poolMint(msg.sender, stableAmount);
    }

    // 0% collateral-backed
    function mintAlgorithmicStable(uint256 stockAmountD18, uint256 stableOutMin) external whenNotPaused {
        uint256 stockPrice = stable.stockPrice();
        require(stable.globalCollateralRatio() == 0, "Collateral ratio must be 0");

        uint256 stableAmointD18 = PoolLibrary.calcMintAlgorithmicStable(
            stockPrice, // X stock / 1 USD
            stockAmountD18
        );

        stableAmointD18 = (stableAmointD18.mul(uint256(1e6).sub(mintingFee))).div(1e6);
        require(stableOutMin <= stableAmointD18, "Slippage limit reached");

        stock.poolBurnFrom(msg.sender, stockAmountD18);
        stable.poolMint(msg.sender, stableAmointD18);
    }

    // Will fail if fully collateralized or fully algorithmic
    // > 0% and < 100% collateral-backed
    function mintFractionalStable(
        uint256 collateralAmount,
        uint256 stockAmount,
        uint256 stableOutMin
    ) external whenNotPaused {
        uint256 stockPrice = stable.stockPrice();
        uint256 globalCollateralRatio = stable.globalCollateralRatio();

        require(
            globalCollateralRatio < COLLATERAL_RATIO_MAX && globalCollateralRatio > 0,
            "Collateral ratio needs to be between .000001 and .999999"
        );
        require(
            collateralToken.balanceOf(address(this)).sub(unclaimedPoolCollateral).add(collateralAmount) <=
            poolCeiling,
            "Pool ceiling reached, no more FRAX can be minted with this collateral"
        );

        uint256 collateralAmount = collateralAmount * (10 ** missingDecimals);
        PoolLibrary.MintFFParams memory inputParams = PoolLibrary.MintFFParams(
            stockPrice,
            getCollateralPrice(),
            stockAmount,
            collateralAmount,
            globalCollateralRatio
        );

        (uint256 mintAmount, uint256 stockNeeded) = PoolLibrary.calcMintFractionalStable(inputParams);

        mintAmount = (mintAmount.mul(uint256(1e6).sub(mintingFee))).div(1e6);
        require(stableOutMin <= mintAmount, "Slippage limit reached");
        require(stockNeeded <= stockAmount, "Not enough Stock inputted");

        stock.poolBurnFrom(msg.sender, stockNeeded);
        TransferHelper.safeTransferFrom(address(collateralToken), msg.sender, address(this), collateralAmount);
        stable.poolMint(msg.sender, mintAmount);
    }

    // Redeem collateral. 100% collateral-backed
    function redeem1t1Stable(uint256 stableAmount, uint256 collateralOutMin) external whenNotPaused {
        require(stable.globalCollateralRatio() == COLLATERAL_RATIO_MAX, "Collateral ratio must be == 1");

        // Need to adjust for decimals of collateral
        uint256 stableAmountPrecision = stableAmount.div(10 ** missingDecimals);
        uint256 collateralNeeded = PoolLibrary.calcRedeem1t1Stable(getCollateralPrice(), stableAmountPrecision);

        collateralNeeded = (collateralNeeded.mul(uint256(1e6).sub(redemptionFee))).div(1e6);
        require(
            collateralNeeded <= collateralToken.balanceOf(address(this)).sub(unclaimedPoolCollateral),
            "Not enough collateral in pool"
        );
        require(collateralOutMin <= collateralNeeded, "Slippage limit reached");

        redeemCollateralBalances[msg.sender] = redeemCollateralBalances[msg.sender].add(collateralNeeded);
        unclaimedPoolCollateral = unclaimedPoolCollateral.add(collateralNeeded);

        // Move all external functions to the end
        stable.poolBurnFrom(msg.sender, stableAmount);
    }

    // Will fail if fully collateralized or algorithmic
    // Redeem Stable for collateral and stock. > 0% and < 100% collateral-backed
    function redeemFractionalStable(
        uint256 stableAmount,
        uint256 stockOutMin,
        uint256 collateralOutMin
    ) external whenNotPaused {
        uint256 stockPrice = stable.stockPrice();
        uint256 globalCollateralRatio = stable.globalCollateralRatio();

        require(
            globalCollateralRatio < COLLATERAL_RATIO_MAX && globalCollateralRatio > 0,
            "Collateral ratio needs to be between .000001 and .999999"
        );
        uint256 colPriceUsd = getCollateralPrice();

        uint256 stableAmountPostFee = (stableAmount.mul(uint256(1e6).sub(redemptionFee))).div(PoolLibrary.PRICE_PRECISION);

        uint256 stockDollarValueD18 = stableAmountPostFee.sub(
            stableAmountPostFee.mul(globalCollateralRatio).div(PoolLibrary.PRICE_PRECISION)
        );
        uint256 stockAmount = stockDollarValueD18.mul(PoolLibrary.PRICE_PRECISION).div(stockPrice);

        // Need to adjust for decimals of collateral
        uint256 stableAmountPrecision = stableAmountPostFee.div(10 ** missingDecimals);
        uint256 collateralDollarValue = stableAmountPrecision.mul(globalCollateralRatio).div(PoolLibrary.PRICE_PRECISION);
        uint256 collateralAmount = collateralDollarValue.mul(PoolLibrary.PRICE_PRECISION).div(colPriceUsd);

        require(
            collateralAmount <= collateralToken.balanceOf(address(this)).sub(unclaimedPoolCollateral),
            "Not enough collateral in pool"
        );
        require(collateralOutMin <= collateralAmount, "Slippage limit reached [collateral]");
        require(stockOutMin <= stockAmount, "Slippage limit reached [stock]");

        redeemCollateralBalances[msg.sender] = redeemCollateralBalances[msg.sender].add(collateralAmount);
        unclaimedPoolCollateral = unclaimedPoolCollateral.add(collateralAmount);

        redeemStockBalances[msg.sender] = redeemStockBalances[msg.sender].add(stockAmount);
        unclaimedPoolStock = unclaimedPoolStock.add(stockAmount);

        // Move all external functions to the end
        stable.poolBurnFrom(msg.sender, stableAmount);
        stock.poolMint(address(this), stockAmount);
    }

    // Redeem stable for stock. 0% collateral-backed
    function redeemAlgorithmicStable(uint256 stableAmount, uint256 stockOutMin) external whenNotPaused {
        uint256 stockPrice = stable.stockPrice();
        uint256 globalCollateralRatio = stable.globalCollateralRatio();

        require(globalCollateralRatio == 0, "Collateral ratio must be 0");
        uint256 stockDollarValueD18 = stableAmount;

        stockDollarValueD18 = (stockDollarValueD18.mul(uint256(1e6).sub(redemptionFee))).div(PoolLibrary.PRICE_PRECISION);
        //apply fees

        uint256 stockAmount = stockDollarValueD18.mul(PoolLibrary.PRICE_PRECISION).div(stockPrice);

        redeemStockBalances[msg.sender] = redeemStockBalances[msg.sender].add(stockAmount);
        unclaimedPoolStock = unclaimedPoolStock.add(stockAmount);

        require(stockOutMin <= stockAmount, "Slippage limit reached");
        // Move all external functions to the end
        stable.poolBurnFrom(msg.sender, stableAmount);
        stock.poolMint(address(this), stockAmount);
    }

    // After a redemption happens, transfer the newly minted stock and owed collateral from this pool
    // contract to the user. Redemption is split into two functions to prevent flash loans from being able
    // to take out stable/collateral from the system, use an AMM to trade the new price, and then mint back into the system.
    // Must wait for (AEO or Whitelist) blocks before collecting redemption
    function collectRedemption() external onlyAEOWhiteList {
        bool sendFXS = false;
        bool sendCollateral = false;
        uint256 stockAmount = 0;
        uint256 collateralAmount = 0;

        // Use Checks-Effects-Interactions pattern
        if (redeemStockBalances[msg.sender] > 0) {
            stockAmount = redeemStockBalances[msg.sender];
            redeemStockBalances[msg.sender] = 0;
            unclaimedPoolStock = unclaimedPoolStock.sub(stockAmount);

            sendFXS = true;
        }

        if (redeemCollateralBalances[msg.sender] > 0) {
            collateralAmount = redeemCollateralBalances[msg.sender];
            redeemCollateralBalances[msg.sender] = 0;
            unclaimedPoolCollateral = unclaimedPoolCollateral.sub(collateralAmount);

            sendCollateral = true;
        }

        if (sendFXS) {
            TransferHelper.safeTransfer(address(stock), msg.sender, stockAmount);
        }
        if (sendCollateral) {
            TransferHelper.safeTransfer(address(collateralToken), msg.sender, collateralAmount);
        }
    }

    // Bypasses the gassy mint->redeem cycle for AMOs to borrow collateral
    function amoMinterBorrow(uint256 collateralAmount) external whenNotPaused onlyAMOMinters {
        // Transfer
        TransferHelper.safeTransfer(address(collateralToken), msg.sender, collateralAmount);
    }

    // When the protocol is recollateralizing, we need to give a discount of stock to hit the new CR target
    // Thus, if the target collateral ratio is higher than the actual value of collateral, minters get Stock for adding collateral
    // This function simply rewards anyone that sends collateral to a pool with the same amount of Stock + the bonus rate
    // Anyone can call this function to recollateralize the protocol and take the extra Stock value from the bonus rate as an arb opportunity
    function recollateralizeStable(uint256 collateralAmount, uint256 stockOutMin) external {
        require(paused() == false, "Recollateralize is paused");
        uint256 collateralAmountD18 = collateralAmount * (10 ** missingDecimals);
        uint256 stockPrice = stable.stockPrice();
        uint256 stockTotalSupply = stable.totalSupply();
        uint256 globalCollateralRatio = stable.globalCollateralRatio();
        uint256 globalCollatValue = stable.globalCollateralValue();

        (uint256 collateralUnits, uint256 amountToRecollat) = PoolLibrary.calcRecollateralizeStableInner(
            collateralAmountD18,
            getCollateralPrice(),
            globalCollatValue,
            stockTotalSupply,
            globalCollateralRatio
        );

        uint256 collateralUnitsPrecision = collateralUnits.div(10 ** missingDecimals);

        uint256 stockPaidBack = amountToRecollat.mul(uint256(1e6).add(bonusRate).sub(recollatFee)).div(stockPrice);

        require(stockOutMin <= stockPaidBack, "Slippage limit reached");
        TransferHelper.safeTransferFrom(
            address(collateralToken),
            msg.sender,
            address(this),
            collateralUnitsPrecision
        );
        stock.poolMint(msg.sender, stockPaidBack);
    }

    // Function can be called by an Stock holder to have the protocol buy back Stock with excess collateral value from a desired collateral pool
    // This can also happen if the collateral ratio > 1
    function buyBackStock(uint256 stockAmount, uint256 collateralOutMin) external {
        require(paused() == false, "Buyback is paused");
        uint256 stockPrice = stable.stockPrice();

        PoolLibrary.BuybackStockParams memory inputParams = PoolLibrary.BuybackStockParams(
            availableExcessCollatDV(),
            stockPrice,
            getCollateralPrice(),
            stockAmount
        );

        uint256 collateralEquivalentD18 = (PoolLibrary.calcBuyBackStock(inputParams))
        .mul(uint256(1e6).sub(buybackFee))
        .div(1e6);
        uint256 collateralPrecision = collateralEquivalentD18.div(10 ** missingDecimals);

        require(collateralOutMin <= collateralPrecision, "Slippage limit reached");
        // Give the sender their desired collateral and burn the Stock
        stock.poolBurnFrom(msg.sender, stockAmount);
        TransferHelper.safeTransfer(address(collateralToken), msg.sender, collateralPrecision);
    }

    // Combined into one function due to 24KiB contract memory limit
    function setPoolParameters(
        uint256 _ceiling,
        uint256 _bonusRate,
        uint256 _redemptionDelay,
        uint256 _mintFee,
        uint256 _redeemFee,
        uint256 _buybackFee,
        uint256 _recollatFee
    ) external onlyOperator {
        poolCeiling = _ceiling;
        bonusRate = _bonusRate;
        redemptionDelay = _redemptionDelay;
        mintingFee = _mintFee;
        redemptionFee = _redeemFee;
        buybackFee = _buybackFee;
        recollatFee = _recollatFee;

        emit PoolParametersSet(
            _ceiling,
            _bonusRate,
            _redemptionDelay,
            _mintFee,
            _redeemFee,
            _buybackFee,
            _recollatFee
        );
    }

    event AMOMinterAdded(address amoMinterAddr);
    event AMOMinterRemoved(address amoMinterAddr);
    event PoolParametersSet(
        uint256 ceiling,
        uint256 bonusRate,
        uint256 redemptionDelay,
        uint256 mintFee,
        uint256 redeemFee,
        uint256 buybackFee,
        uint256 recollatFee
    );
}