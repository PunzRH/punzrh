// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

interface IBacking {
    function payout(address to, uint256 burned, uint256 supplyBefore) external;
}

/// @notice Fixed-supply coin backed by a PONS short. Burn any amount to receive your pro-rata share of the
///         sPONS held by the Backing contract (the floor). Supply only ever goes down.
contract PoonsToken is ERC20 {
    IBacking public immutable backing;
    string private _uri; // metadata JSON: image, description, website, twitter (read by GMGN/indexers like long.xyz coins)

    event Redeemed(address indexed user, uint256 burned);

    constructor(string memory name_, string memory symbol_, uint256 supply, address recipient, address backing_, string memory uri_)
        ERC20(name_, symbol_)
    {
        backing = IBacking(backing_);
        _uri = uri_;
        _mint(recipient, supply);
    }

    /// @notice Token metadata URI (same convention long.xyz/Doppler tokens use, so terminals auto-load the logo).
    function tokenURI() external view returns (string memory) { return _uri; }
    function contractURI() external view returns (string memory) { return _uri; }

    /// @notice Burn `amount` and receive your share of the short (sPONS) from the backing.
    function redeem(uint256 amount) external {
        uint256 supplyBefore = totalSupply();
        _burn(msg.sender, amount);
        backing.payout(msg.sender, amount, supplyBefore);
        emit Redeemed(msg.sender, amount);
    }

    /// @notice Burn without redeeming (used by Backing to destroy coin collected as fees).
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}
