// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.35;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../../contracts/BridgeAdaptor.sol";
import "../../contracts/interfaces/IERC20Safe.sol";
import "../../contracts/test/MockERC20.sol";
import "../../contracts/test/MockERC20Safe.sol";
import "../../contracts/test/MockWormhole.sol";
import "../../contracts/test/MockTokenBridge.sol";
import "../../contracts/test/MockCircleMessageTransmitter.sol";
import "../../contracts/test/MockUnderPullingSafe.sol";
import {TokenBridgeMessageLib} from "wormhole-sdk/libraries/TokenBridgeMessages.sol";

contract BridgeAdaptorTest is Test {
    uint16 constant WORMHOLE_CHAIN_ID_ETHEREUM = 2;
    address constant USDC_ADDRESS = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    uint256 constant CCTP_V2_HOOK_DATA_OFFSET = 376;
    uint256 constant ETHEREUM_MAINNET_CHAIN_ID = 1;

    BridgeAdaptor public adaptor;
    BridgeAdaptor public adaptorImpl;
    MockERC20Safe public safe;
    MockWormhole public mockWormhole;
    MockTokenBridge public mockTokenBridge;
    MockCircleMessageTransmitter public mockCircleTransmitter;
    MockERC20 public testToken;
    MockERC20 public usdc;

    address public admin;
    address public user;
    address public attacker;
    address public layerZeroEndpoint;
    address public layerZeroOft;

    bytes32 public constant MVX_RECIPIENT =
        bytes32(uint256(0xc0f0058cea88a2bc1240b60361efb965957038d05f916c42b3f23a2c38ced81e));
    bytes32 public constant SOLANA_EMITTER = bytes32(uint256(uint160(0x1234567890123456789012345678901234567890)));
    bytes32 public constant LAYERZERO_COMPOSE_FROM =
        bytes32(uint256(uint160(0x7777777777777777777777777777777777777777)));
    uint32 public constant ARBITRUM_LZ_EID = 30110;

    uint256 public constant DEFAULT_MIN_LIMIT = 100;
    uint256 public constant DEFAULT_MAX_LIMIT = 1_000_000;

    function setUp() public {
        // Pin chain id to mainnet so initialize() passes its WrongChain guard.
        vm.chainId(ETHEREUM_MAINNET_CHAIN_ID);

        admin = makeAddr("admin");
        user = makeAddr("user");
        attacker = makeAddr("attacker");
        layerZeroEndpoint = makeAddr("layerZeroEndpoint");
        layerZeroOft = makeAddr("layerZeroOft");

        vm.startPrank(admin);

        testToken = new MockERC20("Test Token", "TEST", 18);
        usdc = new MockERC20("USDC", "USDC", 6);

        safe = new MockERC20Safe(admin);
        safe.whitelistToken(address(testToken), DEFAULT_MIN_LIMIT, DEFAULT_MAX_LIMIT);
        safe.whitelistToken(USDC_ADDRESS, DEFAULT_MIN_LIMIT, DEFAULT_MAX_LIMIT);

        mockWormhole = new MockWormhole();
        mockTokenBridge = new MockTokenBridge();
        mockCircleTransmitter = new MockCircleMessageTransmitter(USDC_ADDRESS);

        adaptorImpl = new BridgeAdaptor();
        bytes memory initData = abi.encodeWithSelector(
            BridgeAdaptor.initialize.selector,
            address(safe),
            address(mockWormhole),
            address(mockTokenBridge),
            address(mockCircleTransmitter)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(adaptorImpl), initData);
        adaptor = BridgeAdaptor(address(proxy));

        adaptor.unpause();

        // Pre-fund the mocked TokenBridge with tokens it will "deliver".
        testToken.mint(address(mockTokenBridge), 100_000_000 * 1e18);

        // Place USDC at the canonical mainnet address used by the production constant.
        vm.etch(USDC_ADDRESS, address(usdc).code);
        MockERC20(USDC_ADDRESS).mint(address(mockCircleTransmitter), 100_000_000 * 1e6);

        vm.stopPrank();
    }

    // ============ Helper Functions ============

    function buildWormholePayload(address token, uint256 amount, bytes32 recipient, bytes memory callData)
        internal
        view
        returns (bytes memory)
    {
        bytes memory innerPayload = abi.encode(recipient, callData);
        return TokenBridgeMessageLib.encodeTransferWithPayload(
            amount,
            bytes32(uint256(uint160(token))),
            WORMHOLE_CHAIN_ID_ETHEREUM,
            bytes32(uint256(uint160(address(adaptor)))),
            WORMHOLE_CHAIN_ID_ETHEREUM,
            bytes32(uint256(uint160(admin))),
            innerPayload
        );
    }

    function buildCCTPV2Message(bytes32 recipient, bytes memory callData) internal pure returns (bytes memory) {
        return buildCCTPV2MessageWithVersion(recipient, callData, 1);
    }

    function buildLayerZeroComposeMessage(
        uint64 nonce,
        uint32 srcEid,
        uint256 amount,
        bytes32 composeFrom,
        bytes32 recipient,
        bytes memory callData
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(nonce, srcEid, amount, composeFrom, abi.encode(recipient, callData));
    }

    function configureLayerZero(address oft, address token, uint32 srcEid) internal {
        vm.startPrank(admin);
        adaptor.pause();
        adaptor.setLayerZeroEndpoint(layerZeroEndpoint);
        adaptor.setLayerZeroOFTToken(oft, token);
        adaptor.setLayerZeroSource(oft, srcEid, true);
        adaptor.setLayerZeroFeeBps(5);
        adaptor.setLayerZeroEnabled(true);
        adaptor.unpause();
        vm.stopPrank();
    }

    function configureLayerZeroWithoutSource(address oft, address token) internal {
        vm.startPrank(admin);
        adaptor.pause();
        adaptor.setLayerZeroEndpoint(layerZeroEndpoint);
        adaptor.setLayerZeroOFTToken(oft, token);
        adaptor.setLayerZeroFeeBps(5);
        adaptor.setLayerZeroEnabled(true);
        adaptor.unpause();
        vm.stopPrank();
    }

    function buildCCTPV2MessageWithVersion(bytes32 recipient, bytes memory callData, uint32 version)
        internal
        pure
        returns (bytes memory)
    {
        bytes memory fixedPrefix = new bytes(CCTP_V2_HOOK_DATA_OFFSET);
        // Write the 4-byte version into the header (offset 0)
        bytes4 v = bytes4(version);
        fixedPrefix[0] = v[0];
        fixedPrefix[1] = v[1];
        fixedPrefix[2] = v[2];
        fixedPrefix[3] = v[3];
        bytes memory hookData = abi.encode(recipient, callData);
        return abi.encodePacked(fixedPrefix, hookData);
    }

    /// @notice Configure mockWormhole + mockTokenBridge so a `depositFromWormhole(encodedVm)` call
    ///         actually delivers `amount` of `token` to the adaptor (auto-transfer path).
    function primeWormholeDelivery(
        bytes memory encodedVm,
        address token,
        uint256 amount,
        bytes32 recipient,
        bytes memory callData
    ) internal {
        bytes memory payload = buildWormholePayload(token, amount, recipient, callData);
        mockWormhole.setMockVAA(encodedVm, 1, SOLANA_EMITTER, 1, payload);
        mockTokenBridge.setTransfer(token, amount, address(adaptor));
        mockTokenBridge.setAutoTransfer(true);
    }

    /// @notice Like primeWormholeDelivery but the bridge DOES NOT deliver (used to test ZeroAmount).
    function primeWormholeNoDelivery(
        bytes memory encodedVm,
        address token,
        uint256 amount,
        bytes32 recipient,
        bytes memory callData
    ) internal {
        bytes memory payload = buildWormholePayload(token, amount, recipient, callData);
        mockWormhole.setMockVAA(encodedVm, 1, SOLANA_EMITTER, 1, payload);
        mockTokenBridge.setAutoTransfer(false);
    }

    // ============ Initialization ============

    function test_Initialize_SetsCorrectValues() public view {
        assertEq(adaptor.getSafe(), address(safe));
        assertEq(address(adaptor.wormhole()), address(mockWormhole));
        assertEq(address(adaptor.wormholeTokenBridge()), address(mockTokenBridge));
        assertEq(address(adaptor.circleMessageTransmitter()), address(mockCircleTransmitter));
        assertTrue(adaptor.wormholeEnabled());
        assertEq(adaptor.admin(), admin);
        assertEq(adaptor.cctpFlatFee(), 1e6);
        assertEq(adaptor.wormholeFeeBps(), 5);
        assertEq(adaptor.layerZeroEndpoint(), address(0));
        assertFalse(adaptor.layerZeroEnabled());
        assertEq(adaptor.layerZeroFeeBps(), 0);
    }

    function test_Initialize_RevertsOnZeroSafe() public {
        BridgeAdaptor newImpl = new BridgeAdaptor();
        bytes memory initData = abi.encodeWithSelector(
            BridgeAdaptor.initialize.selector,
            address(0),
            address(mockWormhole),
            address(mockTokenBridge),
            address(mockCircleTransmitter)
        );
        vm.expectRevert(BridgeAdaptor.InvalidAddress.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }

    function test_Initialize_RevertsOnZeroWormhole() public {
        BridgeAdaptor newImpl = new BridgeAdaptor();
        bytes memory initData = abi.encodeWithSelector(
            BridgeAdaptor.initialize.selector,
            address(safe),
            address(0),
            address(mockTokenBridge),
            address(mockCircleTransmitter)
        );
        vm.expectRevert(BridgeAdaptor.InvalidAddress.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }

    function test_Initialize_RevertsOnWrongChain() public {
        vm.chainId(2);
        BridgeAdaptor newImpl = new BridgeAdaptor();
        bytes memory initData = abi.encodeWithSelector(
            BridgeAdaptor.initialize.selector,
            address(safe),
            address(mockWormhole),
            address(mockTokenBridge),
            address(mockCircleTransmitter)
        );
        vm.expectRevert(abi.encodeWithSelector(BridgeAdaptor.WrongChain.selector, 1, 2));
        new ERC1967Proxy(address(newImpl), initData);
    }

    // ============ Admin Functions ============

    function test_TransferAdmin_TwoStep() public {
        address newAdmin = makeAddr("newAdmin");
        vm.prank(admin);
        adaptor.transferAdmin(newAdmin);
        assertEq(adaptor.admin(), admin);
        vm.prank(newAdmin);
        adaptor.acceptAdmin();
        assertEq(adaptor.admin(), newAdmin);
    }

    function test_TransferAdmin_RevertsIfNotAdmin() public {
        vm.prank(attacker);
        vm.expectRevert(BridgeAdaptor.AccessControlSenderNotAdmin.selector);
        adaptor.transferAdmin(attacker);
    }

    function test_AcceptAdmin_RevertsIfNotPendingAdmin() public {
        address newAdmin = makeAddr("newAdmin");
        vm.prank(admin);
        adaptor.transferAdmin(newAdmin);
        vm.prank(attacker);
        vm.expectRevert(BridgeAdaptor.NotPendingAdmin.selector);
        adaptor.acceptAdmin();
    }

    function test_CancelAdminTransfer_ClearsPendingAndEmits() public {
        address newAdmin = makeAddr("newAdmin");
        vm.prank(admin);
        adaptor.transferAdmin(newAdmin);
        assertEq(adaptor.getPendingAdmin(), newAdmin);

        vm.expectEmit(true, false, false, false, address(adaptor));
        emit BridgeAdaptor.AdminTransferCancelled(newAdmin);
        vm.prank(admin);
        adaptor.cancelAdminTransfer();
        assertEq(adaptor.getPendingAdmin(), address(0));
    }

    function test_Pause_Success() public {
        vm.prank(admin);
        adaptor.pause();
        assertTrue(adaptor.paused());
    }

    function test_Unpause_Success() public {
        vm.startPrank(admin);
        adaptor.pause();
        adaptor.unpause();
        vm.stopPrank();
        assertFalse(adaptor.paused());
    }

    function test_SetWormholeEnabled_Success() public {
        vm.prank(admin);
        adaptor.setWormholeEnabled(false);
        assertFalse(adaptor.wormholeEnabled());
    }

    function test_UpdateWormholeContracts_RevertsOnZero() public {
        vm.startPrank(admin);
        adaptor.pause();
        vm.expectRevert(BridgeAdaptor.InvalidAddress.selector);
        adaptor.updateWormholeContracts(address(0), address(mockTokenBridge));
        vm.expectRevert(BridgeAdaptor.InvalidAddress.selector);
        adaptor.updateWormholeContracts(address(mockWormhole), address(0));
        vm.stopPrank();
    }

    function test_UpdateWormholeContracts_SuccessWhenPaused() public {
        MockWormhole newWh = new MockWormhole();
        MockTokenBridge newTb = new MockTokenBridge();
        vm.startPrank(admin);
        adaptor.pause();
        vm.expectEmit(true, true, false, true, address(adaptor));
        emit BridgeAdaptor.WormholeContractsUpdated(address(newWh), address(newTb));
        adaptor.updateWormholeContracts(address(newWh), address(newTb));
        vm.stopPrank();
        assertEq(address(adaptor.wormhole()), address(newWh));
        assertEq(address(adaptor.wormholeTokenBridge()), address(newTb));
    }

    function test_UpdateWormholeContracts_RequiresPause() public {
        vm.prank(admin);
        vm.expectRevert(BridgeAdaptor.ContractNotPaused.selector);
        adaptor.updateWormholeContracts(address(mockWormhole), address(mockTokenBridge));
    }

    function test_SetCircleTransmitter_RequiresPause() public {
        vm.prank(admin);
        vm.expectRevert(BridgeAdaptor.ContractNotPaused.selector);
        adaptor.setCircleTransmitter(address(mockCircleTransmitter));
    }

    function test_SetCircleTransmitter_SuccessWhenPaused() public {
        address newMt = makeAddr("newMt");
        vm.startPrank(admin);
        adaptor.pause();
        adaptor.setCircleTransmitter(newMt);
        vm.stopPrank();
        assertEq(address(adaptor.circleMessageTransmitter()), newMt);
    }

    function test_SetLayerZeroEnabled_Success() public {
        vm.prank(admin);
        adaptor.setLayerZeroEnabled(true);
        assertTrue(adaptor.layerZeroEnabled());
    }

    function test_SetLayerZeroEndpoint_RequiresPause() public {
        vm.prank(admin);
        vm.expectRevert(BridgeAdaptor.ContractNotPaused.selector);
        adaptor.setLayerZeroEndpoint(layerZeroEndpoint);
    }

    function test_SetLayerZeroEndpoint_RevertsOnZero() public {
        vm.startPrank(admin);
        adaptor.pause();
        vm.expectRevert(BridgeAdaptor.InvalidAddress.selector);
        adaptor.setLayerZeroEndpoint(address(0));
        vm.stopPrank();
    }

    function test_SetLayerZeroEndpoint_SuccessWhenPaused() public {
        vm.startPrank(admin);
        adaptor.pause();
        vm.expectEmit(true, false, false, true, address(adaptor));
        emit BridgeAdaptor.LayerZeroEndpointUpdated(layerZeroEndpoint);
        adaptor.setLayerZeroEndpoint(layerZeroEndpoint);
        vm.stopPrank();
        assertEq(adaptor.layerZeroEndpoint(), layerZeroEndpoint);
    }

    function test_SetLayerZeroOFTToken_SuccessAndRemoveWhenPaused() public {
        vm.startPrank(admin);
        adaptor.pause();
        vm.expectEmit(true, true, false, true, address(adaptor));
        emit BridgeAdaptor.LayerZeroOFTTokenUpdated(layerZeroOft, address(testToken));
        adaptor.setLayerZeroOFTToken(layerZeroOft, address(testToken));
        assertEq(adaptor.layerZeroOftTokens(layerZeroOft), address(testToken));

        adaptor.setLayerZeroOFTToken(layerZeroOft, address(0));
        vm.stopPrank();
        assertEq(adaptor.layerZeroOftTokens(layerZeroOft), address(0));
    }

    function test_SetLayerZeroOFTToken_RequiresPause() public {
        vm.prank(admin);
        vm.expectRevert(BridgeAdaptor.ContractNotPaused.selector);
        adaptor.setLayerZeroOFTToken(layerZeroOft, address(testToken));
    }

    function test_SetLayerZeroOFTToken_RevertsOnZeroOFT() public {
        vm.startPrank(admin);
        adaptor.pause();
        vm.expectRevert(BridgeAdaptor.InvalidAddress.selector);
        adaptor.setLayerZeroOFTToken(address(0), address(testToken));
        vm.stopPrank();
    }

    function test_SetLayerZeroSource_SuccessWhenPaused() public {
        vm.startPrank(admin);
        adaptor.pause();
        vm.expectEmit(true, true, false, true, address(adaptor));
        emit BridgeAdaptor.LayerZeroSourceUpdated(layerZeroOft, ARBITRUM_LZ_EID, true);
        adaptor.setLayerZeroSource(layerZeroOft, ARBITRUM_LZ_EID, true);
        vm.stopPrank();
        assertTrue(adaptor.layerZeroAllowedSrcEids(layerZeroOft, ARBITRUM_LZ_EID));
    }

    function test_SetLayerZeroSource_RequiresPause() public {
        vm.prank(admin);
        vm.expectRevert(BridgeAdaptor.ContractNotPaused.selector);
        adaptor.setLayerZeroSource(layerZeroOft, ARBITRUM_LZ_EID, true);
    }

    function test_SetLayerZeroSource_RevertsOnInvalidInput() public {
        vm.startPrank(admin);
        adaptor.pause();
        vm.expectRevert(BridgeAdaptor.InvalidAddress.selector);
        adaptor.setLayerZeroSource(address(0), ARBITRUM_LZ_EID, true);
        vm.expectRevert(BridgeAdaptor.InvalidLayerZeroSource.selector);
        adaptor.setLayerZeroSource(layerZeroOft, 0, true);
        vm.stopPrank();
    }

    // ============ Fee Caps ============

    function test_SetFeeConfig_RevertsAboveBpsCap() public {
        uint16 maxBps = adaptor.MAX_WORMHOLE_FEE_BPS();
        vm.prank(admin);
        vm.expectRevert(BridgeAdaptor.FeeExceedsMaxBps.selector);
        adaptor.setFeeConfig(1, maxBps + 1);
    }

    function test_SetFeeConfig_RevertsAboveFlatCap() public {
        uint64 maxFlat = adaptor.MAX_CCTP_FLAT_FEE();
        vm.prank(admin);
        vm.expectRevert(BridgeAdaptor.FeeExceedsMaxFlat.selector);
        adaptor.setFeeConfig(maxFlat + 1, 5);
    }

    function test_SetFeeConfig_AcceptsAtCap() public {
        uint64 maxFlat = adaptor.MAX_CCTP_FLAT_FEE();
        uint16 maxBps = adaptor.MAX_WORMHOLE_FEE_BPS();
        vm.prank(admin);
        adaptor.setFeeConfig(maxFlat, maxBps);
        assertEq(adaptor.cctpFlatFee(), maxFlat);
        assertEq(adaptor.wormholeFeeBps(), maxBps);
    }

    function test_SetLayerZeroFeeBps_RevertsAboveCap() public {
        uint16 maxBps = adaptor.MAX_LAYERZERO_FEE_BPS();
        vm.prank(admin);
        vm.expectRevert(BridgeAdaptor.FeeExceedsMaxBps.selector);
        adaptor.setLayerZeroFeeBps(maxBps + 1);
    }

    function test_SetLayerZeroFeeBps_AcceptsAtCap() public {
        uint16 maxBps = adaptor.MAX_LAYERZERO_FEE_BPS();
        vm.prank(admin);
        vm.expectEmit(false, false, false, true, address(adaptor));
        emit BridgeAdaptor.LayerZeroFeeUpdated(maxBps);
        adaptor.setLayerZeroFeeBps(maxBps);
        assertEq(adaptor.layerZeroFeeBps(), maxBps);
    }

    // ============ depositFromWormhole ============

    function test_DepositFromWormhole_Success() public {
        uint256 amount = 1000;
        bytes memory encodedVm = "mock_vaa";
        primeWormholeDelivery(encodedVm, address(testToken), amount, MVX_RECIPIENT, "");

        adaptor.depositFromWormhole(encodedVm);

        assertEq(safe.depositCount(), 1);
        MockERC20Safe.DepositRecord memory record = safe.getDeposit(0);
        assertEq(record.token, address(testToken));
        assertEq(record.amount, amount - (amount * 5) / 10_000);
        assertEq(record.recipient, MVX_RECIPIENT);
    }

    function test_DepositFromWormhole_AccruesFee() public {
        uint256 amount = 1_000_000;
        uint256 fee = (amount * adaptor.wormholeFeeBps()) / 10_000;
        bytes memory encodedVm = "mock_vaa_fee";
        primeWormholeDelivery(encodedVm, address(testToken), amount, MVX_RECIPIENT, "");

        vm.expectEmit(true, false, true, true, address(adaptor));
        emit BridgeAdaptor.FeeAccrued(address(testToken), fee, BridgeAdaptor.FeeMode.Wormhole);
        adaptor.depositFromWormhole(encodedVm);

        assertEq(adaptor.accruedFees(address(testToken)), fee);
        assertEq(testToken.balanceOf(address(adaptor)), fee);
        MockERC20Safe.DepositRecord memory record = safe.getDeposit(0);
        assertEq(record.amount, amount - fee);
    }

    function test_DepositFromWormhole_WithSCExecution() public {
        uint256 amount = 2000;
        bytes memory encodedVm = "mock_vaa_sc";
        bytes memory callData = hex"deadbeef";
        primeWormholeDelivery(encodedVm, address(testToken), amount, MVX_RECIPIENT, callData);

        adaptor.depositFromWormhole(encodedVm);
        assertEq(safe.scDepositCount(), 1);
        MockERC20Safe.DepositRecord memory record = safe.getSCDeposit(0);
        assertEq(record.token, address(testToken));
        assertEq(record.amount, amount - (amount * 5) / 10_000);
        assertEq(record.callData, callData);
    }

    function test_DepositFromWormhole_RevertsWhenPaused() public {
        vm.prank(admin);
        adaptor.pause();
        vm.expectRevert(BridgeAdaptor.ContractPaused.selector);
        adaptor.depositFromWormhole("mock_vaa");
    }

    function test_DepositFromWormhole_RevertsWhenWormholeDisabled() public {
        vm.prank(admin);
        adaptor.setWormholeEnabled(false);
        vm.expectRevert(BridgeAdaptor.WormholeDisabled.selector);
        adaptor.depositFromWormhole("mock_vaa");
    }

    function test_DepositFromWormhole_RevertsWhenSafePaused() public {
        safe.setPaused(true);
        vm.expectRevert(BridgeAdaptor.SafePaused.selector);
        adaptor.depositFromWormhole("mock_vaa");
    }

    function test_DepositFromWormhole_RevertsOnInvalidVAA() public {
        mockWormhole.setValidation(false, "Invalid signatures");
        vm.expectRevert(abi.encodeWithSelector(BridgeAdaptor.InvalidVAA.selector, "Invalid signatures"));
        adaptor.depositFromWormhole("invalid_vaa");
    }

    function test_DepositFromWormhole_RevertsOnZeroAmount() public {
        bytes memory encodedVm = "mock_vaa_zero";
        // Bridge does not deliver; balance delta = 0 → ZeroAmount.
        primeWormholeNoDelivery(encodedVm, address(testToken), 0, MVX_RECIPIENT, "");
        vm.expectRevert(BridgeAdaptor.ZeroAmount.selector);
        adaptor.depositFromWormhole(encodedVm);
    }

    function test_DepositFromWormhole_RevertsOnZeroRecipient() public {
        uint256 amount = 1000;
        bytes memory encodedVm = "mock_vaa_zero_recipient";
        primeWormholeDelivery(encodedVm, address(testToken), amount, bytes32(0), "");
        vm.expectRevert(BridgeAdaptor.InvalidRecipient.selector);
        adaptor.depositFromWormhole(encodedVm);
    }

    function test_DepositFromWormhole_RevertsOnNonWhitelistedToken() public {
        MockERC20 spam = new MockERC20("Spam", "SPM", 18);
        spam.mint(address(mockTokenBridge), 1000);

        uint256 amount = 1000;
        bytes memory encodedVm = "spam_vaa";
        primeWormholeDelivery(encodedVm, address(spam), amount, MVX_RECIPIENT, "");

        vm.expectRevert(abi.encodeWithSelector(BridgeAdaptor.TokenNotWhitelisted.selector, address(spam)));
        adaptor.depositFromWormhole(encodedVm);
    }

    // ============ depositFromCCTPV2 ============

    function test_DepositFromCCTPV2_Success() public {
        // Amount must exceed cctpFlatFee (1e6) — use 5 USDC.
        uint256 amount = 5e6;
        bytes memory message = buildCCTPV2Message(MVX_RECIPIENT, "");
        mockCircleTransmitter.setMockAmount(amount);

        adaptor.depositFromCCTPV2(message, "attestation");

        assertEq(safe.depositCount(), 1);
        MockERC20Safe.DepositRecord memory record = safe.getDeposit(0);
        assertEq(record.token, USDC_ADDRESS);
        assertEq(record.amount, amount - 1e6);
        assertEq(record.recipient, MVX_RECIPIENT);
    }

    function test_DepositFromCCTPV2_AccruesFee() public {
        uint256 amount = 5e6;
        bytes memory message = buildCCTPV2Message(MVX_RECIPIENT, "");
        mockCircleTransmitter.setMockAmount(amount);

        vm.expectEmit(true, false, true, true, address(adaptor));
        emit BridgeAdaptor.FeeAccrued(USDC_ADDRESS, 1e6, BridgeAdaptor.FeeMode.CCTP);
        adaptor.depositFromCCTPV2(message, "attestation");

        assertEq(adaptor.accruedFees(USDC_ADDRESS), 1e6);
        assertEq(MockERC20(USDC_ADDRESS).balanceOf(address(adaptor)), 1e6);
    }

    function test_DepositFromCCTPV2_RevertsWhenPaused() public {
        vm.prank(admin);
        adaptor.pause();
        bytes memory message = buildCCTPV2Message(MVX_RECIPIENT, "");
        vm.expectRevert(BridgeAdaptor.ContractPaused.selector);
        adaptor.depositFromCCTPV2(message, "attestation");
    }

    function test_DepositFromCCTPV2_RevertsWhenSafePaused() public {
        safe.setPaused(true);
        bytes memory message = buildCCTPV2Message(MVX_RECIPIENT, "");
        vm.expectRevert(BridgeAdaptor.SafePaused.selector);
        adaptor.depositFromCCTPV2(message, "attestation");
    }

    function test_DepositFromCCTPV2_RevertsOnZeroRecipient() public {
        bytes memory message = buildCCTPV2Message(bytes32(0), "");
        vm.expectRevert(BridgeAdaptor.InvalidRecipient.selector);
        adaptor.depositFromCCTPV2(message, "attestation");
    }

    function test_DepositFromCCTPV2_RevertsOnZeroAmount() public {
        bytes memory message = buildCCTPV2Message(MVX_RECIPIENT, "");
        mockCircleTransmitter.setMockAmount(0);
        vm.expectRevert(BridgeAdaptor.ZeroAmount.selector);
        adaptor.depositFromCCTPV2(message, "attestation");
    }

    function test_DepositFromCCTPV2_RevertsOnShortMessage() public {
        bytes memory shortMessage = new bytes(100);
        vm.expectRevert(BridgeAdaptor.InvalidPayloadLength.selector);
        adaptor.depositFromCCTPV2(shortMessage, "attestation");
    }

    function test_DepositFromCCTPV2_RevertsOnReceiveFailed() public {
        bytes memory message = buildCCTPV2Message(MVX_RECIPIENT, "");
        mockCircleTransmitter.setShouldSucceed(false);
        vm.expectRevert(BridgeAdaptor.CCTPReceiveFailed.selector);
        adaptor.depositFromCCTPV2(message, "attestation");
    }

    // ============ lzCompose ============

    function test_LayerZeroCompose_Success() public {
        configureLayerZero(layerZeroOft, address(testToken), ARBITRUM_LZ_EID);
        uint256 amount = 2000;
        bytes32 guid = keccak256("lz-guid");
        bytes memory message =
            buildLayerZeroComposeMessage(1, ARBITRUM_LZ_EID, amount, LAYERZERO_COMPOSE_FROM, MVX_RECIPIENT, "");
        testToken.mint(address(adaptor), amount);

        vm.prank(layerZeroEndpoint);
        adaptor.lzCompose(layerZeroOft, guid, message, makeAddr("executor"), "");

        assertTrue(adaptor.layerZeroComposeProcessed(guid));
        assertEq(safe.depositCount(), 1);
        MockERC20Safe.DepositRecord memory record = safe.getDeposit(0);
        assertEq(record.token, address(testToken));
        assertEq(record.amount, amount - (amount * 5) / 10_000);
        assertEq(record.recipient, MVX_RECIPIENT);
    }

    function test_LayerZeroCompose_AccruesFee() public {
        configureLayerZero(layerZeroOft, address(testToken), ARBITRUM_LZ_EID);
        uint256 amount = 1_000_000;
        uint256 fee = (amount * adaptor.layerZeroFeeBps()) / 10_000;
        bytes32 guid = keccak256("lz-guid-fee");
        bytes memory message =
            buildLayerZeroComposeMessage(1, ARBITRUM_LZ_EID, amount, LAYERZERO_COMPOSE_FROM, MVX_RECIPIENT, "");
        testToken.mint(address(adaptor), amount);

        vm.expectEmit(true, false, true, true, address(adaptor));
        emit BridgeAdaptor.FeeAccrued(address(testToken), fee, BridgeAdaptor.FeeMode.LayerZero);
        vm.prank(layerZeroEndpoint);
        adaptor.lzCompose(layerZeroOft, guid, message, makeAddr("executor"), "");

        assertEq(adaptor.accruedFees(address(testToken)), fee);
        assertEq(testToken.balanceOf(address(adaptor)), fee);
    }

    function test_LayerZeroCompose_WithSCExecution() public {
        configureLayerZero(layerZeroOft, address(testToken), ARBITRUM_LZ_EID);
        uint256 amount = 3000;
        bytes32 guid = keccak256("lz-guid-sc");
        bytes memory callData = hex"abcdef";
        bytes memory message =
            buildLayerZeroComposeMessage(2, ARBITRUM_LZ_EID, amount, LAYERZERO_COMPOSE_FROM, MVX_RECIPIENT, callData);
        testToken.mint(address(adaptor), amount);

        vm.prank(layerZeroEndpoint);
        adaptor.lzCompose(layerZeroOft, guid, message, makeAddr("executor"), "");

        assertEq(safe.scDepositCount(), 1);
        MockERC20Safe.DepositRecord memory record = safe.getSCDeposit(0);
        assertEq(record.token, address(testToken));
        assertEq(record.amount, amount - (amount * 5) / 10_000);
        assertEq(record.callData, callData);
    }

    function test_LayerZeroCompose_RevertsWhenPaused() public {
        configureLayerZero(layerZeroOft, address(testToken), ARBITRUM_LZ_EID);
        vm.prank(admin);
        adaptor.pause();
        bytes memory message =
            buildLayerZeroComposeMessage(1, ARBITRUM_LZ_EID, 2000, LAYERZERO_COMPOSE_FROM, MVX_RECIPIENT, "");
        vm.prank(layerZeroEndpoint);
        vm.expectRevert(BridgeAdaptor.ContractPaused.selector);
        adaptor.lzCompose(layerZeroOft, keccak256("paused"), message, makeAddr("executor"), "");
    }

    function test_LayerZeroCompose_RevertsWhenDisabled() public {
        configureLayerZero(layerZeroOft, address(testToken), ARBITRUM_LZ_EID);
        vm.prank(admin);
        adaptor.setLayerZeroEnabled(false);
        bytes memory message =
            buildLayerZeroComposeMessage(1, ARBITRUM_LZ_EID, 2000, LAYERZERO_COMPOSE_FROM, MVX_RECIPIENT, "");
        vm.prank(layerZeroEndpoint);
        vm.expectRevert(BridgeAdaptor.LayerZeroDisabled.selector);
        adaptor.lzCompose(layerZeroOft, keccak256("disabled"), message, makeAddr("executor"), "");
    }

    function test_LayerZeroCompose_RevertsFromWrongEndpoint() public {
        configureLayerZero(layerZeroOft, address(testToken), ARBITRUM_LZ_EID);
        bytes memory message =
            buildLayerZeroComposeMessage(1, ARBITRUM_LZ_EID, 2000, LAYERZERO_COMPOSE_FROM, MVX_RECIPIENT, "");
        address wrongEndpoint = makeAddr("wrongEndpoint");
        vm.prank(wrongEndpoint);
        vm.expectRevert(
            abi.encodeWithSelector(BridgeAdaptor.InvalidLayerZeroEndpoint.selector, layerZeroEndpoint, wrongEndpoint)
        );
        adaptor.lzCompose(layerZeroOft, keccak256("wrongEndpoint"), message, makeAddr("executor"), "");
    }

    function test_LayerZeroCompose_RevertsOnUntrustedOFT() public {
        configureLayerZero(layerZeroOft, address(testToken), ARBITRUM_LZ_EID);
        address untrustedOft = makeAddr("untrustedOft");
        bytes memory message =
            buildLayerZeroComposeMessage(1, ARBITRUM_LZ_EID, 2000, LAYERZERO_COMPOSE_FROM, MVX_RECIPIENT, "");
        vm.prank(layerZeroEndpoint);
        vm.expectRevert(abi.encodeWithSelector(BridgeAdaptor.LayerZeroOFTNotConfigured.selector, untrustedOft));
        adaptor.lzCompose(untrustedOft, keccak256("untrusted"), message, makeAddr("executor"), "");
    }

    function test_LayerZeroCompose_RevertsOnDisallowedSource() public {
        configureLayerZeroWithoutSource(layerZeroOft, address(testToken));
        bytes memory message =
            buildLayerZeroComposeMessage(1, ARBITRUM_LZ_EID, 2000, LAYERZERO_COMPOSE_FROM, MVX_RECIPIENT, "");
        vm.prank(layerZeroEndpoint);
        vm.expectRevert(
            abi.encodeWithSelector(BridgeAdaptor.LayerZeroSourceNotAllowed.selector, layerZeroOft, ARBITRUM_LZ_EID)
        );
        adaptor.lzCompose(layerZeroOft, keccak256("bad-source"), message, makeAddr("executor"), "");
    }

    function test_LayerZeroCompose_RevertsOnReplay() public {
        configureLayerZero(layerZeroOft, address(testToken), ARBITRUM_LZ_EID);
        uint256 amount = 2000;
        bytes32 guid = keccak256("replay");
        bytes memory message =
            buildLayerZeroComposeMessage(1, ARBITRUM_LZ_EID, amount, LAYERZERO_COMPOSE_FROM, MVX_RECIPIENT, "");
        testToken.mint(address(adaptor), amount);

        vm.prank(layerZeroEndpoint);
        adaptor.lzCompose(layerZeroOft, guid, message, makeAddr("executor"), "");

        testToken.mint(address(adaptor), amount);
        vm.prank(layerZeroEndpoint);
        vm.expectRevert(abi.encodeWithSelector(BridgeAdaptor.LayerZeroComposeAlreadyProcessed.selector, guid));
        adaptor.lzCompose(layerZeroOft, guid, message, makeAddr("executor"), "");
    }

    function test_LayerZeroCompose_RevertsOnShortMessage() public {
        configureLayerZero(layerZeroOft, address(testToken), ARBITRUM_LZ_EID);
        bytes memory shortMessage = new bytes(100);
        vm.prank(layerZeroEndpoint);
        vm.expectRevert(BridgeAdaptor.InvalidLayerZeroComposeMessage.selector);
        adaptor.lzCompose(layerZeroOft, keccak256("short"), shortMessage, makeAddr("executor"), "");
    }

    function test_LayerZeroCompose_RevertsOnZeroAmount() public {
        configureLayerZero(layerZeroOft, address(testToken), ARBITRUM_LZ_EID);
        bytes memory message =
            buildLayerZeroComposeMessage(1, ARBITRUM_LZ_EID, 0, LAYERZERO_COMPOSE_FROM, MVX_RECIPIENT, "");
        vm.prank(layerZeroEndpoint);
        vm.expectRevert(BridgeAdaptor.ZeroAmount.selector);
        adaptor.lzCompose(layerZeroOft, keccak256("zero-amount"), message, makeAddr("executor"), "");
    }

    function test_LayerZeroCompose_RevertsOnZeroRecipient() public {
        configureLayerZero(layerZeroOft, address(testToken), ARBITRUM_LZ_EID);
        bytes memory message =
            buildLayerZeroComposeMessage(1, ARBITRUM_LZ_EID, 2000, LAYERZERO_COMPOSE_FROM, bytes32(0), "");
        vm.prank(layerZeroEndpoint);
        vm.expectRevert(BridgeAdaptor.InvalidRecipient.selector);
        adaptor.lzCompose(layerZeroOft, keccak256("zero-recipient"), message, makeAddr("executor"), "");
    }

    function test_LayerZeroCompose_RevertsOnNonWhitelistedToken() public {
        MockERC20 spam = new MockERC20("Spam", "SPM", 18);
        configureLayerZero(layerZeroOft, address(spam), ARBITRUM_LZ_EID);
        uint256 amount = 2000;
        bytes memory message =
            buildLayerZeroComposeMessage(1, ARBITRUM_LZ_EID, amount, LAYERZERO_COMPOSE_FROM, MVX_RECIPIENT, "");
        spam.mint(address(adaptor), amount);

        vm.prank(layerZeroEndpoint);
        vm.expectRevert(abi.encodeWithSelector(BridgeAdaptor.TokenNotWhitelisted.selector, address(spam)));
        adaptor.lzCompose(layerZeroOft, keccak256("spam"), message, makeAddr("executor"), "");
    }

    function test_RescueAndForwardLayerZero_Success() public {
        configureLayerZero(layerZeroOft, address(testToken), ARBITRUM_LZ_EID);
        uint256 amount = 2000;
        testToken.mint(address(adaptor), amount);

        vm.prank(admin);
        adaptor.rescueAndForwardLayerZero(address(testToken), MVX_RECIPIENT, "", amount);

        assertEq(safe.depositCount(), 1);
        MockERC20Safe.DepositRecord memory record = safe.getDeposit(0);
        assertEq(record.token, address(testToken));
        assertEq(record.amount, amount - (amount * 5) / 10_000);
        assertEq(record.recipient, MVX_RECIPIENT);
    }

    function test_RescueAndForwardLayerZero_AccruesFee() public {
        configureLayerZero(layerZeroOft, address(testToken), ARBITRUM_LZ_EID);
        uint256 amount = 1_000_000;
        uint256 fee = (amount * adaptor.layerZeroFeeBps()) / 10_000;
        testToken.mint(address(adaptor), amount);

        vm.prank(admin);
        adaptor.rescueAndForwardLayerZero(address(testToken), MVX_RECIPIENT, "", amount);

        assertEq(adaptor.accruedFees(address(testToken)), fee);
        assertEq(testToken.balanceOf(address(adaptor)), fee);
    }

    function test_RescueAndForwardLayerZero_RevertsIfNotAdmin() public {
        configureLayerZero(layerZeroOft, address(testToken), ARBITRUM_LZ_EID);
        vm.prank(attacker);
        vm.expectRevert(BridgeAdaptor.AccessControlSenderNotAdmin.selector);
        adaptor.rescueAndForwardLayerZero(address(testToken), MVX_RECIPIENT, "", 2000);
    }

    // ============ settleOutOfLimitsWormhole ============

    function test_SettleOutOfLimitsWormhole_BelowMin() public {
        uint256 amount = 50; // below DEFAULT_MIN_LIMIT
        bytes memory encodedVm = "vaa_below_min";
        primeWormholeDelivery(encodedVm, address(testToken), amount, MVX_RECIPIENT, "");

        vm.prank(admin);
        adaptor.setFeeConfig(0, 0);

        uint256 before_ = testToken.balanceOf(admin);
        adaptor.settleOutOfLimitsWormhole(encodedVm);
        assertEq(testToken.balanceOf(admin), before_ + amount);
    }

    function test_SettleOutOfLimitsWormhole_AboveMax() public {
        uint256 amount = 2_000_000; // above DEFAULT_MAX_LIMIT
        bytes memory encodedVm = "vaa_above_max";
        primeWormholeDelivery(encodedVm, address(testToken), amount, MVX_RECIPIENT, "");

        vm.prank(admin);
        adaptor.setFeeConfig(0, 0);

        uint256 before_ = testToken.balanceOf(admin);
        adaptor.settleOutOfLimitsWormhole(encodedVm);
        assertEq(testToken.balanceOf(admin), before_ + amount);
    }

    function test_SettleOutOfLimitsWormhole_AccruesFee() public {
        uint256 amount = 2_000_000; // above DEFAULT_MAX_LIMIT
        uint256 fee = (amount * adaptor.wormholeFeeBps()) / 10_000;
        bytes memory encodedVm = "vaa_above_max_fee";
        primeWormholeDelivery(encodedVm, address(testToken), amount, MVX_RECIPIENT, "");

        uint256 before_ = testToken.balanceOf(admin);
        adaptor.settleOutOfLimitsWormhole(encodedVm);

        assertEq(testToken.balanceOf(admin), before_ + amount - fee);
        assertEq(adaptor.accruedFees(address(testToken)), fee);
        assertEq(testToken.balanceOf(address(adaptor)), fee);
    }

    function test_SettleOutOfLimitsWormhole_RevertsWithinLimits() public {
        uint256 amount = 500; // within [100, 1_000_000]
        bytes memory encodedVm = "vaa_within";
        primeWormholeDelivery(encodedVm, address(testToken), amount, MVX_RECIPIENT, "");
        vm.expectRevert(BridgeAdaptor.AmountWithinSafeLimits.selector);
        adaptor.settleOutOfLimitsWormhole(encodedVm);
    }

    function test_SettleOutOfLimitsWormhole_RevertsWhenPaused() public {
        vm.prank(admin);
        adaptor.pause();
        vm.expectRevert(BridgeAdaptor.ContractPaused.selector);
        adaptor.settleOutOfLimitsWormhole("any");
    }

    function test_SettleOutOfLimitsWormhole_RevertsWhenWormholeDisabled() public {
        vm.prank(admin);
        adaptor.setWormholeEnabled(false);
        vm.expectRevert(BridgeAdaptor.WormholeDisabled.selector);
        adaptor.settleOutOfLimitsWormhole("any");
    }

    // ============ settleOutOfLimitsCCTP ============

    function test_SettleOutOfLimitsCCTP_BelowMin() public {
        uint256 amount = 50;
        bytes memory message = buildCCTPV2Message(MVX_RECIPIENT, "");
        mockCircleTransmitter.setMockAmount(amount);

        vm.prank(admin);
        adaptor.setFeeConfig(0, 0);

        uint256 before_ = MockERC20(USDC_ADDRESS).balanceOf(admin);
        adaptor.settleOutOfLimitsCCTP(message, "attestation");
        assertEq(MockERC20(USDC_ADDRESS).balanceOf(admin), before_ + amount);
    }

    function test_SettleOutOfLimitsCCTP_AboveMax() public {
        uint256 amount = 2_000_000;
        bytes memory message = buildCCTPV2Message(MVX_RECIPIENT, "");
        mockCircleTransmitter.setMockAmount(amount);
        MockERC20(USDC_ADDRESS).mint(address(mockCircleTransmitter), amount);

        vm.prank(admin);
        adaptor.setFeeConfig(0, 0);

        uint256 before_ = MockERC20(USDC_ADDRESS).balanceOf(admin);
        adaptor.settleOutOfLimitsCCTP(message, "attestation");
        assertEq(MockERC20(USDC_ADDRESS).balanceOf(admin), before_ + amount);
    }

    function test_SettleOutOfLimitsCCTP_AccruesFee() public {
        uint256 amount = 2_000_000;
        bytes memory message = buildCCTPV2Message(MVX_RECIPIENT, "");
        mockCircleTransmitter.setMockAmount(amount);
        MockERC20(USDC_ADDRESS).mint(address(mockCircleTransmitter), amount);

        uint256 before_ = MockERC20(USDC_ADDRESS).balanceOf(admin);
        adaptor.settleOutOfLimitsCCTP(message, "attestation");

        assertEq(MockERC20(USDC_ADDRESS).balanceOf(admin), before_ + amount - 1e6);
        assertEq(adaptor.accruedFees(USDC_ADDRESS), 1e6);
        assertEq(MockERC20(USDC_ADDRESS).balanceOf(address(adaptor)), 1e6);
    }

    function test_SettleOutOfLimitsCCTP_RevertsWithinLimits() public {
        uint256 amount = 500;
        bytes memory message = buildCCTPV2Message(MVX_RECIPIENT, "");
        mockCircleTransmitter.setMockAmount(amount);
        vm.expectRevert(BridgeAdaptor.AmountWithinSafeLimits.selector);
        adaptor.settleOutOfLimitsCCTP(message, "attestation");
    }

    function test_SettleOutOfLimitsCCTP_RevertsWhenPaused() public {
        vm.prank(admin);
        adaptor.pause();
        bytes memory message = buildCCTPV2Message(MVX_RECIPIENT, "");
        vm.expectRevert(BridgeAdaptor.ContractPaused.selector);
        adaptor.settleOutOfLimitsCCTP(message, "attestation");
    }

    // ============ recoverTokens ============

    function test_RecoverTokens_FullBalance() public {
        uint256 stuckAmount = 5000;
        vm.prank(admin);
        testToken.mint(address(adaptor), stuckAmount);

        uint256 before_ = testToken.balanceOf(admin);
        vm.prank(admin);
        adaptor.recoverTokens(address(testToken), 0);
        assertEq(testToken.balanceOf(admin), before_ + stuckAmount);
        assertEq(testToken.balanceOf(address(adaptor)), 0);
    }

    function test_RecoverTokens_Partial() public {
        uint256 stuckAmount = 5000;
        uint256 recoverAmount = 2000;
        vm.prank(admin);
        testToken.mint(address(adaptor), stuckAmount);

        uint256 before_ = testToken.balanceOf(admin);
        vm.prank(admin);
        adaptor.recoverTokens(address(testToken), recoverAmount);
        assertEq(testToken.balanceOf(admin), before_ + recoverAmount);
        assertEq(testToken.balanceOf(address(adaptor)), stuckAmount - recoverAmount);
    }

    function test_RecoverTokens_OnlyAdmin() public {
        vm.prank(attacker);
        vm.expectRevert(BridgeAdaptor.AccessControlSenderNotAdmin.selector);
        adaptor.recoverTokens(address(testToken), 0);
    }

    function test_RecoverTokens_RevertsOnInsufficientBalance() public {
        vm.prank(admin);
        testToken.mint(address(adaptor), 1000);
        vm.prank(admin);
        vm.expectRevert(BridgeAdaptor.InsufficientBalance.selector);
        adaptor.recoverTokens(address(testToken), 1001);
    }

    function test_RecoverTokens_DoesNotSweepAccruedFees() public {
        uint256 amount = 1_000_000;
        uint256 fee = (amount * adaptor.wormholeFeeBps()) / 10_000;
        bytes memory encodedVm = "recover_protects_fee";
        primeWormholeDelivery(encodedVm, address(testToken), amount, MVX_RECIPIENT, "");
        adaptor.depositFromWormhole(encodedVm);

        vm.prank(admin);
        vm.expectRevert(BridgeAdaptor.InsufficientBalance.selector);
        adaptor.recoverTokens(address(testToken), 1);

        vm.prank(admin);
        adaptor.recoverTokens(address(testToken), 0);

        assertEq(adaptor.accruedFees(address(testToken)), fee);
        assertEq(testToken.balanceOf(address(adaptor)), fee);
    }

    // ============ claimFees ============

    function test_ClaimAllFees_Success() public {
        uint256 amount = 1_000_000;
        uint256 fee = (amount * adaptor.wormholeFeeBps()) / 10_000;
        bytes memory encodedVm = "claim_fee";
        primeWormholeDelivery(encodedVm, address(testToken), amount, MVX_RECIPIENT, "");
        adaptor.depositFromWormhole(encodedVm);

        uint256 before_ = testToken.balanceOf(admin);
        vm.prank(admin);
        vm.expectEmit(true, true, false, true, address(adaptor));
        emit BridgeAdaptor.FeesClaimed(address(testToken), admin, fee);
        adaptor.claimAllFees(address(testToken), admin);

        assertEq(adaptor.accruedFees(address(testToken)), 0);
        assertEq(testToken.balanceOf(address(adaptor)), 0);
        assertEq(testToken.balanceOf(admin), before_ + fee);
    }

    function test_ClaimFees_Partial() public {
        uint256 amount = 1_000_000;
        uint256 fee = (amount * adaptor.wormholeFeeBps()) / 10_000;
        uint256 partialAmount = fee / 2;
        bytes memory encodedVm = "claim_fee_partial";
        primeWormholeDelivery(encodedVm, address(testToken), amount, MVX_RECIPIENT, "");
        adaptor.depositFromWormhole(encodedVm);

        uint256 before_ = testToken.balanceOf(user);
        vm.prank(admin);
        adaptor.claimFees(address(testToken), user, partialAmount);

        assertEq(adaptor.accruedFees(address(testToken)), fee - partialAmount);
        assertEq(testToken.balanceOf(address(adaptor)), fee - partialAmount);
        assertEq(testToken.balanceOf(user), before_ + partialAmount);
    }

    function test_ClaimFees_OnlyAdmin() public {
        vm.prank(attacker);
        vm.expectRevert(BridgeAdaptor.AccessControlSenderNotAdmin.selector);
        adaptor.claimFees(address(testToken), attacker, 1);
    }

    function test_ClaimFees_RevertsOnZeroInputs() public {
        vm.startPrank(admin);
        vm.expectRevert(BridgeAdaptor.InvalidAddress.selector);
        adaptor.claimFees(address(0), admin, 1);
        vm.expectRevert(BridgeAdaptor.InvalidAddress.selector);
        adaptor.claimFees(address(testToken), address(0), 1);
        vm.expectRevert(BridgeAdaptor.ZeroAmount.selector);
        adaptor.claimFees(address(testToken), admin, 0);
        vm.stopPrank();
    }

    function test_ClaimFees_RevertsAboveAccrued() public {
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                BridgeAdaptor.InsufficientAccruedFees.selector, address(testToken), uint256(1), uint256(0)
            )
        );
        adaptor.claimFees(address(testToken), admin, 1);
    }

    function test_ClaimFees_RevertsIfBalanceBelowAccrued() public {
        uint256 fee = 500;
        bytes32 accruedFeesSlot = keccak256(abi.encode(address(testToken), uint256(11)));
        vm.store(address(adaptor), accruedFeesSlot, bytes32(fee));

        vm.prank(admin);
        vm.expectRevert(BridgeAdaptor.InsufficientBalance.selector);
        adaptor.claimAllFees(address(testToken), admin);
    }

    // ============ ForceApprove zero residual ============

    function test_ForceApprove_ZeroedAfterDeposit() public {
        uint256 amount = 1000;
        bytes memory encodedVm = "vaa_approve_zero";
        primeWormholeDelivery(encodedVm, address(testToken), amount, MVX_RECIPIENT, "");

        adaptor.depositFromWormhole(encodedVm);
        assertEq(testToken.allowance(address(adaptor), address(safe)), 0);
    }

    // ============ Invariant-style ============

    function test_Invariant_OnlyAdminCanCallAdminFunctions() public {
        vm.prank(attacker);
        vm.expectRevert(BridgeAdaptor.AccessControlSenderNotAdmin.selector);
        adaptor.pause();

        vm.prank(attacker);
        vm.expectRevert(BridgeAdaptor.AccessControlSenderNotAdmin.selector);
        adaptor.unpause();

        vm.prank(attacker);
        vm.expectRevert(BridgeAdaptor.AccessControlSenderNotAdmin.selector);
        adaptor.setWormholeEnabled(false);

        vm.prank(attacker);
        vm.expectRevert(BridgeAdaptor.AccessControlSenderNotAdmin.selector);
        adaptor.transferAdmin(attacker);

        vm.prank(admin);
        adaptor.pause();
        vm.prank(attacker);
        vm.expectRevert(BridgeAdaptor.AccessControlSenderNotAdmin.selector);
        adaptor.setCircleTransmitter(attacker);
    }

    // ============ Fuzz: deposit ============

    function testFuzz_DepositFromWormhole_Amounts(uint256 amount) public {
        amount = bound(amount, 1, 1e24);
        bytes memory encodedVm = abi.encodePacked("vaa_amt_", amount);
        primeWormholeDelivery(encodedVm, address(testToken), amount, MVX_RECIPIENT, "");

        uint256 fee = (amount * adaptor.wormholeFeeBps()) / 10_000;
        if (fee >= amount) {
            vm.expectRevert(BridgeAdaptor.InsufficientAmountForFee.selector);
            adaptor.depositFromWormhole(encodedVm);
            return;
        }
        adaptor.depositFromWormhole(encodedVm);
        MockERC20Safe.DepositRecord memory record = safe.getDeposit(0);
        assertEq(record.amount, amount - fee);
    }

    function testFuzz_DepositFromWormhole_Recipients(bytes32 recipient) public {
        vm.assume(recipient != bytes32(0));
        uint256 amount = 1000;
        bytes memory encodedVm = abi.encodePacked("vaa_rec_", recipient);
        primeWormholeDelivery(encodedVm, address(testToken), amount, recipient, "");
        adaptor.depositFromWormhole(encodedVm);
        MockERC20Safe.DepositRecord memory record = safe.getDeposit(0);
        assertEq(record.recipient, recipient);
    }

    function testFuzz_DepositFromCCTPV2_Amounts(uint256 amount) public {
        amount = bound(amount, 1, 1e12);
        bytes memory message = buildCCTPV2Message(MVX_RECIPIENT, "");
        MockERC20(USDC_ADDRESS).mint(address(mockCircleTransmitter), amount);
        mockCircleTransmitter.setMockAmount(amount);

        if (amount <= adaptor.cctpFlatFee()) {
            vm.expectRevert(BridgeAdaptor.InsufficientAmountForFee.selector);
            adaptor.depositFromCCTPV2(message, "attestation");
            return;
        }
        adaptor.depositFromCCTPV2(message, "attestation");
        MockERC20Safe.DepositRecord memory record = safe.getDeposit(0);
        assertEq(record.amount, amount - adaptor.cctpFlatFee());
    }

    // ============ NEW: cctpEnabled kill-switch ============

    function test_DepositFromCCTPV2_RevertsWhenCCTPDisabled() public {
        vm.prank(admin);
        adaptor.setCCTPEnabled(false);
        bytes memory message = buildCCTPV2Message(MVX_RECIPIENT, "");
        vm.expectRevert(BridgeAdaptor.CCTPDisabled.selector);
        adaptor.depositFromCCTPV2(message, "attestation");
    }

    function test_SettleOutOfLimitsCCTP_RevertsWhenCCTPDisabled() public {
        vm.prank(admin);
        adaptor.setCCTPEnabled(false);
        bytes memory message = buildCCTPV2Message(MVX_RECIPIENT, "");
        vm.expectRevert(BridgeAdaptor.CCTPDisabled.selector);
        adaptor.settleOutOfLimitsCCTP(message, "attestation");
    }

    function test_SetCCTPEnabled_OnlyAdmin() public {
        vm.prank(attacker);
        vm.expectRevert(BridgeAdaptor.AccessControlSenderNotAdmin.selector);
        adaptor.setCCTPEnabled(false);
    }

    function test_SetCCTPEnabled_TogglesAndEmits() public {
        assertTrue(adaptor.cctpEnabled());
        vm.expectEmit(true, false, false, true, address(adaptor));
        emit BridgeAdaptor.CCTPEnabledChanged(false);
        vm.prank(admin);
        adaptor.setCCTPEnabled(false);
        assertFalse(adaptor.cctpEnabled());
    }

    // ============ NEW: settle path gating ============

    function test_SettleOutOfLimitsWormhole_RevertsWhenSafePaused() public {
        safe.setPaused(true);
        vm.expectRevert(BridgeAdaptor.SafePaused.selector);
        adaptor.settleOutOfLimitsWormhole("any");
    }

    function test_SettleOutOfLimitsCCTP_RevertsWhenSafePaused() public {
        safe.setPaused(true);
        bytes memory message = buildCCTPV2Message(MVX_RECIPIENT, "");
        vm.expectRevert(BridgeAdaptor.SafePaused.selector);
        adaptor.settleOutOfLimitsCCTP(message, "attestation");
    }

    function test_SettleOutOfLimitsWormhole_RevertsOnNonWhitelistedToken() public {
        MockERC20 spam = new MockERC20("Spam", "SPM", 18);
        spam.mint(address(mockTokenBridge), 50);

        uint256 amount = 50; // below default min limit (would otherwise pass settle)
        bytes memory encodedVm = "spam_settle";
        primeWormholeDelivery(encodedVm, address(spam), amount, MVX_RECIPIENT, "");

        vm.expectRevert(abi.encodeWithSelector(BridgeAdaptor.TokenNotWhitelisted.selector, address(spam)));
        adaptor.settleOutOfLimitsWormhole(encodedVm);
    }

    // ============ NEW: CCTP version assertion ============

    function test_DepositFromCCTPV2_RevertsOnWrongVersion() public {
        bytes memory message = buildCCTPV2MessageWithVersion(MVX_RECIPIENT, "", 0);
        vm.expectRevert(abi.encodeWithSelector(BridgeAdaptor.InvalidCCTPVersion.selector, uint32(1), uint32(0)));
        adaptor.depositFromCCTPV2(message, "attestation");
    }

    function test_DepositFromCCTPV2_RevertsOnFutureVersion() public {
        bytes memory message = buildCCTPV2MessageWithVersion(MVX_RECIPIENT, "", 2);
        vm.expectRevert(abi.encodeWithSelector(BridgeAdaptor.InvalidCCTPVersion.selector, uint32(1), uint32(2)));
        adaptor.depositFromCCTPV2(message, "attestation");
    }

    // ============ NEW: Wormhole token-address upper-byte validation ============

    function test_DepositFromWormhole_RevertsOnMalformedTokenAddress() public {
        // tokenChain == 2 (Ethereum) BUT tokenAddress has bits set in the upper 12 bytes
        bytes32 malformed = bytes32(uint256(0xff << 200) | uint256(uint160(address(testToken))));
        bytes memory innerPayload = abi.encode(MVX_RECIPIENT, bytes(""));
        bytes memory payload = TokenBridgeMessageLib.encodeTransferWithPayload(
            1000,
            malformed,
            WORMHOLE_CHAIN_ID_ETHEREUM,
            bytes32(uint256(uint160(address(adaptor)))),
            WORMHOLE_CHAIN_ID_ETHEREUM,
            bytes32(uint256(uint160(admin))),
            innerPayload
        );
        bytes memory encodedVm = "malformed_vaa";
        mockWormhole.setMockVAA(encodedVm, 1, SOLANA_EMITTER, 1, payload);

        vm.expectRevert(BridgeAdaptor.InvalidTokenAddressFormat.selector);
        adaptor.depositFromWormhole(encodedVm);
    }

    // ============ NEW: initialize fee cap validation ============

    function test_Initialize_FeeCapsAreEnforced() public view {
        // Defaults must respect caps after init
        assertLe(adaptor.cctpFlatFee(), adaptor.MAX_CCTP_FLAT_FEE());
        assertLe(adaptor.wormholeFeeBps(), adaptor.MAX_WORMHOLE_FEE_BPS());
    }

    // ============ NEW: rescueAndForwardCCTP ============

    function test_RescueAndForwardCCTP_Success() public {
        uint256 stuck = 5e6; // 5 USDC sitting in the adaptor (e.g. from direct receiveMessage)
        MockERC20(USDC_ADDRESS).mint(address(adaptor), stuck);

        vm.prank(admin);
        adaptor.rescueAndForwardCCTP(MVX_RECIPIENT, "", stuck);

        MockERC20Safe.DepositRecord memory record = safe.getDeposit(0);
        assertEq(record.token, USDC_ADDRESS);
        assertEq(record.amount, stuck - 1e6); // minus cctpFlatFee
        assertEq(record.recipient, MVX_RECIPIENT);
    }

    function test_RescueAndForwardCCTP_OnlyAdmin() public {
        vm.prank(attacker);
        vm.expectRevert(BridgeAdaptor.AccessControlSenderNotAdmin.selector);
        adaptor.rescueAndForwardCCTP(MVX_RECIPIENT, "", 1e6);
    }

    function test_RescueAndForwardCCTP_RevertsOnZeroRecipient() public {
        vm.prank(admin);
        vm.expectRevert(BridgeAdaptor.InvalidRecipient.selector);
        adaptor.rescueAndForwardCCTP(bytes32(0), "", 1e6);
    }

    function test_RescueAndForwardCCTP_RevertsOnZeroAmount() public {
        vm.prank(admin);
        vm.expectRevert(BridgeAdaptor.ZeroAmount.selector);
        adaptor.rescueAndForwardCCTP(MVX_RECIPIENT, "", 0);
    }

    function test_RescueAndForwardCCTP_RevertsOnInsufficientBalance() public {
        vm.prank(admin);
        vm.expectRevert(BridgeAdaptor.InsufficientBalance.selector);
        adaptor.rescueAndForwardCCTP(MVX_RECIPIENT, "", 1e6);
    }

    function test_RescueAndForwardCCTP_RevertsWhenPaused() public {
        vm.prank(admin);
        adaptor.pause();
        vm.prank(admin);
        vm.expectRevert(BridgeAdaptor.ContractPaused.selector);
        adaptor.rescueAndForwardCCTP(MVX_RECIPIENT, "", 1e6);
    }

    function test_RescueAndForwardCCTP_RevertsWhenCCTPDisabled() public {
        vm.prank(admin);
        adaptor.setCCTPEnabled(false);
        vm.prank(admin);
        vm.expectRevert(BridgeAdaptor.CCTPDisabled.selector);
        adaptor.rescueAndForwardCCTP(MVX_RECIPIENT, "", 1e6);
    }

    // ============ NEW: storage layout pin ============
    // Slot 0: safe; 1: _admin; 2: _pendingAdmin; 3: wormhole; 4: wormholeTokenBridge;
    // 5: packed (circleMessageTransmitter+wormholeEnabled+_paused+cctpFlatFee+wormholeFeeBps);
    // 6: cctpEnabled; 7: packed LayerZeroConfig(endpoint+enabled+feeBps);
    // 8: layerZeroOftTokens; 9: layerZeroAllowedSrcEids; 10: layerZeroComposeProcessed;
    // 11: accruedFees; 12-55: __gap[44].

    function test_StorageLayout_Slot0_Safe() public view {
        bytes32 v = vm.load(address(adaptor), bytes32(uint256(0)));
        assertEq(address(uint160(uint256(v))), address(safe));
    }

    function test_StorageLayout_Slot1_Admin() public view {
        bytes32 v = vm.load(address(adaptor), bytes32(uint256(1)));
        assertEq(address(uint160(uint256(v))), admin);
    }

    function test_StorageLayout_Slot3_Wormhole() public view {
        bytes32 v = vm.load(address(adaptor), bytes32(uint256(3)));
        assertEq(address(uint160(uint256(v))), address(mockWormhole));
    }

    function test_StorageLayout_Slot5_PackedFlagsAndFees() public view {
        bytes32 v = vm.load(address(adaptor), bytes32(uint256(5)));
        uint256 raw = uint256(v);
        // circleMessageTransmitter at offset 0, 20 bytes
        address mt = address(uint160(raw & ((1 << 160) - 1)));
        // wormholeEnabled at offset 20 (= bit 160)
        bool we = ((raw >> 160) & 0xff) != 0;
        // _paused at offset 21 (= bit 168)  — private, but slot reads it
        bool pp = ((raw >> 168) & 0xff) != 0;
        // cctpFlatFee at offset 22 (= bit 176), 8 bytes
        uint64 flat = uint64((raw >> 176) & ((uint256(1) << 64) - 1));
        // wormholeFeeBps at offset 30 (= bit 240), 2 bytes
        uint16 bps = uint16((raw >> 240) & 0xffff);

        assertEq(mt, address(mockCircleTransmitter));
        assertTrue(we);
        // adaptor.unpause() ran in setUp
        assertFalse(pp);
        assertEq(flat, 1e6);
        assertEq(bps, 5);
    }

    function test_StorageLayout_Slot6_CCTPEnabled() public view {
        bytes32 v = vm.load(address(adaptor), bytes32(uint256(6)));
        assertEq(uint256(v) & 0xff, 1);
    }

    function test_StorageLayout_Slot7_LayerZeroPacked() public {
        vm.startPrank(admin);
        adaptor.pause();
        adaptor.setLayerZeroEndpoint(layerZeroEndpoint);
        adaptor.setLayerZeroFeeBps(7);
        adaptor.setLayerZeroEnabled(true);
        vm.stopPrank();

        bytes32 v = vm.load(address(adaptor), bytes32(uint256(7)));
        uint256 raw = uint256(v);
        address endpoint = address(uint160(raw & ((1 << 160) - 1)));
        bool layerZeroEnabled = ((raw >> 160) & 0xff) != 0;
        uint16 bps = uint16((raw >> 168) & 0xffff);

        assertEq(endpoint, layerZeroEndpoint);
        assertTrue(layerZeroEnabled);
        assertEq(bps, 7);
    }

    function test_StorageLayout_Slot11_AccruedFees() public {
        bytes32 slot = keccak256(abi.encode(address(testToken), uint256(11)));
        vm.store(address(adaptor), slot, bytes32(uint256(123)));
        assertEq(adaptor.accruedFees(address(testToken)), 123);
    }

    // ============ NEW: Wormhole wrapped-asset path (BridgeAdaptor.sol:311 else branch) ============

    /// @notice Cover the non-Ethereum-origin token branch where the adaptor calls
    ///         `wormholeTokenBridge.wrappedAsset(chainId, tokenAddress)` to resolve the local ERC20.
    function test_DepositFromWormhole_WrappedAssetPath() public {
        uint16 SOL_CHAIN_ID = 1;
        bytes32 solanaToken = bytes32(uint256(0xdeadbeef));
        // Register the mapping in the mock TokenBridge: (sourceChain, sourceToken) -> testToken
        mockTokenBridge.setWrappedAsset(SOL_CHAIN_ID, solanaToken, address(testToken));

        uint256 amount = 1000;
        bytes memory innerPayload = abi.encode(MVX_RECIPIENT, bytes(""));
        bytes memory payload = TokenBridgeMessageLib.encodeTransferWithPayload(
            amount,
            solanaToken,
            SOL_CHAIN_ID,
            bytes32(uint256(uint160(address(adaptor)))),
            WORMHOLE_CHAIN_ID_ETHEREUM,
            bytes32(uint256(uint160(admin))),
            innerPayload
        );
        bytes memory encodedVm = "wrapped_vaa";
        mockWormhole.setMockVAA(encodedVm, SOL_CHAIN_ID, SOLANA_EMITTER, 1, payload);

        // Bridge delivers the resolved testToken
        mockTokenBridge.setTransfer(address(testToken), amount, address(adaptor));
        mockTokenBridge.setAutoTransfer(true);

        adaptor.depositFromWormhole(encodedVm);

        MockERC20Safe.DepositRecord memory record = safe.getDeposit(0);
        assertEq(record.token, address(testToken));
        assertEq(record.recipient, MVX_RECIPIENT);
        assertEq(record.amount, amount - (amount * 5) / 10_000);
    }

    /// @notice Wormhole VAA where the wrapped-asset lookup returns address(0) — should revert.
    function test_DepositFromWormhole_RevertsOnUnknownWrappedAsset() public {
        uint16 UNKNOWN_CHAIN = 99;
        bytes32 unknownToken = bytes32(uint256(0xc0ffee));
        // Intentionally do NOT register the mapping → wrappedAsset returns address(0)

        uint256 amount = 1000;
        bytes memory innerPayload = abi.encode(MVX_RECIPIENT, bytes(""));
        bytes memory payload = TokenBridgeMessageLib.encodeTransferWithPayload(
            amount,
            unknownToken,
            UNKNOWN_CHAIN,
            bytes32(uint256(uint160(address(adaptor)))),
            WORMHOLE_CHAIN_ID_ETHEREUM,
            bytes32(uint256(uint160(admin))),
            innerPayload
        );
        bytes memory encodedVm = "unknown_wrapped";
        mockWormhole.setMockVAA(encodedVm, UNKNOWN_CHAIN, SOLANA_EMITTER, 1, payload);

        vm.expectRevert(BridgeAdaptor.InvalidAddress.selector);
        adaptor.depositFromWormhole(encodedVm);
    }

    // ============ NEW: malformed-payload paths ============

    /// @notice Wormhole inner payload long enough to pass the length floor but malformed for abi.decode.
    ///         abi.decode reverts when the bytes-length prefix points past the end of data.
    function test_DepositFromWormhole_RevertsOnMalformedInnerPayload() public {
        uint256 amount = 1000;
        // Construct a 96-byte buffer that is NOT a valid abi.encode(bytes32, bytes):
        //   word 0 (32): mvxRecipient (a non-zero bytes32 to bypass the recipient check)
        //   word 1 (32): offset to bytes data = 0x40 (correct)
        //   word 2 (32): bytes length = 0xffffffff (huge — will overflow buffer)
        bytes memory garbage = new bytes(96);
        bytes32 fakeRecipient = MVX_RECIPIENT;
        assembly {
            mstore(add(garbage, 32), fakeRecipient)
            mstore(add(garbage, 64), 0x40)
            mstore(add(garbage, 96), 0xffffffff)
        }

        bytes memory payload = TokenBridgeMessageLib.encodeTransferWithPayload(
            amount,
            bytes32(uint256(uint160(address(testToken)))),
            WORMHOLE_CHAIN_ID_ETHEREUM,
            bytes32(uint256(uint160(address(adaptor)))),
            WORMHOLE_CHAIN_ID_ETHEREUM,
            bytes32(uint256(uint160(admin))),
            garbage
        );
        bytes memory encodedVm = "malformed_inner";
        mockWormhole.setMockVAA(encodedVm, 1, SOLANA_EMITTER, 1, payload);
        mockTokenBridge.setTransfer(address(testToken), amount, address(adaptor));
        mockTokenBridge.setAutoTransfer(true);

        // abi.decode reverts; we don't care which low-level revert reason — just that the call fails.
        vm.expectRevert();
        adaptor.depositFromWormhole(encodedVm);
    }

    /// @notice CCTP message with valid header + length but garbage hookData → abi.decode reverts.
    function test_DepositFromCCTPV2_RevertsOnMalformedHookData() public {
        // Build header: version=1 + zero-pad to CCTP_V2_HOOK_DATA_OFFSET, then 96 bytes of garbage hookData.
        bytes memory fixedPrefix = new bytes(CCTP_V2_HOOK_DATA_OFFSET);
        bytes4 v1 = bytes4(uint32(1));
        fixedPrefix[0] = v1[0];
        fixedPrefix[1] = v1[1];
        fixedPrefix[2] = v1[2];
        fixedPrefix[3] = v1[3];

        // Garbage hookData: declares a bytes-length larger than what's encoded.
        bytes memory garbage = new bytes(96);
        bytes32 fakeRecipient = MVX_RECIPIENT;
        assembly {
            mstore(add(garbage, 32), fakeRecipient)
            mstore(add(garbage, 64), 0x40)
            mstore(add(garbage, 96), 0xffffffff)
        }

        bytes memory message = abi.encodePacked(fixedPrefix, garbage);

        vm.expectRevert();
        adaptor.depositFromCCTPV2(message, "attestation");
    }

    // ============ NEW: CCTP replay ============

    /// @notice Second submission of the same CCTP message must revert (the mock tracks nonces).
    function test_DepositFromCCTPV2_RevertsOnReplay() public {
        uint256 amount = 5e6;
        bytes memory message = buildCCTPV2Message(MVX_RECIPIENT, "");
        mockCircleTransmitter.setMockAmount(amount);

        // First call succeeds.
        adaptor.depositFromCCTPV2(message, "attestation");

        // Mint more USDC so the replay isn't blocked by an empty mintFrom; the mock should still revert
        // on nonce reuse before any transfer happens.
        MockERC20(USDC_ADDRESS).mint(address(mockCircleTransmitter), amount);

        // Second call with the SAME message → MockCircleMessageTransmitter rejects "Nonce already used".
        vm.expectRevert(bytes("Nonce already used"));
        adaptor.depositFromCCTPV2(message, "attestation");
    }

    // ============ NEW: malicious-Safe under-pull → UnexpectedSafePullDelta ============

    // ============ NEW: 10 branch-coverage tests ============

    /// @notice initialize: zero token-bridge address.
    function test_Initialize_RevertsOnZeroTokenBridge() public {
        BridgeAdaptor newImpl = new BridgeAdaptor();
        bytes memory initData = abi.encodeWithSelector(
            BridgeAdaptor.initialize.selector,
            address(safe),
            address(mockWormhole),
            address(0),
            address(mockCircleTransmitter)
        );
        vm.expectRevert(BridgeAdaptor.InvalidAddress.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }

    /// @notice initialize: zero Circle transmitter.
    function test_Initialize_RevertsOnZeroCircle() public {
        BridgeAdaptor newImpl = new BridgeAdaptor();
        bytes memory initData = abi.encodeWithSelector(
            BridgeAdaptor.initialize.selector,
            address(safe),
            address(mockWormhole),
            address(mockTokenBridge),
            address(0)
        );
        vm.expectRevert(BridgeAdaptor.InvalidAddress.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }

    /// @notice transferAdmin: rejects zero address.
    function test_TransferAdmin_RevertsOnZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(BridgeAdaptor.InvalidAddress.selector);
        adaptor.transferAdmin(address(0));
    }

    /// @notice setCircleTransmitter: rejects zero address (must be paused first).
    function test_SetCircleTransmitter_RevertsOnZeroAddress() public {
        vm.startPrank(admin);
        adaptor.pause();
        vm.expectRevert(BridgeAdaptor.InvalidAddress.selector);
        adaptor.setCircleTransmitter(address(0));
        vm.stopPrank();
    }

    /// @notice depositFromWormhole: inner payload shorter than abi.encode(bytes32, bytes) minimum.
    function test_DepositFromWormhole_RevertsOnShortInnerPayload() public {
        uint256 amount = 1000;
        // Build payload with empty innerPayload — length 0 < 96 byte floor.
        bytes memory payload = TokenBridgeMessageLib.encodeTransferWithPayload(
            amount,
            bytes32(uint256(uint160(address(testToken)))),
            WORMHOLE_CHAIN_ID_ETHEREUM,
            bytes32(uint256(uint160(address(adaptor)))),
            WORMHOLE_CHAIN_ID_ETHEREUM,
            bytes32(uint256(uint160(admin))),
            ""
        );
        bytes memory encodedVm = "short_inner";
        mockWormhole.setMockVAA(encodedVm, 1, SOLANA_EMITTER, 1, payload);
        mockTokenBridge.setTransfer(address(testToken), amount, address(adaptor));
        mockTokenBridge.setAutoTransfer(true);

        vm.expectRevert(BridgeAdaptor.InvalidPayloadLength.selector);
        adaptor.depositFromWormhole(encodedVm);
    }

    /// @notice settleOutOfLimitsWormhole: amount-0 path (fee >= amount when both are 0).
    function test_SettleOutOfLimitsWormhole_RevertsOnZeroFeeEqualsAmount() public {
        // Bridge will not deliver; balance delta = 0; amount=0 is below DEFAULT_MIN_LIMIT so
        // it passes the outside-limits check, then fee=0, fee >= amount, revert.
        bytes memory encodedVm = "settle_zero";
        primeWormholeNoDelivery(encodedVm, address(testToken), 0, MVX_RECIPIENT, "");
        vm.expectRevert(BridgeAdaptor.InsufficientAmountForFee.selector);
        adaptor.settleOutOfLimitsWormhole(encodedVm);
    }

    /// @notice settleOutOfLimitsCCTP: USDC not whitelisted on the Safe.
    function test_SettleOutOfLimitsCCTP_RevertsOnNonWhitelisted() public {
        // De-whitelist USDC so the settle path's whitelist guard fires.
        vm.prank(admin);
        safe.setWhitelisted(USDC_ADDRESS, false);

        uint256 amount = 50; // outside Safe limits (below min)
        bytes memory message = buildCCTPV2Message(MVX_RECIPIENT, "");
        mockCircleTransmitter.setMockAmount(amount);

        vm.expectRevert(abi.encodeWithSelector(BridgeAdaptor.TokenNotWhitelisted.selector, USDC_ADDRESS));
        adaptor.settleOutOfLimitsCCTP(message, "attestation");
    }

    /// @notice settleOutOfLimitsCCTP: amount tiny + flat fee large → fee >= amount revert.
    function test_SettleOutOfLimitsCCTP_RevertsOnFeeAboveAmount() public {
        uint256 amount = 50; // below min limit (outside) and below cctpFlatFee (1e6)
        bytes memory message = buildCCTPV2Message(MVX_RECIPIENT, "");
        mockCircleTransmitter.setMockAmount(amount);

        vm.expectRevert(BridgeAdaptor.InsufficientAmountForFee.selector);
        adaptor.settleOutOfLimitsCCTP(message, "attestation");
    }

    /// @notice rescueAndForwardCCTP: Safe paused → SafePaused revert.
    function test_RescueAndForwardCCTP_RevertsWhenSafePaused() public {
        MockERC20(USDC_ADDRESS).mint(address(adaptor), 5e6);
        safe.setPaused(true);
        vm.prank(admin);
        vm.expectRevert(BridgeAdaptor.SafePaused.selector);
        adaptor.rescueAndForwardCCTP(MVX_RECIPIENT, "", 5e6);
    }

    /// @notice _receiveCCTP: defensive `CircleCCTPNotConfigured` revert when the transmitter
    ///         storage slot is zero. Unreachable via setters (zero check rejects), so we use
    ///         vm.store to clear the address bytes of slot 5 while preserving flags + fees.
    function test_ReceiveCCTP_RevertsWhenTransmitterCleared() public {
        bytes32 slot5 = vm.load(address(adaptor), bytes32(uint256(5)));
        // Mask out the bottom 160 bits (the address); keep the upper 96 bits (flags + fees).
        bytes32 cleared = slot5 & bytes32(uint256(type(uint96).max) << 160);
        vm.store(address(adaptor), bytes32(uint256(5)), cleared);

        // Confirm the public getter now returns address(0).
        assertEq(address(adaptor.circleMessageTransmitter()), address(0));

        bytes memory message = buildCCTPV2Message(MVX_RECIPIENT, "");
        vm.expectRevert(BridgeAdaptor.CircleCCTPNotConfigured.selector);
        adaptor.depositFromCCTPV2(message, "attestation");
    }

    /// @notice Swap the Safe for one that pulls `netAmount - 1` and verify BridgeAdaptor reverts
    ///         with `UnexpectedSafePullDelta(expected, actual)` instead of silently losing dust.
    function test_DepositFromWormhole_RevertsOnSafeUnderPull() public {
        // Re-deploy the adaptor pointing at a misbehaving Safe (initialize is one-shot, so we
        // build a fresh proxy here).
        vm.startPrank(admin);
        MockUnderPullingSafe badSafe = new MockUnderPullingSafe(admin);
        badSafe.whitelistToken(address(testToken), DEFAULT_MIN_LIMIT, DEFAULT_MAX_LIMIT);

        BridgeAdaptor newImpl = new BridgeAdaptor();
        bytes memory initData = abi.encodeWithSelector(
            BridgeAdaptor.initialize.selector,
            address(badSafe),
            address(mockWormhole),
            address(mockTokenBridge),
            address(mockCircleTransmitter)
        );
        ERC1967Proxy badProxy = new ERC1967Proxy(address(newImpl), initData);
        BridgeAdaptor adaptorBad = BridgeAdaptor(address(badProxy));
        adaptorBad.unpause();
        vm.stopPrank();

        uint256 amount = 1000;
        bytes memory innerPayload = abi.encode(MVX_RECIPIENT, bytes(""));
        bytes memory payload = TokenBridgeMessageLib.encodeTransferWithPayload(
            amount,
            bytes32(uint256(uint160(address(testToken)))),
            WORMHOLE_CHAIN_ID_ETHEREUM,
            bytes32(uint256(uint160(address(adaptorBad)))),
            WORMHOLE_CHAIN_ID_ETHEREUM,
            bytes32(uint256(uint160(admin))),
            innerPayload
        );
        bytes memory encodedVm = "underpull_vaa";
        mockWormhole.setMockVAA(encodedVm, 1, SOLANA_EMITTER, 1, payload);
        mockTokenBridge.setTransfer(address(testToken), amount, address(adaptorBad));
        mockTokenBridge.setAutoTransfer(true);

        uint256 fee = (amount * 5) / 10_000;
        uint256 netAmount = amount - fee;
        // Mock pulls netAmount - 1, so adaptor's balance drops by netAmount - 1, not netAmount.
        vm.expectRevert(
            abi.encodeWithSelector(BridgeAdaptor.UnexpectedSafePullDelta.selector, netAmount, netAmount - 1)
        );
        adaptorBad.depositFromWormhole(encodedVm);
    }
}
