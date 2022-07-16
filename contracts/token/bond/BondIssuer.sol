// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.10;

import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

import "../../tools/AbstractPausable.sol";
import "../../math/Math.sol";
import "../Rusd.sol";
import "./Bond.sol";

contract BondIssuer is AbstractPausable {
    using SafeMath for uint256;

    uint256 public constant ONE_YEAR = 1 * 365 * 86400;
    uint256 public constant PRICE_PRECISION = 1e6;

    RStablecoin public stableCoin;
    Bond public bond;

    uint256 public lastInterestTime;
    uint256 public exchangeRate;
    uint256 public interestRate;
    uint256 public minInterestRate;//1e6
    uint256 public maxInterestRate;//1e6
    uint256 public reserveAmount;
    address public reserveAddress;

    uint256 public maxBondOutstanding = 1000000e18;

    // Set fees, E6
    uint256 public issueFee = 100; // 0.01% initially
    uint256 public redemptionFee = 100; // 0.01% initially
    uint256 public fee;

    uint256 public vBalStable;

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _operatorMsg,
        address _stableAddress,
        address _bondAddress
    ) AbstractPausable(_operatorMsg) {
        stableCoin = RStablecoin(_stableAddress);
        bond = Bond(_bondAddress);
        minInterestRate = 1e4;
        maxInterestRate = 1e5;
        interestRate = 1e4;
        exchangeRate = PRICE_PRECISION;
        TransferHelper.safeApprove(address(stableCoin), address(this), type(uint256).max);
        TransferHelper.safeApprove(address(bond), address(bond), type(uint256).max);
    }

    function currentInterestRate() public view returns (uint256) {
        uint256 totalSupply = IERC20(bond).totalSupply();
        if (totalSupply <= maxBondOutstanding) {
            return interestRate;
        } else {
            return interestRate.mul(maxBondOutstanding).div(totalSupply);
        }
    }

    function calInterest() public {
        if (block.timestamp > lastInterestTime) {
            uint256 timePast = block.timestamp.sub(lastInterestTime);
            uint256 interest = currentInterestRate().mul(timePast).div(ONE_YEAR);
            exchangeRate = exchangeRate.add(interest);
            lastInterestTime = block.timestamp;
        }
    }

    function mintBond(uint256 stableIn) external whenNotPaused returns (uint256 bondOut, uint256 stableFee) {
        calInterest();
        TransferHelper.safeTransferFrom(address(stableCoin), msg.sender, address(this), stableIn);

        stableFee = stableIn.mul(issueFee).div(PRICE_PRECISION);
        fee = fee.add(stableFee);

        uint256 amount = stableIn.sub(stableFee);
        reserveAmount = reserveAmount.add(amount);

        bondOut = stableIn.mul(PRICE_PRECISION).div(exchangeRate);
        bond.issuerMint(msg.sender, bondOut);
        vBalStable = vBalStable.add(stableIn);
        emit BondMint(msg.sender, stableIn, bondOut, stableFee);
    }

    function redeemBond(uint256 bondIn) external whenNotPaused returns (uint256 stableOut, uint256 stableFee) {
        calInterest();
        bond.burnFrom(msg.sender, bondIn);
        stableOut = bondIn.mul(exchangeRate).div(PRICE_PRECISION);
        stableFee = stableOut.mul(redemptionFee).div(PRICE_PRECISION);
        fee = fee.add(stableFee);
        stableCoin.poolMint(address(this), stableOut);
        TransferHelper.safeTransfer(address(stableCoin), msg.sender, stableOut.sub(stableFee));
        vBalStable = vBalStable.sub(stableOut);
        emit BondRedeemed(msg.sender, bondIn, stableOut, stableFee);
    }

    function setMaxBondOutstanding(uint256 _max) external onlyOperator {
        maxBondOutstanding = _max;
    }


    function fetchReserve() external onlyOperator {
        require(reserveAddress != address(0), "0 address");
        TransferHelper.safeTransfer(address(stableCoin), reserveAddress, reserveAmount);
        reserveAmount = 0;
    }

    function setReserveAddress(address _address) external onlyOperator {
        reserveAddress = _address;
    }

    function setRangeInterestRate(uint256 min, uint256 max) external onlyOperator {
        minInterestRate = min;
        maxInterestRate = max;
    }

    function setInterestRate(uint256 _interestRate) external onlyOperator {
        require(maxInterestRate >= _interestRate && _interestRate >= minInterestRate, "rate  in range");
        interestRate = _interestRate;
    }

    function setFees(uint256 _issueFee, uint256 _redemptionFee) external onlyOperator {
        issueFee = _issueFee;
        redemptionFee = _redemptionFee;
    }

    function claimFee() external onlyOperator {
        TransferHelper.safeTransfer(address(stableCoin), msg.sender, fee);
        fee = 0;
    }

    function recoverToken(address token, uint256 amount) external onlyOperator {
        TransferHelper.safeTransfer(token, msg.sender, amount);
        emit Recovered(token, msg.sender, amount);
    }

    function collatDollarBalance() external pure returns (uint256) {
        return uint256(1e18);
        // 1 nonexistant USDC
    }

    event Recovered(address token, address to, uint256 amount);

    // Track bond redeeming
    event BondRedeemed(address indexed from, uint256 bondAmount, uint256 stableOut, uint256 fee);
    event BondMint(address indexed from, uint256 stableAmount, uint256 bondOut, uint256 fee);
}
