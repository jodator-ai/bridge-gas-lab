// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title PayableReceiver
/// @notice Minimal payable contract for bridge gas lab testing.
///         Used as the L2 recipient in eth-base-contract test case.
contract PayableReceiver {
    event Received(address indexed from, uint256 amount);

    receive() external payable {
        emit Received(msg.sender, msg.value);
    }

    fallback() external payable {
        emit Received(msg.sender, msg.value);
    }

    function getBalance() external view returns (uint256) {
        return address(this).balance;
    }
}
