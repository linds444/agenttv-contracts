// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {AgentTVManager} from "../src/AgentTVManager.sol";

/**
 * @notice Deploy AgentTVManager to Base mainnet.
 *
 * Usage:
 *   source /root/.openclaw/workspace/.env
 *   forge script script/Deploy.s.sol \
 *     --rpc-url https://mainnet.base.org \
 *     --private-key $MOLTX_WALLET_PK \
 *     --broadcast -vvv
 */
contract DeployAgentTVManager is Script {

    // Base mainnet addresses (verified on-chain)
    address constant TREASURY_MANAGER_FACTORY = 0x48af8b28DDC5e5A86c4906212fc35Fa808CA8763;
    address constant FEE_ESCROW_REGISTRY       = 0xFA140FFFf60E1DEfDDbccB85A4772bcE5A22a3D6;
    address constant USDC                      = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    function run() external {
        uint256 deployerKey = vm.envUint("MOLTX_WALLET_PK");
        address deployer    = vm.addr(deployerKey);

        console.log("Deployer:      ", deployer);
        console.log("ETH balance:   ", deployer.balance);

        vm.startBroadcast(deployerKey);

        AgentTVManager manager = new AgentTVManager(
            TREASURY_MANAGER_FACTORY,
            FEE_ESCROW_REGISTRY,
            USDC
        );

        vm.stopBroadcast();

        console.log("AgentTVManager deployed at:", address(manager));
        console.log("");
        console.log("Next steps:");
        console.log("  1. Register as implementation: TreasuryManagerFactory.addImplementation(address)");
        console.log("  2. Launch a coin via FlaunchZap with this manager as treasury");
        console.log("  3. Users can then snapshotBalance(), buyConvictionSlot(), lockTokens()");
    }
}
