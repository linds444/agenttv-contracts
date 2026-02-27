// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {FlaunchZap} from "@flaunch/zaps/FlaunchZap.sol";
import {PositionManager} from "@flaunch/PositionManager.sol";

import {IFlaunch} from "@flaunch-interfaces/IFlaunch.sol";

/*
 * Same launch via @flaunch/sdk (npm i @flaunch/sdk):
 *
 *   import { createFlaunch, PoolCreatedEventData } from "@flaunch/sdk";
 *   import { createPublicClient, createWalletClient, http } from "viem";
 *   import { base } from "viem/chains";
 *   import { privateKeyToAccount } from "viem/accounts";
 *
 *   const publicClient = createPublicClient({ chain: base, transport: http() });
 *   const account = privateKeyToAccount(process.env.MOLTX_WALLET_PK);
 *   const walletClient = createWalletClient({ account, chain: base, transport: http() });
 *   const flaunchWrite = createFlaunch({ publicClient, walletClient });
 *   const flaunchRead  = createFlaunch({ publicClient });
 *
 *   const hash = await flaunchWrite.flaunchIPFS({
 *     name:                   "DIOGE",
 *     symbol:                 "DIOGE",
 *     fairLaunchPercent:      0,
 *     fairLaunchDuration:    3600,                    // 1 hour (same as script)
 *     initialMarketCapUSD:    10_000,                  // set to desired starting mcap; script uses 50M tokens
 *     creator:                account.address,
 *     creatorFeeAllocationPercent: 50,                  // 5000 bps = 50%
 *     metadata: {
 *       base64Image:          "<base64 image or data URL>", // from https://agenttv.live/dioge.jpg or tokenUri image
 *       description:          "The doge that gives zero f*cks. On Flaunch. 100 seats. 1 winner.",
 *       websiteUrl:           "https://takeover.fun",
 *     },
 *     treasuryManagerParams: { manager: AGENTTV_MANAGER_ADDRESS },
 *   });
 *
 *   const poolCreated = await flaunchRead.getPoolCreatedFromTx(hash);
 *   if (poolCreated) console.log("Memecoin:", poolCreated.memecoin);
 */

contract LaunchToken is Script {

    address payable constant FLAUNCH_ZAP = payable(0x39112541720078c70164EA4Deb61F0A4811910F9);
    address constant FLAUNCH = 0x516af52D0c629B5E378DA4DC64Ecb0744cE10109;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    address constant AGENTTV_MANAGER_ADDRESS = address(0);

    function run() external {
        uint256 pk     = vm.envUint("MOLTX_WALLET_PK");
        address wallet = vm.addr(pk);

        console.log("Launcher:", wallet);

        vm.startBroadcast(pk);

        (address memecoin,,) = FlaunchZap(FLAUNCH_ZAP).flaunch({
            _flaunchParams: PositionManager.FlaunchParams({
                name:                   "DIOGE",
                symbol:                 "DIOGE",
                tokenUri:               "data:application/json;base64,eyJuYW1lIjoiRElPR0UiLCJkZXNjcmlwdGlvbiI6IlRoZSBkb2dlIHRoYXQgZ2l2ZXMgemVybyBmKmNrcy4gT24gRmxhdW5jaC4gMTAwIHNlYXRzLiAxIHdpbm5lci4iLCJpbWFnZSI6Imh0dHBzOi8vYWdlbnR0di5saXZlL2Rpb2dlLmpwZyIsImV4dGVybmFsX3VybCI6Imh0dHBzOi8vdGFrZW92ZXIuZnVuIn0=",
                initialTokenFairLaunch: 50_000_000 ether,
                fairLaunchDuration:     3600,
                premineAmount:          0,
                creator:                wallet,
                creatorFeeAllocation:   5000,
                flaunchAt:              0,
                initialPriceParams:     "",
                feeCalculatorParams:    ""
            }),
            _trustedFeeSigner: address(0),
            _premineSwapHookData: "",
            _whitelistParams: FlaunchZap.WhitelistParams({
                merkleRoot: bytes32(0),
                merkleIPFSHash: "",
                maxTokens: 0
            }),
            _airdropParams: FlaunchZap.AirdropParams({
                airdropIndex: 0,
                airdropAmount: 0,
                airdropEndTime: 0,
                merkleRoot: bytes32(0),
                merkleIPFSHash: ""
            }),
            _treasuryManagerParams: FlaunchZap.TreasuryManagerParams({
                manager: AGENTTV_MANAGER_ADDRESS,
                permissions: address(0),
                initializeData: "",
                depositData: ""
            })
        });

        console.log("Memecoin:", memecoin);

        vm.stopBroadcast();
    }
}
