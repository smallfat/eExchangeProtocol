// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../node_modules/@openzeppelin/contracts/token/ERC20/ERC20.sol";


contract ScryToken is ERC20 {
//    string override public name = "ScryToken";
//    string public symbol = "yyy";
//    uint8 public decimals = 2;
//    uint256 public INITIAL_SUPPLY = 1000000000;

    constructor(string memory name, string memory symbol, uint256 initialSupply) ERC20(name, symbol) {
        _mint(msg.sender, initialSupply);
    }
}