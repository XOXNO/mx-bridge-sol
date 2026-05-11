//SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.20;

import {IMessageTransmitter} from "wormhole-sdk/interfaces/cctp/IMessageTransmitter.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MockCircleMessageTransmitter
 * @notice Mock Circle Message Transmitter for testing native CCTP
 */
contract MockCircleMessageTransmitter is IMessageTransmitter {
    // USDC token address
    address public usdc;

    // Mock transfer amount
    uint256 public mockAmount;

    // Mock source domain (from message)
    uint32 public mockSourceDomain;

    // Control flags
    bool public shouldSucceed = true;

    // Track used nonces for replay protection (returns bool per interface)
    mapping(bytes32 => bool) private _usedNonces;

    constructor(address _usdc) {
        usdc = _usdc;
    }

    /**
     * @notice Set the mock transfer amount
     */
    function setMockAmount(uint256 _amount) external {
        mockAmount = _amount;
    }

    /**
     * @notice Set the mock source domain
     */
    function setMockSourceDomain(uint32 _sourceDomain) external {
        mockSourceDomain = _sourceDomain;
    }

    /**
     * @notice Configure success behavior
     */
    function setShouldSucceed(bool _shouldSucceed) external {
        shouldSucceed = _shouldSucceed;
    }

    /**
     * @notice Receive message (mock implementation)
     * @dev Transfers USDC from this contract to msg.sender to simulate minting
     */
    function receiveMessage(
        bytes calldata message,
        bytes calldata /*attestation*/
    ) external override returns (bool success) {
        if (!shouldSucceed) {
            return false;
        }

        // Parse nonce from message for replay protection (simplified)
        bytes32 nonceKey = keccak256(message);
        require(!_usedNonces[nonceKey], "Nonce already used");
        _usedNonces[nonceKey] = true;

        // Transfer USDC to caller (simulating mint to mintRecipient)
        if (usdc != address(0) && mockAmount > 0) {
            IERC20(usdc).transfer(msg.sender, mockAmount);
        }

        return true;
    }

    // IMessageTransmitter interface implementation
    function usedNonces(bytes32 nonce) external view override returns (bool) {
        return _usedNonces[nonce];
    }

    function localDomain() external pure override returns (uint32) {
        return 0; // Ethereum
    }

    function sendMessage(
        uint32,
        bytes32,
        bytes calldata
    ) external pure override returns (uint64) {
        return 0;
    }

    function sendMessageWithCaller(
        uint32,
        bytes32,
        bytes32,
        bytes calldata
    ) external pure override returns (uint64) {
        return 0;
    }

    function replaceMessage(
        bytes calldata,
        bytes calldata,
        bytes calldata,
        bytes32
    ) external pure override {}

    function version() external pure override returns (uint32) {
        return 1;
    }

    function attesterManager() external pure override returns (address) {
        return address(0);
    }

    function maxMessageBodySize() external pure override returns (uint256) {
        return 8192;
    }

    function nextAvailableNonce() external pure override returns (uint64) {
        return 0;
    }

    // IOwnable2Step stubs
    function acceptOwnership() external pure override {}
    function transferOwnership(address) external pure override {}
    function owner() external pure override returns (address) { return address(0); }
    function pendingOwner() external pure override returns (address) { return address(0); }

    // IPausable stubs
    function pause() external pure override {}
    function unpause() external pure override {}
    function paused() external pure override returns (bool) { return false; }
    function pauser() external pure override returns (address) { return address(0); }
    function updatePauser(address) external pure override {}

    // Attester management stubs
    function enableAttester(address) external pure override {}
    function disableAttester(address) external pure override {}
    function getNumEnabledAttesters() external pure override returns (uint256) { return 1; }
    function getEnabledAttester(uint256) external pure override returns (address) { return address(0); }
    function isEnabledAttester(address) external pure override returns (bool) { return true; }
    function updateAttesterManager(address) external pure override {}
    function setSignatureThreshold(uint256) external pure override {}
    function setMaxMessageBodySize(uint256) external pure override {}
}
