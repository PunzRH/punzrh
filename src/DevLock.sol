// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @notice Holds a token allocation until `unlockAt`. No admin, no early exit, no extension needed to prove
///         "the dev cannot sell": anyone can verify the timestamp on the explorer. After `unlockAt`, only the
///         beneficiary can withdraw.
contract DevLock {
    IERC20 public immutable token;
    address public immutable beneficiary;
    uint64 public immutable unlockAt;

    error Locked(uint64 until);
    error NotBeneficiary();

    event Withdrawn(uint256 amount);

    constructor(IERC20 token_, address beneficiary_, uint64 unlockAt_) {
        require(unlockAt_ > block.timestamp, "unlock in past");
        token = token_;
        beneficiary = beneficiary_;
        unlockAt = unlockAt_;
    }

    function locked() external view returns (uint256) {
        return token.balanceOf(address(this));
    }

    function withdraw() external {
        if (msg.sender != beneficiary) revert NotBeneficiary();
        if (block.timestamp < unlockAt) revert Locked(unlockAt);
        uint256 bal = token.balanceOf(address(this));
        token.transfer(beneficiary, bal);
        emit Withdrawn(bal);
    }
}
