// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "../interface/curve/IStableSwap3Pool.sol";
import "../tools/TransferHelper.sol";
import "../token/Rusd.sol";
import "../interface/IAMOMinter.sol";
import "../tools/CheckPermission.sol";
import "../interface/IStock.sol";

contract ExchangeAMO is CheckPermission {
    using SafeMath for uint256;

    uint256 public constant PRICE_PRECISION = 1e6;

    IStableSwap3Pool public immutable threePool;
    ERC20 public immutable threePoolLp;
    RStablecoin public immutable stablecoin;
    ERC20 public immutable collateralToken;
    IAMOMinter public amoMinter;
    IStock public immutable stock;

    uint256 public missingDecimals;

    uint256 public liqSlippage3crv;

    // Convergence window
    uint256 public convergenceWindow; // 0.1 cent

    bool public customFloor;
    uint256 public stableCoinFloor;

    // Discount
    bool public setDiscount;
    uint256 public discountRate;

    int128 stablePoolIndex;
    int128 collateralPoolIndex;

    constructor(
        address _operatorMsg,
        address _amoMinterAddress,
        address stableCoinAddress,
        address _stockAddress,
        address collateralAddress,
        address poolAddress,
        address poolTokenAddress,
        int128 _collateralPoolIndex,
        int128 _stablePoolIndex
    ) CheckPermission(_operatorMsg) {
        stablecoin = RStablecoin(stableCoinAddress);
        stock = IStock(_stockAddress);
        collateralToken = ERC20(collateralAddress);
        missingDecimals = uint256(18).sub(collateralToken.decimals());
        amoMinter = IAMOMinter(_amoMinterAddress);
        threePool = IStableSwap3Pool(poolAddress);
        threePoolLp = ERC20(poolTokenAddress);
        liqSlippage3crv = 800000;
        convergenceWindow = 1e15;
        collateralPoolIndex = _collateralPoolIndex;
        stablePoolIndex = _stablePoolIndex;
        customFloor = false;
        setDiscount = false;
    }

    modifier onlyMinter() {
        require(msg.sender == address(amoMinter), "Not minter");
        _;
    }

    function setIndex(int128 _collateralPoolIndex, int128 _stablePoolIndex) external onlyOperator {
        collateralPoolIndex = _collateralPoolIndex;
        stablePoolIndex = _stablePoolIndex;
    }

    function showAllocations() public view returns (uint256[9] memory arr) {
        uint256 lpBalance = threePoolLp.balanceOf(address(this));
        uint256 stable3crvSupply = threePoolLp.totalSupply();
        uint256 stableWithdrawable;
        uint256 pool3Withdrawable;
        stableWithdrawable = iterate();
        uint256 stableInContract = stablecoin.balanceOf(address(this));
        uint256 usdcInContract = collateralToken.balanceOf(address(this));
        uint256 usdcWithdrawable = pool3Withdrawable.mul(threePool.get_virtual_price()).div(1e18).div(
            10 ** missingDecimals
        );
        uint256 usdcSubtotal = usdcInContract.add(usdcWithdrawable);

        return [
        stableInContract, // [0] Free stable in the contract
        stableWithdrawable, // [1] stable withdrawable from the FRAX3CRV tokens
        stableWithdrawable.add(stableInContract), // [2] stable withdrawable + free FRAX in the the contract
        usdcInContract, // [3] Free USDC
        usdcWithdrawable, // [4] USDC withdrawable from the FRAX3CRV tokens
        usdcSubtotal, // [5] USDC subtotal assuming FRAX drops to the CR and all reserves are arbed
        usdcSubtotal.add(
            (stableInContract.add(stableWithdrawable)).mul(stableDiscountRate()).div(1e6 * (10 ** missingDecimals))
        ), // [6] USDC Total
        lpBalance, // [7] FRAX3CRV free or in the vault
        stable3crvSupply // [8] Total supply of stable tokens
        ];
    }

    function dollarBalances() public view returns (uint256 stableValE18, uint256 collatValE18) {
        // Get the allocations
        uint256[9] memory allocations = showAllocations();

        stableValE18 = (allocations[2]).add((allocations[5]).mul((10 ** missingDecimals)));
        collatValE18 = (allocations[6]).mul(10 ** missingDecimals);
    }

    // Returns hypothetical reserves of pool if the stable price went to the CR,
    function iterate() public view returns (uint256) {
        uint256 lpBalance = threePoolLp.balanceOf(address(this));

        uint256 floorPrice = uint256(1e18).mul(stableFloor()).div(1e6);
        uint256 crv3Received;
        uint256 dollarValue;
        // 3crv is usually slightly above $1 due to collecting 3pool swap fees

        // Calculate the current output dy given input dx
        crv3Received = threePool.get_dy(0, 1, 1e18);
        dollarValue = crv3Received.mul(1e18).div(threePool.get_virtual_price());
        if (dollarValue <= floorPrice.add(convergenceWindow) && dollarValue >= floorPrice.sub(convergenceWindow)) {

        } else if (dollarValue <= floorPrice.add(convergenceWindow)) {
            uint256 crv3ToSwap = lpBalance.div(2);
            //todo Calculate the current output
            lpBalance = lpBalance.sub(threePool.get_dy(1, stablePoolIndex, crv3ToSwap));
        } else if (dollarValue >= floorPrice.sub(convergenceWindow)) {
            uint256 stableToSwap = lpBalance.div(2);
            lpBalance = lpBalance.add(stableToSwap);
        }
        return lpBalance;
    }

    function stableFloor() public view returns (uint256) {
        if (customFloor) {
            return stableCoinFloor;
        } else {
            return stablecoin.globalCollateralRatio();
        }
    }

    function stableDiscountRate() public view returns (uint256) {
        if (setDiscount) {
            return discountRate;
        } else {
            return stablecoin.globalCollateralRatio();
        }
    }

    // Backwards compatibility
    function mintedBalance() public view returns (int256) {
        return amoMinter.stableMintBalances(address(this));
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function poolDeposit(uint256 _stableAmount, uint256 _collateralAmount)
    external
    onlyOperator
    returns (uint256 lpReceived)
    {
        uint256 threeCRVReceived = 0;
        if (_collateralAmount > 0) {
            collateralToken.approve(address(threePool), _collateralAmount);

            uint256[3] memory threePoolCollaterals;
            threePoolCollaterals[uint128(collateralPoolIndex)] = _collateralAmount;
            {
                uint256 min3poolOut = (_collateralAmount * (10 ** missingDecimals)).mul(liqSlippage3crv).div(
                    PRICE_PRECISION
                );
                threePool.add_liquidity(threePoolCollaterals, min3poolOut);
            }

            threeCRVReceived = threePoolLp.balanceOf(address(this));

            // WEIRD ISSUE: NEED TO DO three_pool_erc20.approve(address(three_pool), 0); first before every time
            // May be related to https://github.com/vyperlang/vyper/blob/3e1ff1eb327e9017c5758e24db4bdf66bbfae371/examples/tokens/ERC20.vy#L85
            threePoolLp.approve(address(threePool), 0);
            threePoolLp.approve(address(threePool), threeCRVReceived);
        }

        stablecoin.approve(address(threePool), _stableAmount);
        uint256 minLpOut = (_stableAmount.add(threeCRVReceived)).mul(liqSlippage3crv).div(PRICE_PRECISION);
        uint256[3] memory amounts;
        amounts[uint128(stablePoolIndex)] = _stableAmount;
        lpReceived = threePool.add_liquidity(amounts, minLpOut);

        return lpReceived;
    }

    function poolWithdrawStable(uint256 _metapoolLpIn, bool burnTheStable)
    external
    onlyOperator
    returns (uint256 stableReceived)
    {
        uint256 minStableOut = _metapoolLpIn.mul(liqSlippage3crv).div(PRICE_PRECISION);
        stableReceived = threePool.remove_liquidity_one_coin(_metapoolLpIn, stablePoolIndex, minStableOut);

        if (burnTheStable) {
            burnStable(stableReceived);
        }
    }

    function poolWithdrawCollateral(uint256 _poolIn) public onlyOperator {
        // Convert the 3pool into the collateral
        // WEIRD ISSUE: NEED TO DO three_pool_erc20.approve(address(three_pool), 0); first before every time
        // May be related to https://github.com/vyperlang/vyper/blob/3e1ff1eb327e9017c5758e24db4bdf66bbfae371/examples/tokens/ERC20.vy#L85
        threePoolLp.approve(address(threePool), 0);
        threePoolLp.approve(address(threePool), _poolIn);
        uint256 minCollatOut = _poolIn.mul(liqSlippage3crv).div(PRICE_PRECISION * (10 ** missingDecimals));
        threePool.remove_liquidity_one_coin(_poolIn, collateralPoolIndex, minCollatOut);
    }


    // Give USDC profits back. Goes through the minter
    function giveCollatBack(uint256 collatAmount) external onlyOperator {
        collateralToken.approve(address(amoMinter), collatAmount);
        amoMinter.receiveCollatFromAMO(collatAmount);
    }

    function burnStock(uint256 _amount) public onlyOperator {
        stock.approve(address(amoMinter), _amount);
        amoMinter.burnStockFromAMO(_amount);
    }

    function burnStable(uint256 stableAmount) public onlyOperator {
        stablecoin.approve(address(amoMinter), stableAmount);
        amoMinter.burnStableFromAMO(stableAmount);
    }

    /* ========== RESTRICTED GOVERNANCE FUNCTIONS ========== */

    function setAMOMinter(address _amoMinterAddress) external onlyOperator {
        amoMinter = IAMOMinter(_amoMinterAddress);
    }

    function setConvergenceWindow(uint256 _window) external onlyOperator {
        convergenceWindow = _window;
    }

    // in terms of 1e6 (overriding globalCollateralRatio)
    function setCustomFloor(bool _state, uint256 _floorPrice) external onlyOperator {
        customFloor = _state;
        stableCoinFloor = _floorPrice;
    }

    // in terms of 1e6 (overriding globalCollateralRatio)
    function setDiscountRate(bool _state, uint256 _discountRate) external onlyOperator {
        setDiscount = _state;
        discountRate = _discountRate;
    }

    function setSlippages(uint256 _liqSlippage3crv) external onlyOperator {
        liqSlippage3crv = _liqSlippage3crv;
    }

    function recoverERC20(address tokenAddress, uint256 tokenAmount) external onlyOperator {
        // Can only be triggered by owner or governance, not custodian
        // Tokens are sent to the custodian, as a sort of safeguard
        TransferHelper.safeTransfer(address(tokenAddress), msg.sender, tokenAmount);
    }

    // Generic proxy
    function execute(
        address _to,
        uint256 _value,
        bytes calldata _data
    ) external onlyOperator returns (bool, bytes memory) {
        (bool success, bytes memory result) = _to.call{value : _value}(_data);
        return (success, result);
    }
}
