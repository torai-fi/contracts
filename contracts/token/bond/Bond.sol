// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.10;

import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

import "../../tools/AbstractPausable.sol";

contract Bond is ERC20Burnable, AbstractPausable {
    using SafeMath for uint256;

    // genesis supply will be 5k on Mainnet
    uint256 public constant GENESIS_SUPPLY = 5000e18;
    uint256 public constant PRICE_PRECISION = 1e6;

    address[] public bondIssuers;
    mapping(address => bool) public isBondIssuers;

    modifier onlyIssuers() {
        require(isBondIssuers[msg.sender] == true, "Only bond issuers can call this function");
        _;
    }

    constructor(
        address _operatorMsg,
        string memory _name,
        string memory _symbol
    ) ERC20(_name, _symbol) AbstractPausable(_operatorMsg) {}


    function issuerMint(address _address, uint256 _amount) external onlyIssuers {
        super._mint(_address, _amount);
        emit BondMinted(msg.sender, _address, _amount);
    }

    function issuerBurnFrom(address _address, uint256 _amount) external onlyIssuers {
        super._burn(_address, _amount);
        emit BondBurned(_address, msg.sender, _amount);
    }

    function addIssuer(address _address) external onlyOperator {
        require(isBondIssuers[_address] == false, "already exists");
        isBondIssuers[_address] = true;
        bondIssuers.push(_address);
    }

    function removeIssuer(address _address) external onlyOperator {
        require(isBondIssuers[_address] == true, "non existant");

        // Delete from the mapping
        delete isBondIssuers[_address];

        // 'Delete' from the array by setting the address to 0x0
        for (uint256 i = 0; i < bondIssuers.length; i++) {
            if (bondIssuers[i] == _address) {
                bondIssuers[i] = address(0);
                // This will leave a null in the array and keep the indices the same
                break;
            }
        }
    }

    function recoverToken(address token, uint256 amount) external onlyOperator {
        ERC20(token).transfer(msg.sender, amount);
        emit Recovered(token, msg.sender, amount);
    }

    event Recovered(address token, address to, uint256 amount);

    event BondBurned(address indexed from, address indexed to, uint256 amount);
    event BondMinted(address indexed from, address indexed to, uint256 amount);
}
