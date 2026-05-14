// SPDX-License-Identifier: MIT

pragma solidity 0.8.35;

/**
 * @title ILayerZeroComposer
 * @notice Minimal LayerZero V2 composer interface called by the local EndpointV2.
 */
interface ILayerZeroComposer {
    /**
     * @notice Composes a LayerZero message from an OApp.
     * @param _from OApp/OFT address that queued the composed message on this chain.
     * @param _guid Unique identifier for the corresponding LayerZero message.
     * @param _message Composed message payload.
     * @param _executor Executor address.
     * @param _extraData Additional executor data.
     */
    function lzCompose(
        address _from,
        bytes32 _guid,
        bytes calldata _message,
        address _executor,
        bytes calldata _extraData
    ) external payable;
}
