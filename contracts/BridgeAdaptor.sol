//SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ICoreBridge, CoreBridgeVM} from "wormhole-sdk/interfaces/ICoreBridge.sol";
import {ITokenBridge} from "wormhole-sdk/interfaces/ITokenBridge.sol";
import {IMessageTransmitter} from "wormhole-sdk/interfaces/cctp/IMessageTransmitter.sol";
import {TokenBridgeTransferWithPayload, TokenBridgeMessageLib} from "wormhole-sdk/libraries/TokenBridgeMessages.sol";
import "./interfaces/IERC20Safe.sol";

/**
 * @title BridgeAdaptor
 * @author MultiversX
 * @notice Multi-protocol bridge adaptor for Wormhole/CCTP integration with ERC20Safe
 * @dev Handles VAA verification, token completion, and deposits into ERC20Safe
 */
contract BridgeAdaptor is Initializable {
    using SafeERC20 for IERC20;

    // ============ Constants ============
    /// @notice Wormhole chain ID for Ethereum mainnet
    uint16 private constant WORMHOLE_CHAIN_ID_ETHEREUM = 2;

    /// @notice USDC token address on Ethereum mainnet
    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    /// @notice CCTP V2 hookData offset: Header(148) + BurnMsg fixed(228)
    uint256 private constant CCTP_V2_HOOK_DATA_OFFSET = 376;

    // ============ Core Storage ============
    /// @notice ERC20Safe contract for deposits
    IERC20Safe public safe;
    /// @notice Custom admin address (if set, overrides Safe's admin)
    address private _customAdmin;
    /// @notice Pending admin for two-step transfer
    address private _pendingAdmin;

    // ============ Wormhole Storage ============
    /// @notice Wormhole Core Contract for VAA verification
    ICoreBridge public wormhole;
    /// @notice Wormhole Token Bridge Contract
    ITokenBridge public wormholeTokenBridge;

    // ============ CCTP Storage ============
    /// @notice Circle Message Transmitter for native CCTP
    IMessageTransmitter public circleMessageTransmitter;

    // ============ Packed Storage (1 slot) ============
    /// @notice Flag to enable/disable Wormhole integration
    bool public wormholeEnabled;
    /// @notice Paused state
    bool private _paused;
    /// @notice Fixed fee for CCTP deposits (default: 1e6 = 1 USDC, max ~18.4B)
    uint64 public cctpFlatFee;
    /// @notice Fee basis points for Wormhole deposits (default: 5 = 0.05%, max 10000)
    uint16 public wormholeFeeBps;

    // ============ Constants ============
    uint256 private constant BPS_DENOMINATOR = 10000;

    /// @notice Reserved storage slots for future upgrades
    uint256[40] private __gap;

    // ============ Custom Errors ============
    error WormholeDisabled();
    error InvalidVAA(string reason);
    error CircleCCTPNotConfigured();
    error ZeroAmount();
    error InsufficientBalance();
    error InvalidAddress();
    error InvalidRecipient();
    error SafePaused();
    error AccessControlSenderNotAdmin();
    error ContractPaused();
    error ContractNotPaused();
    error InvalidPayloadLength();
    error CCTPReceiveFailed();
    error AmountWithinSafeLimits();
    error InsufficientAmountForFee();
    error FeeExceedsMaxBps();
    error NotPendingAdmin();

    // ============ Events ============
    event Pause(bool isPause);
    event AdminTransferStarted(address indexed currentAdmin, address indexed pendingAdmin);
    event CustomAdminSet(address indexed previousAdmin, address indexed newAdmin);
    event WormholeEnabledChanged(bool enabled);
    event WormholeContractsUpdated(address wormhole, address tokenBridge);
    event CircleCCTPUpdated(address messageTransmitter);
    event FeeConfigUpdated(uint64 cctpFlatFee, uint16 wormholeFeeBps);

    // ============ Modifiers ============

    /**
     * @dev Returns the effective admin address
     * Uses custom admin if set, otherwise queries Safe's admin
     */
    function admin() public view returns (address) {
        if (_customAdmin != address(0)) {
            return _customAdmin;
        }
        return safe.admin();
    }

    /**
     * @dev Modifier to restrict access to admin only
     */
    modifier onlyAdmin() {
        if (admin() != msg.sender) revert AccessControlSenderNotAdmin();
        _;
    }

    /**
     * @dev Modifier to make a function callable only when not paused
     */
    modifier whenNotPaused() {
        if (_paused) revert ContractPaused();
        _;
    }

    /**
     * @dev Modifier to make a function callable only when paused
     */
    modifier whenPaused() {
        if (!_paused) revert ContractNotPaused();
        _;
    }

    // ============ Constructor ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============ Initialization ============

    /**
     * @notice Initialize the BridgeAdaptor
     * @param _safe ERC20Safe contract address
     * @param _wormhole Wormhole Core Bridge address
     * @param _tokenBridge Wormhole Token Bridge address
     * @param _circleTransmitter Circle MessageTransmitter address
     */
    function initialize(
        address _safe,
        address _wormhole,
        address _tokenBridge,
        address _circleTransmitter
    ) external initializer {
        if (_safe == address(0)) revert InvalidAddress();
        if (_wormhole == address(0)) revert InvalidAddress();
        if (_tokenBridge == address(0)) revert InvalidAddress();
        if (_circleTransmitter == address(0)) revert InvalidAddress();

        safe = IERC20Safe(_safe);
        wormhole = ICoreBridge(_wormhole);
        wormholeTokenBridge = ITokenBridge(_tokenBridge);
        circleMessageTransmitter = IMessageTransmitter(_circleTransmitter);
        _customAdmin = msg.sender; // Deployer becomes admin
        wormholeEnabled = true; // Start enabled
        _paused = true; // Start paused
        cctpFlatFee = 1e6; // 1 USDC
        wormholeFeeBps = 5; // 0.05%
    }

    // ============ Admin Configuration ============

    /**
     * @notice Start two-step admin transfer
     * @dev New admin must call acceptAdmin() to complete transfer
     * @param newAdmin The new admin address (cannot be zero)
     */
    function transferAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert InvalidAddress();
        _pendingAdmin = newAdmin;
        emit AdminTransferStarted(_customAdmin, newAdmin);
    }

    /**
     * @notice Accept admin transfer (must be called by pending admin)
     */
    function acceptAdmin() external {
        if (msg.sender != _pendingAdmin) revert NotPendingAdmin();
        address previousAdmin = _customAdmin;
        _customAdmin = _pendingAdmin;
        _pendingAdmin = address(0);
        emit CustomAdminSet(previousAdmin, _customAdmin);
    }

    /**
     * @notice Cancel pending admin transfer
     */
    function cancelAdminTransfer() external onlyAdmin {
        _pendingAdmin = address(0);
    }

    /**
     * @notice Pause the contract
     */
    function pause() external onlyAdmin {
        _paused = true;
        emit Pause(true);
    }

    /**
     * @notice Unpause the contract
     */
    function unpause() external onlyAdmin {
        _paused = false;
        emit Pause(false);
    }

    /**
     * @notice Check if the contract is paused
     */
    function paused() public view returns (bool) {
        return _paused;
    }

    /**
     * @notice Enable/disable Wormhole integration
     */
    function setWormholeEnabled(bool enabled) external onlyAdmin {
        wormholeEnabled = enabled;
        emit WormholeEnabledChanged(enabled);
    }

    /**
     * @notice Update Wormhole contract addresses (emergency use)
     * @dev Can only be called when paused
     */
    function updateWormholeContracts(
        address _wormhole,
        address _tokenBridge
    ) external onlyAdmin whenPaused {
        if (_wormhole != address(0)) wormhole = ICoreBridge(_wormhole);
        if (_tokenBridge != address(0)) wormholeTokenBridge = ITokenBridge(_tokenBridge);
        emit WormholeContractsUpdated(_wormhole, _tokenBridge);
    }

    /**
     * @notice Set Circle MessageTransmitter contract
     * @param _messageTransmitter Circle's MessageTransmitter contract address
     */
    function setCircleTransmitter(address _messageTransmitter) external onlyAdmin {
        if (_messageTransmitter == address(0)) revert InvalidAddress();
        circleMessageTransmitter = IMessageTransmitter(_messageTransmitter);
        emit CircleCCTPUpdated(_messageTransmitter);
    }

    /**
     * @notice Set fee configuration
     * @param _cctpFlatFee Fixed fee for CCTP deposits (in USDC decimals, e.g., 1e6 = 1 USDC)
     * @param _wormholeFeeBps Fee basis points for Wormhole deposits (e.g., 5 = 0.05%)
     */
    function setFeeConfig(uint64 _cctpFlatFee, uint16 _wormholeFeeBps) external onlyAdmin {
        if (_wormholeFeeBps > BPS_DENOMINATOR) revert FeeExceedsMaxBps();
        cctpFlatFee = _cctpFlatFee;
        wormholeFeeBps = _wormholeFeeBps;
        emit FeeConfigUpdated(_cctpFlatFee, _wormholeFeeBps);
    }

    // ============ Wormhole Token Bridge Deposits ============

    /**
     * @notice Deposit tokens from Wormhole Token Bridge (TransferWithPayload - Type 3)
     * @dev Payload must contain: abi.encode(bytes32 mvxRecipient, bytes callData)
     * @param encodedVm The encoded VAA
     */
    function depositFromWormhole(bytes memory encodedVm) external whenNotPaused {
        if (!wormholeEnabled) revert WormholeDisabled();
        if (safe.paused()) revert SafePaused();

        (address token, uint256 amount, bytes memory innerPayload) = _receiveWormhole(encodedVm);
        if (amount == 0) revert ZeroAmount();
        if (innerPayload.length == 0) revert InvalidPayloadLength();

        (bytes32 recipient, bytes memory callData) = abi.decode(innerPayload, (bytes32, bytes));
        if (recipient == bytes32(0)) revert InvalidRecipient();

        _depositToSafe(token, amount, recipient, callData, false);
    }

    /**
     * @notice Claim Wormhole VAA to admin when amount is outside Safe limits
     * @dev Only works when amount < minLimit or amount > maxLimit. Fee is deducted.
     */
    function claimWormholeToAdmin(bytes memory encodedVm) external {
        (address token, uint256 amount,) = _receiveWormhole(encodedVm);
        _requireAmountOutsideSafeLimits(token, amount);

        uint256 fee = _calculateFee(amount, false);
        if (fee >= amount) revert InsufficientAmountForFee();
        // Fee stays in contract, recoverable via recoverTokens
        address adminAddr = admin();
        IERC20(token).safeTransfer(adminAddr, amount - fee);
    }

    /**
     * @notice Receive Wormhole tokens - shared by deposit and admin claim
     * @return token The received token address
     * @return amount The actual received amount (from balance tracking)
     * @return innerPayload The payload embedded in the transfer
     */
    function _receiveWormhole(bytes memory encodedVm) internal returns (
        address token,
        uint256 amount,
        bytes memory innerPayload
    ) {
        // Parse and verify VAA
        (CoreBridgeVM memory vm, bool valid, string memory reason) = wormhole.parseAndVerifyVM(encodedVm);
        if (!valid) revert InvalidVAA(reason);

        // Decode transfer payload
        TokenBridgeTransferWithPayload memory transfer = TokenBridgeMessageLib.decodeTransferWithPayloadStructMem(vm.payload);

        // Resolve token address
        uint16 tokenChain = transfer.tokenChainId;
        bytes32 tokenAddressBytes = transfer.tokenAddress;
        if (tokenChain == WORMHOLE_CHAIN_ID_ETHEREUM) {
            token = address(uint160(uint256(tokenAddressBytes)));
        } else {
            token = wormholeTokenBridge.wrappedAsset(tokenChain, tokenAddressBytes);
        }

        // Track actual balance change (Wormhole VAA uses 8-decimal normalization which differs from actual tokens)
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));

        // Complete transfer (handles replay protection)
        wormholeTokenBridge.completeTransferWithPayload(encodedVm);

        // Use actual received amount, not normalized VAA amount
        amount = IERC20(token).balanceOf(address(this)) - balanceBefore;
        innerPayload = transfer.payload;
    }

    // ============ CCTP V2 Deposits ============

    /**
     * @notice Deposit tokens from CCTP V2 with hookData
     * @dev HookData format: abi.encode(bytes32 mvxRecipient, bytes callData)
     * @param cctpMessage The Circle CCTP V2 message
     * @param cctpAttestation The Circle attestation signature
     */
    function depositFromCCTPV2(
        bytes calldata cctpMessage,
        bytes calldata cctpAttestation
    ) external whenNotPaused {
        if (safe.paused()) revert SafePaused();

        // Extract MVX recipient from hookData
        (bytes32 mvxRecipient, bytes memory callData) = _extractAndDecodeHookData(cctpMessage);
        if (mvxRecipient == bytes32(0)) revert InvalidRecipient();

        // Receive CCTP tokens
        (address token, uint256 amount) = _receiveCCTP(cctpMessage, cctpAttestation);
        if (amount == 0) revert ZeroAmount();

        _depositToSafe(token, amount, mvxRecipient, callData, true);
    }

    /**
     * @notice Claim CCTP funds to admin when amount is outside Safe limits
     * @dev Only works when amount < minLimit or amount > maxLimit. Fee is deducted.
     */
    function claimCCTPToAdmin(
        bytes calldata message,
        bytes calldata attestation
    ) external {
        (address token, uint256 amount) = _receiveCCTP(message, attestation);
        _requireAmountOutsideSafeLimits(token, amount);

        uint256 fee = _calculateFee(amount, true);
        if (fee >= amount) revert InsufficientAmountForFee();
        // Fee stays in contract, recoverable via recoverTokens
        address adminAddr = admin();
        IERC20(token).safeTransfer(adminAddr, amount - fee);
    }

    /**
     * @notice Extract and decode hookData from CCTP V2 message
     * @dev hookData is at offset 376 (148 byte header + 228 byte BurnMessage fixed fields)
     *      hookData format: abi.encode(bytes32 mvxRecipient, bytes callData)
     * @param message The CCTP V2 message bytes
     * @return mvxRecipient The MultiversX recipient address
     * @return callData Optional SC execution call data
     */
    function _extractAndDecodeHookData(bytes calldata message)
        internal pure returns (bytes32 mvxRecipient, bytes memory callData)
    {
        if (message.length <= CCTP_V2_HOOK_DATA_OFFSET) revert InvalidPayloadLength();

        bytes calldata hookData = message[CCTP_V2_HOOK_DATA_OFFSET:];
        (mvxRecipient, callData) = abi.decode(hookData, (bytes32, bytes));
    }

    /**
     * @notice Receive CCTP tokens - shared by deposit and admin claim
     * @return token The received token address (always USDC)
     * @return amount The received amount
     */
    function _receiveCCTP(
        bytes calldata message,
        bytes calldata attestation
    ) internal returns (address token, uint256 amount) {
        if (address(circleMessageTransmitter) == address(0)) revert CircleCCTPNotConfigured();

        token = USDC;

        // Track balance and receive
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        if (!circleMessageTransmitter.receiveMessage(message, attestation)) revert CCTPReceiveFailed();
        amount = IERC20(token).balanceOf(address(this)) - balanceBefore;
    }

    // ============ Internal Functions ============

    /**
     * @notice Calculate fee for a deposit
     * @param amount The deposit amount
     * @param isCCTP Whether this is a CCTP deposit (flat fee) or Wormhole (percentage)
     * @return fee The calculated fee amount
     */
    function _calculateFee(uint256 amount, bool isCCTP) internal view returns (uint256) {
        if (isCCTP) {
            return cctpFlatFee;
        }
        return (amount * wormholeFeeBps) / BPS_DENOMINATOR;
    }

    /**
     * @notice Deposit tokens to the Safe with fee deduction
     * @param token The token address
     * @param amount The amount to deposit (before fee)
     * @param recipient The MultiversX recipient
     * @param callData SC execution call data (empty for regular deposit)
     * @param isCCTP Whether this is a CCTP deposit (for fee calculation)
     */
    function _depositToSafe(
        address token,
        uint256 amount,
        bytes32 recipient,
        bytes memory callData,
        bool isCCTP
    ) internal {
        uint256 fee = _calculateFee(amount, isCCTP);
        if (fee >= amount) revert InsufficientAmountForFee();

        uint256 netAmount = amount - fee;
        // Fee stays in contract, recoverable via recoverTokens

        IERC20(token).forceApprove(address(safe), netAmount);

        if (callData.length > 0) {
            safe.depositWithSCExecution(token, netAmount, recipient, callData);
        } else {
            safe.deposit(token, netAmount, recipient);
        }
    }

    // ============ View Functions ============

    /**
     * @notice Get the Safe contract address
     * @return The Safe contract address
     */
    function getSafe() external view returns (address) {
        return address(safe);
    }

    /**
     * @notice Get the custom admin address
     * @return The custom admin address (or address(0) if using Safe's admin)
     */
    function getCustomAdmin() external view returns (address) {
        return _customAdmin;
    }

    /**
     * @notice Get the pending admin address for two-step transfer
     * @return The pending admin address (or address(0) if no transfer pending)
     */
    function getPendingAdmin() external view returns (address) {
        return _pendingAdmin;
    }

    // ============ Admin Recovery Functions ============

    /**
     * @notice Recover stuck tokens from the contract to admin wallet
     * @dev Restricted to admin to prevent front-running attacks on deposits
     * @param token The token address to recover
     * @param amount The amount to recover (0 = full balance)
     */
    function recoverTokens(address token, uint256 amount) external onlyAdmin {
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 toTransfer = amount == 0 ? balance : amount;
        if (toTransfer > balance) revert InsufficientBalance();
        address adminAddr = admin();
        IERC20(token).safeTransfer(adminAddr, toTransfer);
    }

    /**
     * @notice Check if amount is outside Safe limits (below min or above max)
     * @dev Reverts if amount is within limits - user should use normal deposit flow
     */
    function _requireAmountOutsideSafeLimits(address token, uint256 amount) internal view {
        uint256 minLimit = safe.tokenMinLimits(token);
        uint256 maxLimit = safe.tokenMaxLimits(token);

        // If amount is within Safe limits, revert - use normal deposit instead
        if (amount >= minLimit && amount <= maxLimit) revert AmountWithinSafeLimits();
    }
}
