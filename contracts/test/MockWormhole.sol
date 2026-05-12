// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.35;

import {ICoreBridge, CoreBridgeVM, GuardianSignature, GuardianSet} from "wormhole-sdk/interfaces/ICoreBridge.sol";

/**
 * @title MockWormhole
 * @notice Mock Wormhole Core contract for testing
 */
contract MockWormhole is ICoreBridge {
    // Storage for mock VAA data
    mapping(bytes32 => bool) public validVAAs;
    mapping(bytes32 => CoreBridgeVM) public parsedVMs;

    // Control flags
    bool public alwaysValid = true;
    string public defaultReason = "";

    // Default VM for simpler testing
    CoreBridgeVM public defaultVM;
    bool public useDefaultVM = false;

    /**
     * @notice Set up a mock VAA
     */
    function setMockVAA(
        bytes memory encodedVm,
        uint16 emitterChainId,
        bytes32 emitterAddress,
        uint64 sequence,
        bytes memory payload
    ) external {
        bytes32 vaaHash = keccak256(encodedVm);
        validVAAs[vaaHash] = true;

        CoreBridgeVM storage vm = parsedVMs[vaaHash];
        vm.version = 1;
        vm.timestamp = uint32(block.timestamp);
        vm.nonce = 1;
        vm.emitterChainId = emitterChainId;
        vm.emitterAddress = emitterAddress;
        vm.sequence = sequence;
        vm.consistencyLevel = 200;
        vm.payload = payload;
        vm.guardianSetIndex = 0;
        vm.hash = vaaHash;
    }

    /**
     * @notice Simpler setup for tests - sets a default VM to return for any VAA
     * @param emitterChainId The chain ID of the emitter
     * @param emitterAddress The address of the emitter
     * @param sequence The sequence number
     * @param payload The payload data
     */
    function setMockVM(uint16 emitterChainId, bytes32 emitterAddress, uint64 sequence, bytes memory payload) external {
        defaultVM.version = 1;
        defaultVM.timestamp = uint32(block.timestamp);
        defaultVM.nonce = 1;
        defaultVM.emitterChainId = emitterChainId;
        defaultVM.emitterAddress = emitterAddress;
        defaultVM.sequence = sequence;
        defaultVM.consistencyLevel = 200;
        defaultVM.payload = payload;
        defaultVM.guardianSetIndex = 0;
        defaultVM.hash = keccak256(payload);
        useDefaultVM = true;
    }

    /**
     * @notice Control validation behavior
     */
    function setValidation(bool _alwaysValid, string memory _reason) external {
        alwaysValid = _alwaysValid;
        defaultReason = _reason;
    }

    /**
     * @notice Parse and verify VAA
     */
    function parseAndVerifyVM(bytes calldata encodedVM)
        external
        view
        override
        returns (CoreBridgeVM memory vm, bool valid, string memory reason)
    {
        bytes32 vaaHash = keccak256(encodedVM);

        if (!alwaysValid) {
            return (vm, false, defaultReason);
        }

        // Use default VM if set
        if (useDefaultVM) {
            return (defaultVM, true, "");
        }

        if (validVAAs[vaaHash]) {
            return (parsedVMs[vaaHash], true, "");
        }

        // If not explicitly set, create a default valid VM
        vm.version = 1;
        vm.timestamp = uint32(block.timestamp);
        vm.hash = vaaHash;
        return (vm, true, "");
    }

    // Required interface stubs
    function messageFee() external pure override returns (uint256) {
        return 0;
    }

    function publishMessage(uint32, bytes memory, uint8) external payable override returns (uint64) {
        return 0;
    }

    function chainId() external pure override returns (uint16) {
        return 2; // Ethereum
    }

    function nextSequence(address) external pure override returns (uint64) {
        return 0;
    }

    function getGuardianSet(uint32) external pure override returns (GuardianSet memory) {
        GuardianSet memory gs;
        return gs;
    }

    function getCurrentGuardianSetIndex() external pure override returns (uint32) {
        return 0;
    }
}
