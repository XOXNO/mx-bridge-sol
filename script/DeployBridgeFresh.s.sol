// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.35;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "../contracts/BridgeAdaptor.sol";

/// @notice Fresh BridgeAdaptor deploy: implementation + transparent proxy + initialize.
/// @dev Replaces the OZ Upgrades plugin path because hardhat-ledger + ethers v6 reject
///      contract-create receipts (`to: ""`). Uses forge's native --ledger flag.
///      Run: `forge script script/DeployBridgeFresh.s.sol --rpc-url $MAINNET_RPC_URL
///      --ledger --sender 0xb741... --hd-paths "m/44'/60'/0'/0/0" --broadcast --gas-price 1gwei`.
contract DeployBridgeFresh is Script {
    // Mainnet constants — must mirror setup.config.json.
    address constant SAFE = 0xC3c144d86c8840FD405acd637A548E850C636138;
    address constant WORMHOLE_CORE = 0x98f3c9e6E3fAce36bAAd05FE09d375Ef1464288B;
    address constant WORMHOLE_TOKEN_BRIDGE = 0x3ee18B2214AFF97000D974cf647E7C347E8fa585;
    address constant CIRCLE_MT_V2 = 0x81D40F21F12A8F0E3252Bccb954D722d4c464B64;
    address constant ADMIN = 0xb741a35956AA2365c767734a5Ad6b8b60a41F8DD;

    function run() external {
        bytes memory initData = abi.encodeWithSelector(
            BridgeAdaptor.initialize.selector, SAFE, WORMHOLE_CORE, WORMHOLE_TOKEN_BRIDGE, CIRCLE_MT_V2
        );

        vm.startBroadcast();
        BridgeAdaptor impl = new BridgeAdaptor();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(address(impl), ADMIN, initData);
        vm.stopBroadcast();

        console.log("BridgeAdaptor implementation: ", address(impl));
        console.log("BridgeAdaptor proxy:          ", address(proxy));
    }
}
