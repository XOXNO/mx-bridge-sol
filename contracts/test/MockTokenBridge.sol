//SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.20;

import {ITokenBridge} from "wormhole-sdk/interfaces/ITokenBridge.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MockTokenBridge
 * @notice Mock Wormhole Token Bridge for testing
 */
contract MockTokenBridge is ITokenBridge {
    // Mapping from (chainId, tokenAddress) to wrapped asset
    mapping(bytes32 => address) public wrappedAssets;

    // Token to transfer on completeTransfer
    address public transferToken;
    uint256 public transferAmount;
    address public transferRecipient;

    // Control for auto-transfer
    bool public autoTransfer = true;

    /**
     * @notice Set the wrapped asset mapping
     */
    function setWrappedAsset(uint16 _chainId, bytes32 tokenAddress, address wrapped) external {
        bytes32 key = keccak256(abi.encodePacked(_chainId, tokenAddress));
        wrappedAssets[key] = wrapped;
    }

    /**
     * @notice Configure the transfer to execute on completeTransfer
     */
    function setTransfer(address token, uint256 amount, address recipient) external {
        transferToken = token;
        transferAmount = amount;
        transferRecipient = recipient;
    }

    /**
     * @notice Control auto-transfer behavior
     */
    function setAutoTransfer(bool _autoTransfer) external {
        autoTransfer = _autoTransfer;
    }

    /**
     * @notice Complete a token transfer (mock implementation - Type 1)
     */
    function completeTransfer(bytes calldata /*encodedVm*/) external override {
        if (autoTransfer && transferToken != address(0) && transferAmount > 0) {
            IERC20(transferToken).transfer(transferRecipient, transferAmount);
        }
    }

    /**
     * @notice Complete a token transfer with payload (mock implementation - Type 3)
     * @dev Transfers tokens and returns empty payload (payload is parsed from VAA in adaptor)
     */
    function completeTransferWithPayload(bytes calldata /*encodedVm*/) external override returns (bytes memory) {
        if (autoTransfer && transferToken != address(0) && transferAmount > 0) {
            IERC20(transferToken).transfer(transferRecipient, transferAmount);
        }
        // Return empty payload - the actual payload is parsed from the VAA in the adaptor
        return "";
    }

    /**
     * @notice Get wrapped asset for a token
     */
    function wrappedAsset(uint16 tokenChainId, bytes32 tokenAddress)
        external
        view
        override
        returns (address)
    {
        bytes32 key = keccak256(abi.encodePacked(tokenChainId, tokenAddress));
        return wrappedAssets[key];
    }

    function completeTransferAndUnwrapETH(bytes calldata) external pure override {}

    function completeTransferAndUnwrapETHWithPayload(bytes calldata) external pure override returns (bytes memory) {
        return "";
    }

    function isWrappedAsset(address) external pure override returns (bool) {
        return false;
    }

    function isTransferCompleted(bytes32) external pure override returns (bool) {
        return false;
    }

    function chainId() external pure override returns (uint16) {
        return 2;
    }

    function attestToken(address, uint32) external payable override returns (uint64) {
        return 0;
    }

    function createWrapped(bytes calldata) external pure override returns (address) {
        return address(0);
    }

    function transferTokens(
        address,
        uint256,
        uint16,
        bytes32,
        uint256,
        uint32
    ) external payable override returns (uint64) {
        return 0;
    }

    function transferTokensWithPayload(
        address,
        uint256,
        uint16,
        bytes32,
        uint32,
        bytes calldata
    ) external payable override returns (uint64) {
        return 0;
    }

    // Additional SDK interface stubs
    function wrapAndTransferETH(uint16, bytes32, uint256, uint32) external payable override returns (uint64) {
        return 0;
    }

    function wrapAndTransferETHWithPayload(uint16, bytes32, uint32, bytes calldata) external payable override returns (uint64) {
        return 0;
    }

    function updateWrapped(bytes calldata) external pure override returns (address) {
        return address(0);
    }

    function wormhole() external pure override returns (address) {
        return address(0);
    }

    function bridgeContracts(uint16) external pure override returns (bytes32) {
        return bytes32(0);
    }

    function tokenImplementation() external pure override returns (address) {
        return address(0);
    }

    function WETH() external pure override returns (address) {
        return address(0);
    }
}
