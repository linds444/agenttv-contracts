// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

interface IFlaunch {
    function tokenId(address memecoin) external view returns (uint256);
    function approve(address to, uint256 tokenId) external;
}

interface IFlaunchZap {
    struct FlaunchParams {
        string name;
        string symbol;
        string tokenUri;
        uint initialTokenFairLaunch;
        uint fairLaunchDuration;
        uint premineAmount;
        address creator;
        uint24 creatorFeeAllocation;
        uint flaunchAt;
        bytes initialPriceParams;
        bytes feeCalculatorParams;
    }
    struct PoolSwapParams {
        bytes32 poolId;
        string tokenUri;
        uint referralCode;
    }
    struct ManagerParams {
        uint referralCode;
        uint ownerShare;
        uint protocolShare;
        bytes32 inviteCode;
        string inviteUri;
    }
    struct TreasuryManagerParams {
        address managerImplementation;
        address managerOwner;
        bytes initData;
        bytes postInitData;
    }
    function flaunch(
        FlaunchParams calldata _params,
        address _referrer,
        bytes calldata _swapData,
        PoolSwapParams calldata _poolSwapParams,
        ManagerParams calldata _managerParams,
        TreasuryManagerParams calldata _treasuryManagerParams
    ) external payable returns (address memecoin_, uint tokenId_);
}

interface IImportZap {
    struct SeatAcquireParams {
        uint256 seatId;
        uint256 price;
        uint256 amount;
    }
    function importWithSeats(
        address _flaunch,
        uint256 _tokenId,
        SeatAcquireParams[] calldata _seats
    ) external;
}

contract LaunchDioge is Script {
    address constant FLAUNCH_ZAP     = 0xe52dE1801C10cF709cc8e62d43D783AFe984b510;
    address constant IMPORT_ZAP      = 0x3d5EadF1585dC98eD306C81214574F75a99e8290;
    address constant FLAUNCH         = 0x516af52D0c629B5E378DA4DC64Ecb0744cE10109;
    address constant TAKEOVER_MGR    = 0x22c738cA7b87933949dedf66DC0D51F3F52f1bd6;
    address constant USDC            = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    function run() external {
        uint256 pk     = vm.envUint("MOLTX_WALLET_PK");
        address wallet = vm.addr(pk);
        console.log("Launcher:", wallet);

        vm.startBroadcast(pk);

        // ── Step 1: Launch DIOGE via FlaunchZap with TakeoverFeeSplitManager ──
        bytes memory initialPriceParams = abi.encode(uint256(1_000_000_000));

        (address memecoin,) = IFlaunchZap(FLAUNCH_ZAP).flaunch(
            IFlaunchZap.FlaunchParams({
                name:                   "DIOGE",
                symbol:                 "DIOGE",
                tokenUri:               "data:application/json;base64,eyJuYW1lIjoiRElPR0UiLCJkZXNjcmlwdGlvbiI6IlRoZSBkb2dlIHRoYXQgZ2l2ZXMgemVybyBmKmNrcy4gT24gRmxhdW5jaC4gMTAwIHNlYXRzLiAxIHdpbm5lci4iLCJpbWFnZSI6Imh0dHBzOi8vYWdlbnR0di5saXZlL2Rpb2dlLmpwZyIsImV4dGVybmFsX3VybCI6Imh0dHBzOi8vdGFrZW92ZXIuZnVuIn0=",
                initialTokenFairLaunch: 50_000_000 ether,
                fairLaunchDuration:     3600,
                premineAmount:          0,
                creator:                wallet,
                creatorFeeAllocation:   5000,
                flaunchAt:              0,
                initialPriceParams:     initialPriceParams,
                feeCalculatorParams:    ""
            }),
            address(0),
            "",
            IFlaunchZap.PoolSwapParams({ poolId: bytes32(0), tokenUri: "", referralCode: 0 }),
            IFlaunchZap.ManagerParams({ referralCode: 0, ownerShare: 0, protocolShare: 0, inviteCode: bytes32(0), inviteUri: "" }),
            IFlaunchZap.TreasuryManagerParams({
                managerImplementation: address(0),
                managerOwner:          address(0),
                initData:              "",
                postInitData:          ""
            })
        );
        // Read real tokenId from Flaunch contract
        uint tokenId = IFlaunch(FLAUNCH).tokenId(memecoin);
        console.log("DIOGE memecoin:", memecoin);
        console.log("DIOGE tokenId:", tokenId);

        // ── Step 2: Approve ImportZap to transfer the Flaunch NFT + USDC ──
        IFlaunch(FLAUNCH).approve(IMPORT_ZAP, tokenId);
        uint256 totalUSDC = 20 * 100_000; // $2.00
        IERC20(USDC).approve(IMPORT_ZAP, totalUSDC);

        IImportZap.SeatAcquireParams[] memory seats = new IImportZap.SeatAcquireParams[](20);
        for (uint i = 0; i < 20; i++) {
            seats[i] = IImportZap.SeatAcquireParams({
                seatId: i,
                price:  1_000_000,  // $1 USDC
                amount: 100_000     // $0.10 USDC deposit
            });
        }

        IImportZap(IMPORT_ZAP).importWithSeats(FLAUNCH, tokenId, seats);
        console.log("20 seats claimed!");

        vm.stopBroadcast();
    }
}
