// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.35;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../../contracts/BridgeAdaptor.sol";
import "../../contracts/interfaces/IERC20Safe.sol";
import {IUSDC, UsdcDealer} from "wormhole-sdk/testing/UsdcDealer.sol";

/// @notice Mainnet-fork integration tests for BridgeAdaptor.
///
/// Skipped automatically when MAINNET_RPC_URL isn't set (pure unit-test runs).
///
/// Coverage focus:
///   - Real ERC20Safe acceptance of our deposits via rescueAndForwardCCTP
///   - Real USDC safeTransfer (via OZ SafeERC20) end-to-end
///   - Real Circle V2 MessageTransmitter ABI compatibility
///   - Real address resolution (Wormhole core/token-bridge, Circle MT, Safe, USDC)
///
/// Out-of-scope (deferred):
///   - Full signed-message E2E for Wormhole VAA / CCTP V2 attestation. Wormhole-SDK's
///     overrides target CCTP V1 message layout and our contract enforces V2; building
///     V2 messages by hand is brittle. Add when Circle ships official V2 test helpers.
contract BridgeAdaptorForkTest is Test {
    using UsdcDealer for IUSDC;

    // Live mainnet addresses (must mirror setup.config.json).
    address constant ERC20_SAFE = 0xC3c144d86c8840FD405acd637A548E850C636138;
    address constant WORMHOLE_CORE = 0x98f3c9e6E3fAce36bAAd05FE09d375Ef1464288B;
    address constant WORMHOLE_TOKEN_BRIDGE = 0x3ee18B2214AFF97000D974cf647E7C347E8fa585;
    address constant CIRCLE_MT_V2 = 0x81D40F21F12A8F0E3252Bccb954D722d4c464B64;
    address constant USDC_ADDRESS = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // CCTP V2 message offsets (must match BridgeAdaptor constants).
    uint256 constant CCTP_V2_HOOK_DATA_OFFSET = 376;
    uint256 constant MIN_ABI_ENCODED_HOOK_DATA = 96;

    BridgeAdaptor adaptor;
    address admin;

    bytes32 constant MVX_RECIPIENT =
        bytes32(uint256(0xc0f0058cea88a2bc1240b60361efb965957038d05f916c42b3f23a2c38ced81e));

    /// @dev Fork is created on first use; if MAINNET_RPC_URL is empty, every test reverts in
    ///      `setUp` with a clear message and the suite is effectively no-op locally without it.
    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            // Mark every test as skipped via a known-skip pattern. Foundry doesn't have native
            // skip; throwing here makes intent unambiguous and prevents accidental green runs
            // against zero state.
            vm.skip(true);
            return;
        }
        // Pin to a recent finalized block for determinism. Bump every few months.
        vm.createSelectFork(rpc, 22_500_000);

        admin = makeAddr("fork-admin");

        vm.startPrank(admin);
        BridgeAdaptor impl = new BridgeAdaptor();
        bytes memory initData = abi.encodeWithSelector(
            BridgeAdaptor.initialize.selector, ERC20_SAFE, WORMHOLE_CORE, WORMHOLE_TOKEN_BRIDGE, CIRCLE_MT_V2
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        adaptor = BridgeAdaptor(address(proxy));
        adaptor.unpause();
        vm.stopPrank();
    }

    /// @notice Sanity: the proxy initialized with real-mainnet refs and admin matches.
    function test_Fork_RealAddresses() public view {
        assertEq(adaptor.getSafe(), ERC20_SAFE);
        assertEq(address(adaptor.wormhole()), WORMHOLE_CORE);
        assertEq(address(adaptor.wormholeTokenBridge()), WORMHOLE_TOKEN_BRIDGE);
        assertEq(address(adaptor.circleMessageTransmitter()), CIRCLE_MT_V2);
        assertEq(adaptor.admin(), admin);
        assertTrue(adaptor.wormholeEnabled());
        assertTrue(adaptor.cctpEnabled());
        assertFalse(adaptor.paused());
    }

    /// @notice End-to-end with the real USDC contract: deal in, recover out.
    function test_Fork_RecoverTokens_RealUSDC() public {
        IUSDC usdc = IUSDC(USDC_ADDRESS);
        uint256 amount = 100e6; // 100 USDC

        usdc.deal(address(adaptor), amount);
        assertEq(usdc.balanceOf(address(adaptor)), amount);

        uint256 adminBefore = usdc.balanceOf(admin);
        vm.prank(admin);
        adaptor.recoverTokens(USDC_ADDRESS, 0); // sweep all

        assertEq(usdc.balanceOf(address(adaptor)), 0);
        assertEq(usdc.balanceOf(admin), adminBefore + amount);
    }

    /// @notice Forward stranded USDC into the REAL ERC20Safe via rescueAndForwardCCTP.
    ///         Tests the most consequential trust boundary: that our adaptor correctly calls
    ///         `safe.deposit(token, amount, recipient)` and the real Safe accepts it.
    function test_Fork_RescueAndForwardCCTP_RealSafe() public {
        // Skip gracefully if the live Safe doesn't whitelist USDC at the pinned block — that
        // would be an ops finding, not a contract bug.
        if (!IERC20Safe(ERC20_SAFE).whitelistedTokens(USDC_ADDRESS)) {
            vm.skip(true);
            return;
        }

        // Arrange: deal USDC to adaptor as if a direct CCTP receiveMessage stranded it.
        // Amount must exceed cctpFlatFee (1 USDC) AND clear the live Safe's tokenMinLimit
        // for USDC (currently 40 USDC at the pinned block).
        IUSDC usdc = IUSDC(USDC_ADDRESS);
        uint256 amount = 100e6; // 100 USDC
        usdc.deal(address(adaptor), amount);

        // Record Safe USDC balance before so we can assert the pull.
        uint256 safeBefore = usdc.balanceOf(ERC20_SAFE);

        // Act: admin rescues + forwards.
        vm.prank(admin);
        adaptor.rescueAndForwardCCTP(MVX_RECIPIENT, "", amount);

        // Assert: real Safe pulled exactly netAmount = amount - cctpFlatFee.
        uint64 fee = adaptor.cctpFlatFee();
        uint256 netAmount = amount - fee;
        assertEq(usdc.balanceOf(ERC20_SAFE), safeBefore + netAmount);
        // Fee remains in adaptor (recoverable separately).
        assertEq(usdc.balanceOf(address(adaptor)), fee);
    }

    /// @notice Real Circle V2 MessageTransmitter is the call target. We verify the version
    ///         guard fires BEFORE the real transmitter is dispatched (cheap fail-fast path).
    function test_Fork_DepositFromCCTPV2_RevertsOnWrongVersion() public {
        // Build a CCTP V2 message with WRONG version byte (= 0).
        bytes memory msg_ = new bytes(CCTP_V2_HOOK_DATA_OFFSET + MIN_ABI_ENCODED_HOOK_DATA);
        // version=0 (V1), should fail our V2 check at version=1.
        // (no need to set anything — bytes default to zero)
        bytes memory hookData = abi.encode(MVX_RECIPIENT, bytes(""));
        bytes memory full = abi.encodePacked(msg_, hookData);

        vm.expectRevert(abi.encodeWithSelector(BridgeAdaptor.InvalidCCTPVersion.selector, uint32(1), uint32(0)));
        adaptor.depositFromCCTPV2(full, "attestation");
    }

    /// @notice Live Safe has a non-zero admin. If our adaptor ever needs to bypass and read it,
    ///         this confirms the real Safe still exposes `admin()` per IERC20Safe.
    function test_Fork_LiveSafe_AdminIsNonZero() public view {
        address liveAdmin = IERC20Safe(ERC20_SAFE).admin();
        assertTrue(liveAdmin != address(0));
    }
}
