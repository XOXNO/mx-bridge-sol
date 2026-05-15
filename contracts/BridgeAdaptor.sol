// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ICoreBridge, CoreBridgeVM} from "wormhole-sdk/interfaces/ICoreBridge.sol";
import {ITokenBridge} from "wormhole-sdk/interfaces/ITokenBridge.sol";
import {IMessageTransmitter} from "wormhole-sdk/interfaces/cctp/IMessageTransmitter.sol";
import {TokenBridgeTransferWithPayload, TokenBridgeMessageLib} from "wormhole-sdk/libraries/TokenBridgeMessages.sol";
import {IERC20Safe} from "./interfaces/IERC20Safe.sol";
import {ILayerZeroComposer} from "./interfaces/ILayerZeroComposer.sol";
import {OFTComposeMsgCodec} from "./libraries/OFTComposeMsgCodec.sol";

/**
 * @title BridgeAdaptor
 * @author MultiversX
 * @notice Multi-protocol bridge adaptor for Wormhole/CCTP integration with ERC20Safe.
 * @dev Upgrade-safe: append new fields by consuming `__gap` slots; never reorder. Storage
 *      layout is pinned by Foundry tests to catch silent dependency drift.
 */
contract BridgeAdaptor is Initializable, ReentrancyGuard, ILayerZeroComposer {
    using SafeERC20 for IERC20;

    // ============ Constants ============
    /// @notice Wormhole chain ID for Ethereum mainnet
    uint16 private constant WORMHOLE_CHAIN_ID_ETHEREUM = 2;
    /// @notice Required `block.chainid` for `initialize`
    uint256 private constant ETHEREUM_MAINNET_CHAIN_ID = 1;
    /// @notice USDC on Ethereum mainnet
    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    /// @notice CCTP V2 hookData starts after the 376-byte header + burn message
    uint256 private constant CCTP_V2_HOOK_DATA_OFFSET = 376;
    /// @notice Minimum encoded length of `abi.encode(bytes32, bytes)`
    uint256 private constant MIN_ABI_ENCODED_HOOK_DATA = 96;
    /// @notice Expected CCTP V2 header version
    uint32 private constant CCTP_V2_MESSAGE_VERSION = 1;
    /// @notice Basis-points denominator
    uint256 private constant BPS_DENOMINATOR = 10_000;
    /// @notice Wormhole percentage fee cap (10%)
    uint16 public constant MAX_WORMHOLE_FEE_BPS = 1_000;
    /// @notice CCTP flat fee cap (100 USDC)
    uint64 public constant MAX_CCTP_FLAT_FEE = 100e6;

    // ============ Core Storage ============
    /// @notice ERC20Safe contract receiving deposits
    IERC20Safe public safe;
    /// @notice Effective admin (rotated via two-step transfer)
    address private _admin;
    /// @notice Pending admin for two-step transfer
    address private _pendingAdmin;

    // ============ Wormhole Storage ============
    /// @notice Wormhole Core Bridge (VAA verification)
    ICoreBridge public wormhole;
    /// @notice Wormhole Token Bridge
    ITokenBridge public wormholeTokenBridge;

    // ============ Packed Storage ============
    /// @notice Circle MessageTransmitter (CCTP V2)
    IMessageTransmitter public circleMessageTransmitter;
    /// @notice Wormhole integration kill-switch
    bool public wormholeEnabled;
    /// @notice Pause state
    bool private _paused;
    /// @notice CCTP flat fee (capped by MAX_CCTP_FLAT_FEE)
    uint64 public cctpFlatFee;
    /// @notice Wormhole fee in bps (capped by MAX_WORMHOLE_FEE_BPS)
    uint16 public wormholeFeeBps;

    /// @notice CCTP integration kill-switch
    bool public cctpEnabled;

    struct LayerZeroState {
        address endpoint;
        bool enabled;
        uint16 feeBps;
        mapping(address oft => address token) oftTokens;
        mapping(address oft => mapping(uint32 srcEid => bool allowed)) allowedSrcEids;
        mapping(bytes32 guid => bool processed) composeProcessed;
    }

    // ============ LayerZero Storage ============
    /// @notice LayerZero EndpointV2, kill-switch, fee, trusted OFTs, source allowlist, and replay guard
    LayerZeroState private _layerZero;

    /// @notice Fee amounts retained by the adaptor and claimable by admin, keyed by ERC20 token.
    mapping(address token => uint256 amount) public accruedFees;

    /// @dev Reserved for future upgrades
    uint256[44] private __gap;

    enum FeeMode {
        Wormhole,
        CCTP,
        LayerZero
    }

    // ============ Custom Errors ============
    error WormholeDisabled();
    error CCTPDisabled();
    error LayerZeroDisabled();
    error InvalidVAA(string reason);
    error InvalidCCTPVersion(uint32 expected, uint32 actual);
    error CircleCCTPNotConfigured();
    error ZeroAmount();
    error InsufficientBalance();
    error InvalidAddress();
    error InvalidRecipient();
    error InvalidTokenAddressFormat();
    error SafePaused();
    error AccessControlSenderNotAdmin();
    error ContractPaused();
    error ContractNotPaused();
    error InvalidPayloadLength();
    error CCTPReceiveFailed();
    error AmountWithinSafeLimits();
    error InsufficientAmountForFee();
    error FeeExceedsMaxBps();
    error FeeExceedsMaxFlat();
    error NotPendingAdmin();
    error TokenNotWhitelisted(address token);
    error WrongChain(uint256 expected, uint256 actual);
    error UnexpectedSafePullDelta(uint256 expected, uint256 actual);
    error InvalidLayerZeroEndpoint(address expected, address actual);
    error LayerZeroOFTNotConfigured(address oft);
    error LayerZeroSourceNotAllowed(address oft, uint32 srcEid);
    error LayerZeroComposeAlreadyProcessed(bytes32 guid);
    error InvalidLayerZeroComposeMessage();
    error InvalidLayerZeroSource();
    error InsufficientAccruedFees(address token, uint256 requested, uint256 available);

    // ============ Events ============
    event Pause(bool isPause);
    event AdminTransferStarted(address indexed currentAdmin, address indexed pendingAdmin);
    event AdminTransferCancelled(address indexed cancelledPendingAdmin);
    event AdminSet(address indexed previousAdmin, address indexed newAdmin);
    event WormholeEnabledChanged(bool enabled);
    event CCTPEnabledChanged(bool enabled);
    event LayerZeroEnabledChanged(bool enabled);
    event WormholeContractsUpdated(address indexed wormhole, address indexed tokenBridge);
    event CircleCCTPUpdated(address indexed messageTransmitter);
    event LayerZeroEndpointUpdated(address indexed endpoint);
    event LayerZeroOFTTokenUpdated(address indexed oft, address indexed token);
    event LayerZeroSourceUpdated(address indexed oft, uint32 indexed srcEid, bool allowed);
    event FeeConfigUpdated(uint64 cctpFlatFee, uint16 wormholeFeeBps);
    event LayerZeroFeeUpdated(uint16 layerZeroFeeBps);
    event FeeAccrued(address indexed token, uint256 amount, FeeMode indexed feeMode);
    event FeesClaimed(address indexed token, address indexed to, uint256 amount);
    event CCTPRescueForwarded(bytes32 indexed mvxRecipient, uint256 amount, uint256 callDataLen);
    event LayerZeroComposeForwarded(
        address indexed oft,
        uint32 indexed srcEid,
        bytes32 indexed guid,
        address token,
        bytes32 mvxRecipient,
        uint256 amount,
        uint256 callDataLen
    );
    event LayerZeroRescueForwarded(
        address indexed token, bytes32 indexed mvxRecipient, uint256 amount, uint256 callDataLen
    );

    // ============ Modifiers ============

    /// @notice Returns the effective admin address
    function admin() public view returns (address) {
        return _admin;
    }

    /// @dev Restricts access to admin only
    modifier onlyAdmin() {
        if (_admin != msg.sender) revert AccessControlSenderNotAdmin();
        _;
    }

    /// @dev Reverts if the contract is paused
    modifier whenNotPaused() {
        if (_paused) revert ContractPaused();
        _;
    }

    /// @dev Reverts if the contract is not paused
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

    /// @notice Initialize the BridgeAdaptor; deployer becomes admin and the contract starts paused.
    /// @param _safe ERC20Safe contract
    /// @param _wormhole Wormhole Core Bridge
    /// @param _tokenBridge Wormhole Token Bridge
    /// @param _circleTransmitter Circle MessageTransmitter
    function initialize(address _safe, address _wormhole, address _tokenBridge, address _circleTransmitter)
        external
        initializer
    {
        if (block.chainid != ETHEREUM_MAINNET_CHAIN_ID) {
            revert WrongChain(ETHEREUM_MAINNET_CHAIN_ID, block.chainid);
        }
        if (_safe == address(0)) revert InvalidAddress();
        if (_wormhole == address(0)) revert InvalidAddress();
        if (_tokenBridge == address(0)) revert InvalidAddress();
        if (_circleTransmitter == address(0)) revert InvalidAddress();

        safe = IERC20Safe(_safe);
        wormhole = ICoreBridge(_wormhole);
        wormholeTokenBridge = ITokenBridge(_tokenBridge);
        circleMessageTransmitter = IMessageTransmitter(_circleTransmitter);
        _admin = msg.sender;
        wormholeEnabled = true;
        cctpEnabled = true;
        _paused = true; // Start paused so admin can configure before opening

        _setFeeConfig(1e6, 5); // 1 USDC flat / 0.05% bps (cap-validated)

        emit AdminSet(address(0), msg.sender);
    }

    // ============ Admin Configuration ============

    /// @notice Nominate a new admin; the nominee must call `acceptAdmin` to take control.
    /// @param newAdmin Address that will become admin once it accepts.
    function transferAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert InvalidAddress();
        _pendingAdmin = newAdmin;
        emit AdminTransferStarted(_admin, newAdmin);
    }

    /// @notice Accept admin transfer (must be called by pending admin)
    function acceptAdmin() external {
        if (msg.sender != _pendingAdmin) revert NotPendingAdmin();
        address previousAdmin = _admin;
        _admin = _pendingAdmin;
        _pendingAdmin = address(0);
        emit AdminSet(previousAdmin, _admin);
    }

    /// @notice Cancel pending admin transfer
    function cancelAdminTransfer() external onlyAdmin {
        address cancelled = _pendingAdmin;
        _pendingAdmin = address(0);
        emit AdminTransferCancelled(cancelled);
    }

    /// @notice Pause the contract
    function pause() external onlyAdmin {
        _paused = true;
        emit Pause(true);
    }

    /// @notice Unpause the contract
    function unpause() external onlyAdmin {
        _paused = false;
        emit Pause(false);
    }

    /// @notice Check if the contract is paused
    function paused() public view returns (bool) {
        return _paused;
    }

    /// @notice Enable/disable Wormhole integration
    function setWormholeEnabled(bool enabled) external onlyAdmin {
        wormholeEnabled = enabled;
        emit WormholeEnabledChanged(enabled);
    }

    /// @notice Enable/disable CCTP integration (per-protocol kill-switch)
    function setCCTPEnabled(bool enabled) external onlyAdmin {
        cctpEnabled = enabled;
        emit CCTPEnabledChanged(enabled);
    }

    /// @notice Enable/disable LayerZero integration (per-protocol kill-switch)
    function setLayerZeroEnabled(bool enabled) external onlyAdmin {
        _layerZero.enabled = enabled;
        emit LayerZeroEnabledChanged(enabled);
    }

    /// @notice Update Wormhole core + token-bridge addresses. Both must be non-zero. Pause-gated.
    function updateWormholeContracts(address _wormhole, address _tokenBridge) external onlyAdmin whenPaused {
        if (_wormhole == address(0) || _tokenBridge == address(0)) revert InvalidAddress();
        wormhole = ICoreBridge(_wormhole);
        wormholeTokenBridge = ITokenBridge(_tokenBridge);
        emit WormholeContractsUpdated(_wormhole, _tokenBridge);
    }

    /// @notice Set Circle MessageTransmitter address. Pause-gated.
    function setCircleTransmitter(address _messageTransmitter) external onlyAdmin whenPaused {
        if (_messageTransmitter == address(0)) revert InvalidAddress();
        circleMessageTransmitter = IMessageTransmitter(_messageTransmitter);
        emit CircleCCTPUpdated(_messageTransmitter);
    }

    /// @notice Set the local LayerZero EndpointV2 address. Pause-gated.
    function setLayerZeroEndpoint(address _endpoint) external onlyAdmin whenPaused {
        if (_endpoint == address(0)) revert InvalidAddress();
        _layerZero.endpoint = _endpoint;
        emit LayerZeroEndpointUpdated(_endpoint);
    }

    /// @notice Map a trusted LayerZero OFT/OFT Adapter to the ERC20 token it credits locally.
    /// @dev Set `token = address(0)` to remove trust for `oft`. Pause-gated.
    function setLayerZeroOFTToken(address oft, address token) external onlyAdmin whenPaused {
        if (oft == address(0)) revert InvalidAddress();
        _layerZero.oftTokens[oft] = token;
        emit LayerZeroOFTTokenUpdated(oft, token);
    }

    /// @notice Allow or disallow a source LayerZero endpoint for a trusted OFT/OFT Adapter.
    function setLayerZeroSource(address oft, uint32 srcEid, bool allowed) external onlyAdmin whenPaused {
        if (oft == address(0)) revert InvalidAddress();
        if (srcEid == 0) revert InvalidLayerZeroSource();
        _layerZero.allowedSrcEids[oft][srcEid] = allowed;
        emit LayerZeroSourceUpdated(oft, srcEid, allowed);
    }

    /// @notice Set the CCTP flat fee and Wormhole bps fee, each bounded by its cap.
    /// @dev Not pause-gated by design; admin may retune fees while the contract is live.
    /// @param _cctpFlatFee Flat fee charged on each CCTP deposit, in USDC base units.
    /// @param _wormholeFeeBps Wormhole fee in basis points, applied to the deposit amount.
    function setFeeConfig(uint64 _cctpFlatFee, uint16 _wormholeFeeBps) external onlyAdmin {
        _setFeeConfig(_cctpFlatFee, _wormholeFeeBps);
    }

    /// @notice Set the LayerZero bps fee, bounded by its cap.
    function setLayerZeroFeeBps(uint16 _layerZeroFeeBps) external onlyAdmin {
        _setLayerZeroFeeBps(_layerZeroFeeBps);
    }

    function _setFeeConfig(uint64 _cctpFlatFee, uint16 _wormholeFeeBps) internal {
        if (_wormholeFeeBps > MAX_WORMHOLE_FEE_BPS) revert FeeExceedsMaxBps();
        if (_cctpFlatFee > MAX_CCTP_FLAT_FEE) revert FeeExceedsMaxFlat();
        cctpFlatFee = _cctpFlatFee;
        wormholeFeeBps = _wormholeFeeBps;
        emit FeeConfigUpdated(_cctpFlatFee, _wormholeFeeBps);
    }

    function _setLayerZeroFeeBps(uint16 _layerZeroFeeBps) internal {
        if (_layerZeroFeeBps > MAX_WORMHOLE_FEE_BPS) revert FeeExceedsMaxBps();
        _layerZero.feeBps = _layerZeroFeeBps;
        emit LayerZeroFeeUpdated(_layerZeroFeeBps);
    }

    // ============ Wormhole Token Bridge Deposits ============

    /// @notice Redeem a Wormhole Token Bridge Type-3 VAA and forward the tokens to the Safe.
    /// @dev Inner payload decodes as `abi.encode(bytes32 mvxRecipient, bytes callData)`.
    /// @param encodedVm Signed Wormhole VAA carrying the token transfer and MultiversX payload.
    function depositFromWormhole(bytes calldata encodedVm) external whenNotPaused nonReentrant {
        if (!wormholeEnabled) revert WormholeDisabled();
        if (safe.paused()) revert SafePaused();

        (address token, uint256 amount, bytes memory innerPayload) = _receiveWormhole(encodedVm);
        if (amount == 0) revert ZeroAmount();
        if (innerPayload.length < MIN_ABI_ENCODED_HOOK_DATA) revert InvalidPayloadLength();

        (bytes32 recipient, bytes memory callData) = abi.decode(innerPayload, (bytes32, bytes));
        if (recipient == bytes32(0)) revert InvalidRecipient();

        _depositToSafe(token, amount, recipient, callData, FeeMode.Wormhole);
    }

    /// @notice Permissionless settlement of a Wormhole VAA outside Safe limits to `admin()`.
    /// @dev Net = amount - fee; fee accrues to the contract.
    function settleOutOfLimitsWormhole(bytes calldata encodedVm) external whenNotPaused nonReentrant {
        if (!wormholeEnabled) revert WormholeDisabled();
        if (safe.paused()) revert SafePaused();
        (address token, uint256 amount,) = _receiveWormhole(encodedVm);
        if (!safe.whitelistedTokens(token)) revert TokenNotWhitelisted(token);
        _requireAmountOutsideSafeLimits(token, amount);

        uint256 fee = _calculateFee(amount, FeeMode.Wormhole);
        if (fee >= amount) revert InsufficientAmountForFee();
        _accrueFee(token, fee, FeeMode.Wormhole);
        IERC20(token).safeTransfer(_admin, amount - fee);
    }

    /// @dev Shared Wormhole receive helper. Returns token, balance-delta amount, embedded payload.
    function _receiveWormhole(bytes calldata encodedVm)
        internal
        returns (address token, uint256 amount, bytes memory innerPayload)
    {
        (CoreBridgeVM memory vm, bool valid, string memory reason) = wormhole.parseAndVerifyVM(encodedVm);
        if (!valid) revert InvalidVAA(reason);

        TokenBridgeTransferWithPayload memory transfer =
            TokenBridgeMessageLib.decodeTransferWithPayloadStructMem(vm.payload);

        uint16 tokenChain = transfer.tokenChainId;
        bytes32 tokenAddressBytes = transfer.tokenAddress;
        if (tokenChain == WORMHOLE_CHAIN_ID_ETHEREUM) {
            if (uint256(tokenAddressBytes) >> 160 != 0) revert InvalidTokenAddressFormat();
            token = address(uint160(uint256(tokenAddressBytes)));
        } else {
            token = wormholeTokenBridge.wrappedAsset(tokenChain, tokenAddressBytes);
        }
        if (token == address(0)) revert InvalidAddress();

        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        wormholeTokenBridge.completeTransferWithPayload(encodedVm);
        amount = IERC20(token).balanceOf(address(this)) - balanceBefore;
        innerPayload = transfer.payload;
    }

    // ============ CCTP V2 Deposits ============

    /// @notice Redeem a CCTP V2 message and forward the minted USDC to the Safe.
    /// @dev hookData decodes as `abi.encode(bytes32 mvxRecipient, bytes callData)`.
    /// @param cctpMessage Raw CCTP V2 message bytes carrying the burn and hookData.
    /// @param cctpAttestation Circle attestation that authorises the message.
    function depositFromCCTPV2(bytes calldata cctpMessage, bytes calldata cctpAttestation)
        external
        whenNotPaused
        nonReentrant
    {
        if (!cctpEnabled) revert CCTPDisabled();
        if (safe.paused()) revert SafePaused();

        (bytes32 mvxRecipient, bytes memory callData) = _extractAndDecodeHookData(cctpMessage);
        if (mvxRecipient == bytes32(0)) revert InvalidRecipient();

        (address token, uint256 amount) = _receiveCCTP(cctpMessage, cctpAttestation);
        if (amount == 0) revert ZeroAmount();

        _depositToSafe(token, amount, mvxRecipient, callData, FeeMode.CCTP);
    }

    /// @notice Permissionless settlement of a CCTP V2 message outside Safe limits to `admin()`.
    function settleOutOfLimitsCCTP(bytes calldata message, bytes calldata attestation)
        external
        whenNotPaused
        nonReentrant
    {
        if (!cctpEnabled) revert CCTPDisabled();
        if (safe.paused()) revert SafePaused();
        (address token, uint256 amount) = _receiveCCTP(message, attestation);
        if (!safe.whitelistedTokens(token)) revert TokenNotWhitelisted(token);
        _requireAmountOutsideSafeLimits(token, amount);

        uint256 fee = _calculateFee(amount, FeeMode.CCTP);
        if (fee >= amount) revert InsufficientAmountForFee();
        _accrueFee(token, fee, FeeMode.CCTP);
        IERC20(token).safeTransfer(_admin, amount - fee);
    }

    /// @notice Forward USDC stranded by a direct CCTP `receiveMessage` to the Safe under the
    ///         supplied recipient and callData.
    /// @dev Admin must match `(mvxRecipient, callData, amount)` to the original burn's hookData
    ///      off-chain before calling.
    /// @param mvxRecipient MultiversX recipient encoded in the original burn hookData.
    /// @param callData Optional MultiversX SC-execution payload from the original burn hookData.
    /// @param amount USDC amount to forward, in USDC base units.
    function rescueAndForwardCCTP(bytes32 mvxRecipient, bytes calldata callData, uint256 amount)
        external
        onlyAdmin
        whenNotPaused
        nonReentrant
    {
        if (!cctpEnabled) revert CCTPDisabled();
        if (safe.paused()) revert SafePaused();
        if (mvxRecipient == bytes32(0)) revert InvalidRecipient();
        if (amount == 0) revert ZeroAmount();
        if (IERC20(USDC).balanceOf(address(this)) < amount) revert InsufficientBalance();

        emit CCTPRescueForwarded(mvxRecipient, amount, callData.length);
        _depositToSafe(USDC, amount, mvxRecipient, callData, FeeMode.CCTP);
    }

    /// @dev Decode `(bytes32 mvxRecipient, bytes callData)` from CCTP V2 hookData; asserts version.
    function _extractAndDecodeHookData(bytes calldata message)
        internal
        pure
        returns (bytes32 mvxRecipient, bytes memory callData)
    {
        if (message.length < CCTP_V2_HOOK_DATA_OFFSET + MIN_ABI_ENCODED_HOOK_DATA) {
            revert InvalidPayloadLength();
        }
        uint32 messageVersion = uint32(bytes4(message[0:4]));
        if (messageVersion != CCTP_V2_MESSAGE_VERSION) {
            revert InvalidCCTPVersion(CCTP_V2_MESSAGE_VERSION, messageVersion);
        }
        bytes calldata hookData = message[CCTP_V2_HOOK_DATA_OFFSET:];
        (mvxRecipient, callData) = abi.decode(hookData, (bytes32, bytes));
    }

    /// @dev Shared CCTP receive helper. Returns USDC token + balance-delta amount.
    function _receiveCCTP(bytes calldata message, bytes calldata attestation)
        internal
        returns (address token, uint256 amount)
    {
        if (address(circleMessageTransmitter) == address(0)) revert CircleCCTPNotConfigured();

        token = USDC;
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        if (!circleMessageTransmitter.receiveMessage(message, attestation)) revert CCTPReceiveFailed();
        amount = IERC20(token).balanceOf(address(this)) - balanceBefore;
    }

    // ============ LayerZero OFT Compose Deposits ============

    /// @notice Receive a LayerZero OFT composed message and forward credited tokens to the Safe.
    /// @dev `message.composeMsg()` decodes as `abi.encode(bytes32 mvxRecipient, bytes callData)`.
    function lzCompose(address _from, bytes32 _guid, bytes calldata _message, address, bytes calldata)
        external
        payable
        whenNotPaused
        nonReentrant
    {
        if (!_layerZero.enabled) revert LayerZeroDisabled();
        if (msg.sender != _layerZero.endpoint) revert InvalidLayerZeroEndpoint(_layerZero.endpoint, msg.sender);
        if (safe.paused()) revert SafePaused();
        if (_layerZero.composeProcessed[_guid]) revert LayerZeroComposeAlreadyProcessed(_guid);

        (address token, uint32 srcEid, uint256 amount, bytes32 mvxRecipient, bytes memory callData) =
            _decodeLayerZeroCompose(_from, _message);

        _layerZero.composeProcessed[_guid] = true;
        emit LayerZeroComposeForwarded(_from, srcEid, _guid, token, mvxRecipient, amount, callData.length);
        _depositToSafe(token, amount, mvxRecipient, callData, FeeMode.LayerZero);
    }

    function _decodeLayerZeroCompose(address _from, bytes calldata _message)
        internal
        view
        returns (address token, uint32 srcEid, uint256 amount, bytes32 mvxRecipient, bytes memory callData)
    {
        token = _layerZero.oftTokens[_from];
        if (token == address(0)) revert LayerZeroOFTNotConfigured(_from);
        if (_message.length < OFTComposeMsgCodec.COMPOSE_MSG_OFFSET + MIN_ABI_ENCODED_HOOK_DATA) {
            revert InvalidLayerZeroComposeMessage();
        }

        srcEid = OFTComposeMsgCodec.srcEid(_message);
        if (!_layerZero.allowedSrcEids[_from][srcEid]) revert LayerZeroSourceNotAllowed(_from, srcEid);

        amount = OFTComposeMsgCodec.amountLD(_message);
        if (amount == 0) revert ZeroAmount();

        (mvxRecipient, callData) = abi.decode(OFTComposeMsgCodec.composeMsg(_message), (bytes32, bytes));
        if (mvxRecipient == bytes32(0)) revert InvalidRecipient();
    }

    /// @notice Forward LayerZero-credited tokens that are stranded in the adaptor to the Safe.
    /// @dev Intended for operational recovery when compose execution was omitted or cannot be retried.
    function rescueAndForwardLayerZero(address token, bytes32 mvxRecipient, bytes calldata callData, uint256 amount)
        external
        onlyAdmin
        whenNotPaused
        nonReentrant
    {
        if (!_layerZero.enabled) revert LayerZeroDisabled();
        if (safe.paused()) revert SafePaused();
        if (token == address(0)) revert InvalidAddress();
        if (mvxRecipient == bytes32(0)) revert InvalidRecipient();
        if (amount == 0) revert ZeroAmount();
        if (IERC20(token).balanceOf(address(this)) < amount) revert InsufficientBalance();

        emit LayerZeroRescueForwarded(token, mvxRecipient, amount, callData.length);
        _depositToSafe(token, amount, mvxRecipient, callData, FeeMode.LayerZero);
    }

    // ============ Internal Functions ============

    /// @dev CCTP = flat fee; Wormhole/LayerZero = bps of amount.
    function _calculateFee(uint256 amount, FeeMode feeMode) internal view returns (uint256) {
        if (feeMode == FeeMode.CCTP) {
            return cctpFlatFee;
        }
        if (feeMode == FeeMode.LayerZero) {
            return (amount * _layerZero.feeBps) / BPS_DENOMINATOR;
        }
        return (amount * wormholeFeeBps) / BPS_DENOMINATOR;
    }

    function _accrueFee(address token, uint256 fee, FeeMode feeMode) internal {
        if (fee == 0) return;
        accruedFees[token] += fee;
        emit FeeAccrued(token, fee, feeMode);
    }

    /// @dev Forward `amount - fee` to the Safe. Whitelist + post-pull balance assertion guard
    ///      against non-whitelisted tokens and fee-on-transfer / blacklist / silent-fail behaviour.
    function _depositToSafe(address token, uint256 amount, bytes32 recipient, bytes memory callData, FeeMode feeMode)
        internal
    {
        if (!safe.whitelistedTokens(token)) revert TokenNotWhitelisted(token);

        uint256 fee = _calculateFee(amount, feeMode);
        if (fee >= amount) revert InsufficientAmountForFee();

        uint256 netAmount = amount - fee;
        _accrueFee(token, fee, feeMode);

        IERC20 erc20 = IERC20(token);
        uint256 balanceBefore = erc20.balanceOf(address(this));
        erc20.forceApprove(address(safe), netAmount);

        if (callData.length > 0) {
            safe.depositWithSCExecution(token, netAmount, recipient, callData);
        } else {
            safe.deposit(token, netAmount, recipient);
        }

        uint256 pulled = balanceBefore - erc20.balanceOf(address(this));
        if (pulled != netAmount) revert UnexpectedSafePullDelta(netAmount, pulled);

        erc20.forceApprove(address(safe), 0); // zero residual allowance
    }

    // ============ View Functions ============

    /// @notice Get the Safe contract address
    function getSafe() external view returns (address) {
        return address(safe);
    }

    /// @notice Get the pending admin address for two-step transfer
    function getPendingAdmin() external view returns (address) {
        return _pendingAdmin;
    }

    /// @notice LayerZero percentage fee cap (10%).
    // solhint-disable-next-line func-name-mixedcase
    function MAX_LAYERZERO_FEE_BPS() external pure returns (uint16) {
        return MAX_WORMHOLE_FEE_BPS;
    }

    /// @notice Get the configured LayerZero EndpointV2 address.
    function layerZeroEndpoint() external view returns (address) {
        return _layerZero.endpoint;
    }

    /// @notice Check whether LayerZero integration is enabled.
    function layerZeroEnabled() external view returns (bool) {
        return _layerZero.enabled;
    }

    /// @notice Get the LayerZero fee in basis points.
    function layerZeroFeeBps() external view returns (uint16) {
        return _layerZero.feeBps;
    }

    /// @notice Get the local ERC20 credited by a trusted LayerZero OFT/OFT Adapter.
    function layerZeroOftTokens(address oft) external view returns (address) {
        return _layerZero.oftTokens[oft];
    }

    /// @notice Check whether a source LayerZero EID is allowed for an OFT/OFT Adapter.
    function layerZeroAllowedSrcEids(address oft, uint32 srcEid) external view returns (bool) {
        return _layerZero.allowedSrcEids[oft][srcEid];
    }

    /// @notice Check whether a LayerZero compose GUID has already been forwarded.
    function layerZeroComposeProcessed(bytes32 guid) external view returns (bool) {
        return _layerZero.composeProcessed[guid];
    }

    // ============ Fee Claiming ============

    /// @notice Claim accrued protocol fees for a token to `to`.
    /// @param token ERC20 token whose accrued fees should be claimed.
    /// @param to Recipient of the claimed fees.
    /// @param amount Amount to claim, in token base units.
    function claimFees(address token, address to, uint256 amount) external onlyAdmin nonReentrant {
        _claimFees(token, to, amount);
    }

    /// @notice Claim all currently accrued protocol fees for a token to `to`.
    /// @param token ERC20 token whose accrued fees should be claimed.
    /// @param to Recipient of the claimed fees.
    function claimAllFees(address token, address to) external onlyAdmin nonReentrant {
        _claimFees(token, to, accruedFees[token]);
    }

    function _claimFees(address token, address to, uint256 amount) internal {
        if (token == address(0)) revert InvalidAddress();
        if (to == address(0)) revert InvalidAddress();
        if (amount == 0) revert ZeroAmount();

        uint256 available = accruedFees[token];
        if (amount > available) revert InsufficientAccruedFees(token, amount, available);
        if (IERC20(token).balanceOf(address(this)) < amount) revert InsufficientBalance();

        accruedFees[token] = available - amount;
        IERC20(token).safeTransfer(to, amount);
        emit FeesClaimed(token, to, amount);
    }

    // ============ Admin Recovery Functions ============

    /// @notice Sweep stuck tokens from this contract to the admin.
    /// @dev Pass `amount = 0` to transfer the unaccounted balance. Accrued fees are protected
    ///      from this emergency path and must be withdrawn through `claimFees` / `claimAllFees`.
    /// @param token ERC20 token to recover.
    /// @param amount Amount to transfer, or `0` to sweep the unaccounted balance.
    function recoverTokens(address token, uint256 amount) external onlyAdmin nonReentrant {
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 feeBalance = accruedFees[token];
        uint256 recoverable = balance > feeBalance ? balance - feeBalance : 0;
        uint256 toTransfer = amount == 0 ? recoverable : amount;
        if (toTransfer > recoverable) revert InsufficientBalance();
        IERC20(token).safeTransfer(_admin, toTransfer);
    }

    /// @dev Reverts if `amount` is within Safe limits (use the normal deposit flow instead).
    function _requireAmountOutsideSafeLimits(address token, uint256 amount) internal view {
        uint256 minLimit = safe.tokenMinLimits(token);
        uint256 maxLimit = safe.tokenMaxLimits(token);
        if (amount >= minLimit && amount <= maxLimit) revert AmountWithinSafeLimits();
    }
}
