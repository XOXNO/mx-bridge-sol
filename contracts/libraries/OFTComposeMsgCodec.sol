// SPDX-License-Identifier: MIT

pragma solidity 0.8.35;

/**
 * @title OFTComposeMsgCodec
 * @notice Minimal decoder for LayerZero OFT composed messages.
 * @dev Layout: nonce(8) | srcEid(4) | amountLD(32) | composeFrom(32) | composeMsg.
 */
library OFTComposeMsgCodec {
    uint256 internal constant COMPOSE_MSG_OFFSET = 76;

    function srcEid(bytes calldata message) internal pure returns (uint32) {
        return uint32(bytes4(message[8:12]));
    }

    function amountLD(bytes calldata message) internal pure returns (uint256) {
        return uint256(bytes32(message[12:44]));
    }

    function composeFrom(bytes calldata message) internal pure returns (bytes32) {
        return bytes32(message[44:76]);
    }

    function composeMsg(bytes calldata message) internal pure returns (bytes memory) {
        return message[COMPOSE_MSG_OFFSET:];
    }
}
