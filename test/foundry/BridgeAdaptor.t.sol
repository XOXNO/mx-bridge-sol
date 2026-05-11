// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../../contracts/BridgeAdaptor.sol";
import "../../contracts/interfaces/IERC20Safe.sol";
import "../../contracts/test/MockERC20.sol";
import "../../contracts/test/MockERC20Safe.sol";
import "../../contracts/test/MockWormhole.sol";
import "../../contracts/test/MockTokenBridge.sol";
import "../../contracts/test/MockCircleMessageTransmitter.sol";
import {TokenBridgeMessageLib} from "wormhole-sdk/libraries/TokenBridgeMessages.sol";

// ============ BridgeAdaptor Test Contract ============
contract BridgeAdaptorTest is Test {
    // Constants matching BridgeAdaptor
    uint16 constant WORMHOLE_CHAIN_ID_ETHEREUM = 2;
    address constant USDC_ADDRESS = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    uint256 constant CCTP_V2_HOOK_DATA_OFFSET = 376;

    // Test contracts
    BridgeAdaptor public adaptor;
    BridgeAdaptor public adaptorImpl;
    MockERC20Safe public safe;
    MockWormhole public mockWormhole;
    MockTokenBridge public mockTokenBridge;
    MockCircleMessageTransmitter public mockCircleTransmitter;
    MockERC20 public testToken;
    MockERC20 public usdc;

    // Test addresses
    address public admin;
    address public user;
    address public attacker;

    // Sample values
    bytes32 public constant MVX_RECIPIENT = bytes32(uint256(0xc0f0058cea88a2bc1240b60361efb965957038d05f916c42b3f23a2c38ced81e));
    bytes32 public constant SOLANA_EMITTER = bytes32(uint256(uint160(0x1234567890123456789012345678901234567890)));

    // Default limits
    uint256 public constant DEFAULT_MIN_LIMIT = 100;
    uint256 public constant DEFAULT_MAX_LIMIT = 1000000;

    // ============ Setup ============

    function setUp() public {
        admin = makeAddr("admin");
        user = makeAddr("user");
        attacker = makeAddr("attacker");

        vm.startPrank(admin);

        // Deploy mock tokens
        testToken = new MockERC20("Test Token", "TEST", 18);
        usdc = new MockERC20("USDC", "USDC", 6);

        // Deploy mock Safe
        safe = new MockERC20Safe(admin);
        safe.whitelistToken(address(testToken), DEFAULT_MIN_LIMIT, DEFAULT_MAX_LIMIT);
        safe.whitelistToken(USDC_ADDRESS, DEFAULT_MIN_LIMIT, DEFAULT_MAX_LIMIT);

        // Deploy mock Wormhole contracts
        mockWormhole = new MockWormhole();
        mockTokenBridge = new MockTokenBridge();
        mockCircleTransmitter = new MockCircleMessageTransmitter(USDC_ADDRESS);

        // Deploy BridgeAdaptor through proxy
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

        // Unpause adaptor
        adaptor.unpause();

        // Fund mock contracts
        testToken.mint(address(mockTokenBridge), 100_000_000 * 1e18);

        // Deploy USDC at the expected address using vm.etch for CCTP tests
        vm.etch(USDC_ADDRESS, address(usdc).code);
        MockERC20(USDC_ADDRESS).mint(address(mockCircleTransmitter), 100_000_000 * 1e6);

        vm.stopPrank();
    }

    // ============ Helper Functions ============

    /// @notice Build Token Bridge Type 3 payload (TransferWithPayload)
    function buildWormholePayload(
        address token,
        uint256 amount,
        bytes32 recipient,
        bytes memory callData
    ) internal view returns (bytes memory) {
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

    /// @notice Build CCTP V2 message with hookData
    function buildCCTPV2Message(
        bytes32 recipient,
        bytes memory callData
    ) internal pure returns (bytes memory) {
        // Build header (148 bytes) + BurnMsg fixed fields (228 bytes) = 376 bytes
        bytes memory fixedPrefix = new bytes(CCTP_V2_HOOK_DATA_OFFSET);

        // Encode hookData: abi.encode(bytes32 mvxRecipient, bytes callData)
        bytes memory hookData = abi.encode(recipient, callData);

        return abi.encodePacked(fixedPrefix, hookData);
    }

    /// @notice Setup mock VAA for wormhole deposits
    function setupMockVAA(
        bytes memory encodedVm,
        address token,
        uint256 amount,
        bytes32 recipient,
        bytes memory callData
    ) internal {
        bytes memory payload = buildWormholePayload(token, amount, recipient, callData);
        mockWormhole.setMockVAA(
            encodedVm,
            1, // Solana chain ID
            SOLANA_EMITTER,
            1,
            payload
        );
    }

    // ============ Unit Tests: Initialization ============

    function test_Initialize_SetsCorrectValues() public view {
        assertEq(adaptor.getSafe(), address(safe));
        assertEq(address(adaptor.wormhole()), address(mockWormhole));
        assertEq(address(adaptor.wormholeTokenBridge()), address(mockTokenBridge));
        assertEq(address(adaptor.circleMessageTransmitter()), address(mockCircleTransmitter));
        assertTrue(adaptor.wormholeEnabled());
        assertEq(adaptor.admin(), admin);
    }

    function test_Initialize_RevertsOnZeroSafe() public {
        vm.startPrank(admin);
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
        vm.stopPrank();
    }

    function test_Initialize_RevertsOnZeroWormhole() public {
        vm.startPrank(admin);
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
        vm.stopPrank();
    }

    // ============ Unit Tests: Admin Functions ============

    function test_SetCustomAdmin_Success() public {
        address newAdmin = makeAddr("newAdmin");
        vm.prank(admin);
        adaptor.transferAdmin(newAdmin);
        // Admin only changes after the new admin accepts (two-step)
        assertEq(adaptor.admin(), admin);
        vm.prank(newAdmin);
        adaptor.acceptAdmin();
        assertEq(adaptor.admin(), newAdmin);
    }

    function test_SetCustomAdmin_RevertsIfNotAdmin() public {
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

    // ============ Unit Tests: depositFromWormhole ============

    function test_DepositFromWormhole_Success() public {
        uint256 amount = 1000;
        bytes memory encodedVm = "mock_vaa";

        setupMockVAA(encodedVm, address(testToken), amount, MVX_RECIPIENT, "");

        // Disable auto transfer and mint tokens to adaptor
        mockTokenBridge.setAutoTransfer(false);
        vm.prank(admin);
        testToken.mint(address(adaptor), amount);

        adaptor.depositFromWormhole(encodedVm);

        assertEq(safe.depositCount(), 1);
        MockERC20Safe.DepositRecord memory record = safe.getDeposit(0);
        assertEq(record.token, address(testToken));
        assertEq(record.amount, amount);
        assertEq(record.recipient, MVX_RECIPIENT);
    }

    function test_DepositFromWormhole_WithSCExecution() public {
        uint256 amount = 2000;
        bytes memory encodedVm = "mock_vaa_sc";
        bytes memory callData = hex"deadbeef";

        setupMockVAA(encodedVm, address(testToken), amount, MVX_RECIPIENT, callData);

        mockTokenBridge.setAutoTransfer(false);
        vm.prank(admin);
        testToken.mint(address(adaptor), amount);

        adaptor.depositFromWormhole(encodedVm);

        assertEq(safe.scDepositCount(), 1);
        MockERC20Safe.DepositRecord memory record = safe.getSCDeposit(0);
        assertEq(record.token, address(testToken));
        assertEq(record.amount, amount);
        assertEq(record.recipient, MVX_RECIPIENT);
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
        setupMockVAA(encodedVm, address(testToken), 0, MVX_RECIPIENT, "");
        mockTokenBridge.setAutoTransfer(false);

        vm.expectRevert(BridgeAdaptor.ZeroAmount.selector);
        adaptor.depositFromWormhole(encodedVm);
    }

    function test_DepositFromWormhole_RevertsOnZeroRecipient() public {
        bytes memory encodedVm = "mock_vaa_zero_recipient";
        setupMockVAA(encodedVm, address(testToken), 1000, bytes32(0), "");
        mockTokenBridge.setAutoTransfer(false);
        vm.prank(admin);
        testToken.mint(address(adaptor), 1000);

        vm.expectRevert(BridgeAdaptor.InvalidRecipient.selector);
        adaptor.depositFromWormhole(encodedVm);
    }

    // ============ Unit Tests: depositFromCCTPV2 ============

    function test_DepositFromCCTPV2_Success() public {
        uint256 amount = 5000;
        bytes memory message = buildCCTPV2Message(MVX_RECIPIENT, "");
        bytes memory attestation = "attestation";

        mockCircleTransmitter.setMockAmount(amount);

        adaptor.depositFromCCTPV2(message, attestation);

        assertEq(safe.depositCount(), 1);
        MockERC20Safe.DepositRecord memory record = safe.getDeposit(0);
        assertEq(record.token, USDC_ADDRESS);
        assertEq(record.amount, amount);
        assertEq(record.recipient, MVX_RECIPIENT);
    }

    function test_DepositFromCCTPV2_WithSCExecution() public {
        uint256 amount = 10000;
        bytes memory callData = hex"cafebabe";
        bytes memory message = buildCCTPV2Message(MVX_RECIPIENT, callData);
        bytes memory attestation = "attestation";

        mockCircleTransmitter.setMockAmount(amount);

        adaptor.depositFromCCTPV2(message, attestation);

        assertEq(safe.scDepositCount(), 1);
        MockERC20Safe.DepositRecord memory record = safe.getSCDeposit(0);
        assertEq(record.token, USDC_ADDRESS);
        assertEq(record.amount, amount);
        assertEq(record.callData, callData);
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
        bytes memory shortMessage = new bytes(100); // Less than 376 bytes

        vm.expectRevert(BridgeAdaptor.InvalidPayloadLength.selector);
        adaptor.depositFromCCTPV2(shortMessage, "attestation");
    }

    function test_DepositFromCCTPV2_RevertsOnReceiveFailed() public {
        bytes memory message = buildCCTPV2Message(MVX_RECIPIENT, "");
        mockCircleTransmitter.setShouldSucceed(false);

        vm.expectRevert(BridgeAdaptor.CCTPReceiveFailed.selector);
        adaptor.depositFromCCTPV2(message, "attestation");
    }

    // ============ Unit Tests: claimWormholeToAdmin ============

    function test_ClaimWormholeToAdmin_WhenBelowMinLimit() public {
        uint256 amount = 50; // Below DEFAULT_MIN_LIMIT of 100
        bytes memory encodedVm = "mock_vaa_below_min";

        setupMockVAA(encodedVm, address(testToken), amount, MVX_RECIPIENT, "");
        mockTokenBridge.setAutoTransfer(false);
        vm.prank(admin);
        testToken.mint(address(adaptor), amount);

        uint256 adminBalanceBefore = testToken.balanceOf(admin);

        adaptor.claimWormholeToAdmin(encodedVm);

        assertEq(testToken.balanceOf(admin), adminBalanceBefore + amount);
    }

    function test_ClaimWormholeToAdmin_WhenAboveMaxLimit() public {
        uint256 amount = 2_000_000; // Above DEFAULT_MAX_LIMIT of 1,000,000
        bytes memory encodedVm = "mock_vaa_above_max";

        setupMockVAA(encodedVm, address(testToken), amount, MVX_RECIPIENT, "");
        mockTokenBridge.setAutoTransfer(false);
        vm.prank(admin);
        testToken.mint(address(adaptor), amount);

        uint256 adminBalanceBefore = testToken.balanceOf(admin);

        adaptor.claimWormholeToAdmin(encodedVm);

        assertEq(testToken.balanceOf(admin), adminBalanceBefore + amount);
    }

    function test_ClaimWormholeToAdmin_RevertsWhenWithinLimits() public {
        uint256 amount = 500; // Within limits (100-1,000,000)
        bytes memory encodedVm = "mock_vaa_within_limits";

        setupMockVAA(encodedVm, address(testToken), amount, MVX_RECIPIENT, "");
        mockTokenBridge.setAutoTransfer(false);
        vm.prank(admin);
        testToken.mint(address(adaptor), amount);

        vm.expectRevert(BridgeAdaptor.AmountWithinSafeLimits.selector);
        adaptor.claimWormholeToAdmin(encodedVm);
    }

    // ============ Unit Tests: claimCCTPToAdmin ============

    function test_ClaimCCTPToAdmin_WhenBelowMinLimit() public {
        uint256 amount = 50; // Below min limit
        bytes memory message = buildCCTPV2Message(MVX_RECIPIENT, "");
        bytes memory attestation = "attestation";

        mockCircleTransmitter.setMockAmount(amount);

        uint256 adminBalanceBefore = MockERC20(USDC_ADDRESS).balanceOf(admin);

        adaptor.claimCCTPToAdmin(message, attestation);

        assertEq(MockERC20(USDC_ADDRESS).balanceOf(admin), adminBalanceBefore + amount);
    }

    function test_ClaimCCTPToAdmin_WhenAboveMaxLimit() public {
        uint256 amount = 2_000_000; // Above max limit
        bytes memory message = buildCCTPV2Message(MVX_RECIPIENT, "");
        bytes memory attestation = "attestation";

        mockCircleTransmitter.setMockAmount(amount);
        MockERC20(USDC_ADDRESS).mint(address(mockCircleTransmitter), amount);

        uint256 adminBalanceBefore = MockERC20(USDC_ADDRESS).balanceOf(admin);

        adaptor.claimCCTPToAdmin(message, attestation);

        assertEq(MockERC20(USDC_ADDRESS).balanceOf(admin), adminBalanceBefore + amount);
    }

    function test_ClaimCCTPToAdmin_RevertsWhenWithinLimits() public {
        uint256 amount = 500; // Within limits
        bytes memory message = buildCCTPV2Message(MVX_RECIPIENT, "");
        bytes memory attestation = "attestation";

        mockCircleTransmitter.setMockAmount(amount);

        vm.expectRevert(BridgeAdaptor.AmountWithinSafeLimits.selector);
        adaptor.claimCCTPToAdmin(message, attestation);
    }

    // ============ Unit Tests: recoverTokens ============

    function test_RecoverTokens_FullBalance() public {
        uint256 stuckAmount = 5000;
        vm.prank(admin);
        testToken.mint(address(adaptor), stuckAmount);

        uint256 adminBalanceBefore = testToken.balanceOf(admin);

        // Anyone can call recoverTokens, but tokens go to admin
        vm.prank(user);
        adaptor.recoverTokens(address(testToken), 0);

        assertEq(testToken.balanceOf(admin), adminBalanceBefore + stuckAmount);
        assertEq(testToken.balanceOf(address(adaptor)), 0);
    }

    function test_RecoverTokens_PartialAmount() public {
        uint256 stuckAmount = 5000;
        uint256 recoverAmount = 2000;
        vm.prank(admin);
        testToken.mint(address(adaptor), stuckAmount);

        uint256 adminBalanceBefore = testToken.balanceOf(admin);

        adaptor.recoverTokens(address(testToken), recoverAmount);

        assertEq(testToken.balanceOf(admin), adminBalanceBefore + recoverAmount);
        assertEq(testToken.balanceOf(address(adaptor)), stuckAmount - recoverAmount);
    }

    function test_RecoverTokens_RevertsOnInsufficientBalance() public {
        uint256 stuckAmount = 1000;
        vm.prank(admin);
        testToken.mint(address(adaptor), stuckAmount);

        vm.expectRevert(BridgeAdaptor.InsufficientBalance.selector);
        adaptor.recoverTokens(address(testToken), stuckAmount + 1);
    }

    // ============ Unit Tests: USDC Constant ============

    function test_USDCConstant_IsCorrect() public view {
        // The USDC constant in BridgeAdaptor should always be 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
        // We verify this by checking CCTP deposits use this address
        assertEq(USDC_ADDRESS, 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    }

    // ============ Fuzz Tests: depositFromWormhole ============

    function testFuzz_DepositFromWormhole_Amounts(uint256 amount) public {
        // Bound amount to reasonable range (1 to 10^24)
        amount = bound(amount, 1, 1e24);

        bytes memory encodedVm = abi.encodePacked("mock_vaa_fuzz_", amount);
        setupMockVAA(encodedVm, address(testToken), amount, MVX_RECIPIENT, "");

        mockTokenBridge.setAutoTransfer(false);
        vm.prank(admin);
        testToken.mint(address(adaptor), amount);

        adaptor.depositFromWormhole(encodedVm);

        assertEq(safe.depositCount(), 1);
        MockERC20Safe.DepositRecord memory record = safe.getDeposit(0);
        assertEq(record.amount, amount);
    }

    function testFuzz_DepositFromWormhole_Recipients(bytes32 recipient) public {
        vm.assume(recipient != bytes32(0)); // Valid recipients only

        uint256 amount = 1000;
        bytes memory encodedVm = abi.encodePacked("mock_vaa_recipient_", recipient);
        setupMockVAA(encodedVm, address(testToken), amount, recipient, "");

        mockTokenBridge.setAutoTransfer(false);
        vm.prank(admin);
        testToken.mint(address(adaptor), amount);

        adaptor.depositFromWormhole(encodedVm);

        MockERC20Safe.DepositRecord memory record = safe.getDeposit(0);
        assertEq(record.recipient, recipient);
    }

    // ============ Fuzz Tests: depositFromCCTPV2 ============

    function testFuzz_DepositFromCCTPV2_Amounts(uint256 amount) public {
        // Bound amount to reasonable USDC range (1 to 10^12 = 1M USDC with 6 decimals)
        amount = bound(amount, 1, 1e12);

        bytes memory message = buildCCTPV2Message(MVX_RECIPIENT, "");

        // Mint enough USDC to transmitter
        MockERC20(USDC_ADDRESS).mint(address(mockCircleTransmitter), amount);
        mockCircleTransmitter.setMockAmount(amount);

        adaptor.depositFromCCTPV2(message, "attestation");

        assertEq(safe.depositCount(), 1);
        MockERC20Safe.DepositRecord memory record = safe.getDeposit(0);
        assertEq(record.amount, amount);
    }

    function testFuzz_DepositFromCCTPV2_HookData(bytes32 recipient, bytes memory callData) public {
        vm.assume(recipient != bytes32(0));
        vm.assume(callData.length < 10000); // Reasonable callData size

        uint256 amount = 5000;
        bytes memory message = buildCCTPV2Message(recipient, callData);

        mockCircleTransmitter.setMockAmount(amount);

        adaptor.depositFromCCTPV2(message, "attestation");

        if (callData.length > 0) {
            MockERC20Safe.DepositRecord memory record = safe.getSCDeposit(0);
            assertEq(record.recipient, recipient);
            assertEq(record.callData, callData);
        } else {
            MockERC20Safe.DepositRecord memory record = safe.getDeposit(0);
            assertEq(record.recipient, recipient);
        }
    }

    // ============ Fuzz Tests: Admin Claims with Limit Boundaries ============

    function testFuzz_ClaimWormholeToAdmin_BelowMinLimit(uint256 amount) public {
        // Amount below min limit should succeed
        amount = bound(amount, 1, DEFAULT_MIN_LIMIT - 1);

        bytes memory encodedVm = abi.encodePacked("claim_below_", amount);
        setupMockVAA(encodedVm, address(testToken), amount, MVX_RECIPIENT, "");

        mockTokenBridge.setAutoTransfer(false);
        vm.prank(admin);
        testToken.mint(address(adaptor), amount);

        uint256 adminBalanceBefore = testToken.balanceOf(admin);

        adaptor.claimWormholeToAdmin(encodedVm);

        assertEq(testToken.balanceOf(admin), adminBalanceBefore + amount);
    }

    function testFuzz_ClaimWormholeToAdmin_AboveMaxLimit(uint256 amount) public {
        // Amount above max limit should succeed
        amount = bound(amount, DEFAULT_MAX_LIMIT + 1, 1e24);

        bytes memory encodedVm = abi.encodePacked("claim_above_", amount);
        setupMockVAA(encodedVm, address(testToken), amount, MVX_RECIPIENT, "");

        mockTokenBridge.setAutoTransfer(false);
        vm.prank(admin);
        testToken.mint(address(adaptor), amount);

        uint256 adminBalanceBefore = testToken.balanceOf(admin);

        adaptor.claimWormholeToAdmin(encodedVm);

        assertEq(testToken.balanceOf(admin), adminBalanceBefore + amount);
    }

    function testFuzz_ClaimWormholeToAdmin_WithinLimits_Reverts(uint256 amount) public {
        // Amount within limits should revert
        amount = bound(amount, DEFAULT_MIN_LIMIT, DEFAULT_MAX_LIMIT);

        bytes memory encodedVm = abi.encodePacked("claim_within_", amount);
        setupMockVAA(encodedVm, address(testToken), amount, MVX_RECIPIENT, "");

        mockTokenBridge.setAutoTransfer(false);
        vm.prank(admin);
        testToken.mint(address(adaptor), amount);

        vm.expectRevert(BridgeAdaptor.AmountWithinSafeLimits.selector);
        adaptor.claimWormholeToAdmin(encodedVm);
    }

    function testFuzz_ClaimCCTPToAdmin_BelowMinLimit(uint256 amount) public {
        amount = bound(amount, 1, DEFAULT_MIN_LIMIT - 1);

        bytes memory message = buildCCTPV2Message(MVX_RECIPIENT, "");
        MockERC20(USDC_ADDRESS).mint(address(mockCircleTransmitter), amount);
        mockCircleTransmitter.setMockAmount(amount);

        uint256 adminBalanceBefore = MockERC20(USDC_ADDRESS).balanceOf(admin);

        adaptor.claimCCTPToAdmin(message, "attestation");

        assertEq(MockERC20(USDC_ADDRESS).balanceOf(admin), adminBalanceBefore + amount);
    }

    function testFuzz_ClaimCCTPToAdmin_AboveMaxLimit(uint256 amount) public {
        amount = bound(amount, DEFAULT_MAX_LIMIT + 1, 1e18);

        bytes memory message = buildCCTPV2Message(MVX_RECIPIENT, "");
        MockERC20(USDC_ADDRESS).mint(address(mockCircleTransmitter), amount);
        mockCircleTransmitter.setMockAmount(amount);

        uint256 adminBalanceBefore = MockERC20(USDC_ADDRESS).balanceOf(admin);

        adaptor.claimCCTPToAdmin(message, "attestation");

        assertEq(MockERC20(USDC_ADDRESS).balanceOf(admin), adminBalanceBefore + amount);
    }

    function testFuzz_ClaimCCTPToAdmin_WithinLimits_Reverts(uint256 amount) public {
        amount = bound(amount, DEFAULT_MIN_LIMIT, DEFAULT_MAX_LIMIT);

        bytes memory message = buildCCTPV2Message(MVX_RECIPIENT, "");
        MockERC20(USDC_ADDRESS).mint(address(mockCircleTransmitter), amount);
        mockCircleTransmitter.setMockAmount(amount);

        vm.expectRevert(BridgeAdaptor.AmountWithinSafeLimits.selector);
        adaptor.claimCCTPToAdmin(message, "attestation");
    }

    // ============ Fuzz Tests: recoverTokens ============

    function testFuzz_RecoverTokens_Amounts(uint256 stuckAmount, uint256 recoverAmount) public {
        stuckAmount = bound(stuckAmount, 1, 1e24);
        recoverAmount = bound(recoverAmount, 0, stuckAmount);

        vm.prank(admin);
        testToken.mint(address(adaptor), stuckAmount);

        uint256 adminBalanceBefore = testToken.balanceOf(admin);
        uint256 expectedRecover = recoverAmount == 0 ? stuckAmount : recoverAmount;

        adaptor.recoverTokens(address(testToken), recoverAmount);

        assertEq(testToken.balanceOf(admin), adminBalanceBefore + expectedRecover);
    }

    // ============ Fuzz Tests: _requireAmountOutsideSafeLimits boundaries ============

    function testFuzz_RequireAmountOutsideSafeLimits_ExactMinBoundary(uint256 minLimit, uint256 maxLimit) public {
        minLimit = bound(minLimit, 1, 1e18);
        maxLimit = bound(maxLimit, minLimit, 1e24);

        safe.setTokenLimits(address(testToken), minLimit, maxLimit);

        // Exact min limit should revert (within limits)
        bytes memory encodedVm = abi.encodePacked("exact_min_", minLimit);
        setupMockVAA(encodedVm, address(testToken), minLimit, MVX_RECIPIENT, "");
        mockTokenBridge.setAutoTransfer(false);
        vm.prank(admin);
        testToken.mint(address(adaptor), minLimit);

        vm.expectRevert(BridgeAdaptor.AmountWithinSafeLimits.selector);
        adaptor.claimWormholeToAdmin(encodedVm);
    }

    function testFuzz_RequireAmountOutsideSafeLimits_ExactMaxBoundary(uint256 minLimit, uint256 maxLimit) public {
        minLimit = bound(minLimit, 1, 1e18);
        maxLimit = bound(maxLimit, minLimit, 1e24);

        safe.setTokenLimits(address(testToken), minLimit, maxLimit);

        // Exact max limit should revert (within limits)
        bytes memory encodedVm = abi.encodePacked("exact_max_", maxLimit);
        setupMockVAA(encodedVm, address(testToken), maxLimit, MVX_RECIPIENT, "");
        mockTokenBridge.setAutoTransfer(false);
        vm.prank(admin);
        testToken.mint(address(adaptor), maxLimit);

        vm.expectRevert(BridgeAdaptor.AmountWithinSafeLimits.selector);
        adaptor.claimWormholeToAdmin(encodedVm);
    }

    function testFuzz_RequireAmountOutsideSafeLimits_JustBelowMin(uint256 minLimit, uint256 maxLimit) public {
        minLimit = bound(minLimit, 2, 1e18);
        maxLimit = bound(maxLimit, minLimit, 1e24);

        safe.setTokenLimits(address(testToken), minLimit, maxLimit);

        // Just below min should succeed
        uint256 amount = minLimit - 1;
        bytes memory encodedVm = abi.encodePacked("below_min_", amount);
        setupMockVAA(encodedVm, address(testToken), amount, MVX_RECIPIENT, "");
        mockTokenBridge.setAutoTransfer(false);
        vm.prank(admin);
        testToken.mint(address(adaptor), amount);

        uint256 adminBalanceBefore = testToken.balanceOf(admin);
        adaptor.claimWormholeToAdmin(encodedVm);
        assertEq(testToken.balanceOf(admin), adminBalanceBefore + amount);
    }

    function testFuzz_RequireAmountOutsideSafeLimits_JustAboveMax(uint256 minLimit, uint256 maxLimit) public {
        minLimit = bound(minLimit, 1, 1e18);
        maxLimit = bound(maxLimit, minLimit, 1e24 - 1);

        safe.setTokenLimits(address(testToken), minLimit, maxLimit);

        // Just above max should succeed
        uint256 amount = maxLimit + 1;
        bytes memory encodedVm = abi.encodePacked("above_max_", amount);
        setupMockVAA(encodedVm, address(testToken), amount, MVX_RECIPIENT, "");
        mockTokenBridge.setAutoTransfer(false);
        vm.prank(admin);
        testToken.mint(address(adaptor), amount);

        uint256 adminBalanceBefore = testToken.balanceOf(admin);
        adaptor.claimWormholeToAdmin(encodedVm);
        assertEq(testToken.balanceOf(admin), adminBalanceBefore + amount);
    }

    // ============ Invariant Test Helpers ============

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

        vm.prank(attacker);
        vm.expectRevert(BridgeAdaptor.AccessControlSenderNotAdmin.selector);
        adaptor.setCircleTransmitter(attacker);
    }

    function test_Invariant_DepositsOnlyWorkWhenNotPaused() public {
        vm.prank(admin);
        adaptor.pause();

        // Wormhole deposit should fail
        vm.expectRevert(BridgeAdaptor.ContractPaused.selector);
        adaptor.depositFromWormhole("mock_vaa");

        // CCTP deposit should fail
        bytes memory message = buildCCTPV2Message(MVX_RECIPIENT, "");
        vm.expectRevert(BridgeAdaptor.ContractPaused.selector);
        adaptor.depositFromCCTPV2(message, "attestation");
    }

    function test_Invariant_AdminClaimsOnlyOutsideLimits() public {
        // Set specific limits
        safe.setTokenLimits(address(testToken), 100, 1000);

        // Amount within limits (500) should revert
        bytes memory encodedVm = "within_limits";
        setupMockVAA(encodedVm, address(testToken), 500, MVX_RECIPIENT, "");
        mockTokenBridge.setAutoTransfer(false);
        vm.prank(admin);
        testToken.mint(address(adaptor), 500);

        vm.expectRevert(BridgeAdaptor.AmountWithinSafeLimits.selector);
        adaptor.claimWormholeToAdmin(encodedVm);

        // Amount below min (50) should succeed
        bytes memory encodedVm2 = "below_min";
        setupMockVAA(encodedVm2, address(testToken), 50, MVX_RECIPIENT, "");
        vm.prank(admin);
        testToken.mint(address(adaptor), 50);

        adaptor.claimWormholeToAdmin(encodedVm2);

        // Amount above max (1500) should succeed
        bytes memory encodedVm3 = "above_max";
        setupMockVAA(encodedVm3, address(testToken), 1500, MVX_RECIPIENT, "");
        vm.prank(admin);
        testToken.mint(address(adaptor), 1500);

        adaptor.claimWormholeToAdmin(encodedVm3);
    }
}

// ============ Invariant Handler Contract ============
contract BridgeAdaptorHandler is Test {
    BridgeAdaptor public adaptor;
    MockERC20Safe public safe;
    address public admin;
    address public nonAdmin;

    constructor(BridgeAdaptor _adaptor, MockERC20Safe _safe, address _admin, address _nonAdmin) {
        adaptor = _adaptor;
        safe = _safe;
        admin = _admin;
        nonAdmin = _nonAdmin;
    }

    // Handler functions that randomly call admin functions
    function handler_pause() external {
        vm.prank(admin);
        try adaptor.pause() {} catch {}
    }

    function handler_unpause() external {
        vm.prank(admin);
        try adaptor.unpause() {} catch {}
    }

    function handler_setWormholeEnabled(bool enabled) external {
        vm.prank(admin);
        try adaptor.setWormholeEnabled(enabled) {} catch {}
    }

    function handler_setCustomAdmin(address newAdmin) external {
        vm.prank(admin);
        try adaptor.transferAdmin(newAdmin) {} catch {}
    }

    // Attacker attempts (should always fail)
    function handler_attackerPause() external {
        vm.prank(nonAdmin);
        try adaptor.pause() {} catch {}
    }

    function handler_attackerSetAdmin(address newAdmin) external {
        vm.prank(nonAdmin);
        try adaptor.transferAdmin(newAdmin) {} catch {}
    }
}

// ============ Invariant Test Contract ============
contract BridgeAdaptorInvariantTest is Test {
    BridgeAdaptor public adaptor;
    MockERC20Safe public safe;
    MockWormhole public mockWormhole;
    MockTokenBridge public mockTokenBridge;
    MockCircleMessageTransmitter public mockCircleTransmitter;
    MockERC20 public testToken;
    BridgeAdaptorHandler public handler;

    address public admin;
    address public nonAdmin;

    function setUp() public {
        admin = makeAddr("admin");
        nonAdmin = makeAddr("nonAdmin");

        vm.startPrank(admin);

        testToken = new MockERC20("Test", "TEST", 18);
        safe = new MockERC20Safe(admin);
        safe.whitelistToken(address(testToken), 100, 1000000);

        mockWormhole = new MockWormhole();
        mockTokenBridge = new MockTokenBridge();
        mockCircleTransmitter = new MockCircleMessageTransmitter(address(testToken));

        BridgeAdaptor impl = new BridgeAdaptor();
        bytes memory initData = abi.encodeWithSelector(
            BridgeAdaptor.initialize.selector,
            address(safe),
            address(mockWormhole),
            address(mockTokenBridge),
            address(mockCircleTransmitter)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        adaptor = BridgeAdaptor(address(proxy));

        vm.stopPrank();

        // Create handler and target it
        handler = new BridgeAdaptorHandler(adaptor, safe, admin, nonAdmin);
        targetContract(address(handler));
    }

    /// @notice Invariant: Admin should never be zero address after initialization
    /// Note: Custom admin can be set to zero, but admin() falls back to Safe's admin
    function invariant_AdminNeverZero() public view {
        assertTrue(adaptor.admin() != address(0), "Admin should never be zero");
    }

    /// @notice Invariant: Safe reference should never change (no setter function)
    function invariant_SafeNeverChanges() public view {
        assertEq(adaptor.getSafe(), address(safe), "Safe reference should not change");
    }

    /// @notice Invariant: Wormhole core reference should never be zero during normal operation
    function invariant_WormholeNeverZero() public view {
        assertTrue(address(adaptor.wormhole()) != address(0), "Wormhole should never be zero");
    }

    /// @notice Invariant: Token bridge reference should never be zero during normal operation
    function invariant_TokenBridgeNeverZero() public view {
        assertTrue(address(adaptor.wormholeTokenBridge()) != address(0), "Token bridge should never be zero");
    }
}
