// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.10;

import "./StablecoinPool.sol";

contract PoolUSD is StablecoinPool {
    address public usdAddress;

    constructor(
        address _operatorMsg,
        address _stableAddress,
        address _stockAddress,
        address _collateralAddress,
        uint256 _poolCeiling
    )
    public
    StablecoinPool(_operatorMsg, _stableAddress, _stockAddress, _collateralAddress, _poolCeiling)
    {
        require(_collateralAddress != address(0), "0 address");
        usdAddress = _collateralAddress;
    }
}
