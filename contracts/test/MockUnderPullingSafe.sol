// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Safe} from "../interfaces/IERC20Safe.sol";

/// @notice Safe mock that intentionally pulls one token less than the approval grants.
///         Used to verify BridgeAdaptor's `UnexpectedSafePullDelta` revert (`_depositToSafe`).
contract MockUnderPullingSafe is IERC20Safe {
    address public override admin;
    bool public override paused;

    mapping(address => bool) public override whitelistedTokens;
    mapping(address => uint256) public override tokenMinLimits;
    mapping(address => uint256) public override tokenMaxLimits;

    constructor(address _admin) {
        admin = _admin;
    }

    function whitelistToken(address token, uint256 minLimit, uint256 maxLimit) external {
        whitelistedTokens[token] = true;
        tokenMinLimits[token] = minLimit;
        tokenMaxLimits[token] = maxLimit;
    }

    function deposit(address tokenAddress, uint256 amount, bytes32) external override {
        // Pulls one wei LESS than requested.
        IERC20(tokenAddress).transferFrom(msg.sender, address(this), amount - 1);
    }

    function depositWithSCExecution(address tokenAddress, uint256 amount, bytes32, bytes calldata) external override {
        IERC20(tokenAddress).transferFrom(msg.sender, address(this), amount - 1);
    }
}
