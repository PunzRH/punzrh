// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

/// @notice Share token for one side (long or short) of a PonsPerpPool. Only the pool can mint/burn.
contract PerpToken is ERC20 {
    address public immutable pool;

    error NotPool();

    constructor(string memory name_, string memory symbol_, address pool_) ERC20(name_, symbol_) {
        pool = pool_;
    }

    modifier onlyPool() {
        if (msg.sender != pool) revert NotPool();
        _;
    }

    function mint(address to, uint256 amount) external onlyPool {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyPool {
        _burn(from, amount);
    }
}
