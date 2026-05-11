//SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.20;

/**
 * @title IERC20Safe
 * @notice Interface for WormholeAdaptor to interact with ERC20Safe
 */
interface IERC20Safe {
    /**
     * @notice Returns the admin address of the Safe
     */
    function admin() external view returns (address);

    /**
     * @notice Check if a token is whitelisted
     * @param token The token address to check
     */
    function whitelistedTokens(address token) external view returns (bool);

    /**
     * @notice Get the minimum deposit limit for a token
     * @param token The token address
     */
    function tokenMinLimits(address token) external view returns (uint256);

    /**
     * @notice Get the maximum deposit limit for a token
     * @param token The token address
     */
    function tokenMaxLimits(address token) external view returns (uint256);

    /**
     * @notice Deposit tokens to the bridge
     * @param tokenAddress The token to deposit
     * @param amount The amount to deposit
     * @param recipientAddress The MultiversX recipient address
     */
    function deposit(
        address tokenAddress,
        uint256 amount,
        bytes32 recipientAddress
    ) external;

    /**
     * @notice Deposit tokens with smart contract execution on MultiversX
     * @param tokenAddress The token to deposit
     * @param amount The amount to deposit
     * @param recipientAddress The MultiversX recipient address
     * @param callData The call data for SC execution
     */
    function depositWithSCExecution(
        address tokenAddress,
        uint256 amount,
        bytes32 recipientAddress,
        bytes calldata callData
    ) external;

    /**
     * @notice Check if the Safe is paused
     */
    function paused() external view returns (bool);
}
