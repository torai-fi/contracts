// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

import "../../tools/AbstractPausable.sol";
import "../../tools/TransferHelper.sol";

contract Reserve is AbstractPausable {

    constructor(
        address _operatorMsg
    ) AbstractPausable(_operatorMsg) {

    }


    function fetchToken(address token, uint256 amount) external onlyOperator {
        TransferHelper.safeTransfer(token, msg.sender, amount);
        emit Recovered(token, msg.sender, amount);
    }

    event Recovered(address token, address to, uint256 amount);

}
