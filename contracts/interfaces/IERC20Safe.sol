// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.35;

/**
 * @title IERC20Safe
 * @notice Interface for the BridgeAdaptor to interact with ERC20Safe
 */
interface IERC20Safe {
    /// @notice Returns the admin address of the Safe
    function admin() external view returns (address);

    /// @notice Check if a token is whitelisted
    function whitelistedTokens(address token) external view returns (bool);

    /// @notice Get the minimum deposit limit for a token
    function tokenMinLimits(address token) external view returns (uint256);

    /// @notice Get the maximum deposit limit for a token
    function tokenMaxLimits(address token) external view returns (uint256);

    /// @notice Deposit tokens to the bridge
    function deposit(address tokenAddress, uint256 amount, bytes32 recipientAddress) external;

    /// @notice Deposit tokens with smart contract execution on MultiversX
    function depositWithSCExecution(
        address tokenAddress,
        uint256 amount,
        bytes32 recipientAddress,
        bytes calldata callData
    ) external;

    /// @notice Check if the Safe is paused
    function paused() external view returns (bool);
}
