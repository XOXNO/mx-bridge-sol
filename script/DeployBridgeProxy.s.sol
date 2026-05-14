// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.35;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "../contracts/BridgeAdaptor.sol";

/// @notice One-shot proxy deployer used to recover from a partial OZ Upgrades deploy.
/// @dev Reads the already-deployed implementation from env (`IMPL_ADDRESS`) and constructs a
///      `TransparentUpgradeableProxy(impl, initialOwner=ADMIN, data=initialize(...))`. The proxy's
///      constructor internally creates a `ProxyAdmin` owned by `ADMIN` (OZ v5 contract behaviour).
///      Run with: `forge script script/DeployBridgeProxy.s.sol --rpc-url $MAINNET_RPC_URL
///      --ledger --sender 0xb741... --broadcast --gas-price 1gwei`.
contract DeployBridgeProxy is Script {
    // Mainnet constants — must mirror setup.config.json.
    address constant SAFE = 0xC3c144d86c8840FD405acd637A548E850C636138;
    address constant WORMHOLE_CORE = 0x98f3c9e6E3fAce36bAAd05FE09d375Ef1464288B;
    address constant WORMHOLE_TOKEN_BRIDGE = 0x3ee18B2214AFF97000D974cf647E7C347E8fa585;
    address constant CIRCLE_MT_V2 = 0x81D40F21F12A8F0E3252Bccb954D722d4c464B64;
    address constant ADMIN = 0xb741a35956AA2365c767734a5Ad6b8b60a41F8DD;

    function run() external {
        address impl = vm.envAddress("IMPL_ADDRESS");
        require(impl.code.length > 0, "IMPL_ADDRESS has no code");

        bytes memory initData = abi.encodeWithSelector(
            BridgeAdaptor.initialize.selector, SAFE, WORMHOLE_CORE, WORMHOLE_TOKEN_BRIDGE, CIRCLE_MT_V2
        );

        vm.startBroadcast();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(impl, ADMIN, initData);
        vm.stopBroadcast();

        console.log("BridgeAdaptor proxy deployed to:", address(proxy));
    }
}
