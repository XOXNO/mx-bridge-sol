import { readFileSync } from "node:fs";

import { task } from "hardhat/config";

import { getDeployOptions } from "../args/deployOptions.js";

export default task("adaptor-recover-tokens", "Recover stuck tokens from BridgeAdaptor to admin")
  .addOption({ name: "token", description: "Token address to recover", defaultValue: "" })
  .addOption({ name: "amount", description: "Amount to recover (0 = full balance)", defaultValue: "0" })
  .addOption({
    name: "configfile",
    description: "Config file path",
    defaultValue: "setup.config.json",
  })
  .addOption({ name: "price", description: "Gas price in gwei", defaultValue: "" })
  .setInlineAction(async (args, hre) => {
    if (!args.token) throw new Error("--token is required");
    const connection = await hre.network.connect();

    const cfg = JSON.parse(readFileSync(args.configfile, "utf8")) as { bridgeAdaptor?: string };
    const adaptorAddress = cfg.bridgeAdaptor;
    if (!adaptorAddress) {
      throw new Error(`BridgeAdaptor address not found in ${args.configfile}`);
    }

    const [signer] = await connection.ethers.getSigners();
    console.log("Signer:", await signer.getAddress());

    const adaptor = await connection.ethers.getContractAt("BridgeAdaptor", adaptorAddress, signer);
    const adminAddress = (await adaptor.admin()) as string;
    console.log("Contract admin:", adminAddress);

    const token = await connection.ethers.getContractAt("IERC20", args.token);
    const adaptorBalance = (await token.balanceOf(adaptorAddress)) as bigint;
    const adminBalanceBefore = (await token.balanceOf(adminAddress)) as bigint;

    console.log("Adaptor balance:", connection.ethers.formatUnits(adaptorBalance, 6));
    console.log("Admin balance before:", connection.ethers.formatUnits(adminBalanceBefore, 6));

    const amountToRecover = args.amount === "0" ? adaptorBalance : BigInt(args.amount);
    console.log("Amount to recover:", connection.ethers.formatUnits(amountToRecover, 6));

    const tx = await adaptor.recoverTokens(args.token, amountToRecover, {
      gasLimit: 100_000n,
      ...getDeployOptions(args),
    });
    console.log("Transaction hash:", tx.hash);

    const receipt = await tx.wait();
    console.log("Confirmed in block:", receipt?.blockNumber);

    const adminBalanceAfter = (await token.balanceOf(adminAddress)) as bigint;
    console.log("Admin balance after:", connection.ethers.formatUnits(adminBalanceAfter, 6));
    console.log("Tokens recovered:", connection.ethers.formatUnits(adminBalanceAfter - adminBalanceBefore, 6));
  })
  .build();
