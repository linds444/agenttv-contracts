// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title AgentTVManager
 * @author Alfred & Linds
 * @notice A novel Flaunch TreasuryManager combining five fee mechanics:
 *
 *   📈 VOLUME SEATS   (40%) — Hold the token, snapshot your balance weekly, earn proportionally.
 *                             Diamond Vault holders get a multiplier on their snapshot weight.
 *   💎 DIAMOND VAULTS (10%) — Lock tokens 30/60/90 days → 1.5x/1.75x/2x multiplier on seat weight.
 *   🎯 CONVICTION POOL(25%) — 50 competitive slots. Enter for $1 USDC, keep depositing to hold
 *                             your lead. First to deposit $50 in a slot locks it permanently.
 *                             Below $40 = anyone can outbid you. At $50 = yours forever.
 *   🔄 WEEKLY AUCTION  (5%) — Each epoch's pot goes to the highest ETH bidder. Bid wars = fun.
 *   👑 OWNER          (20%) — Immediate allocation, claimable anytime.
 *   💼 PLATFORM        (1%) — Off the top of all trades and deposits → platform owner wallet.
 *
 * @dev Extends TreasuryManager from flayerlabs/flaunchgg-contracts.
 *      Requires: @flaunch, @flaunch-interfaces, @openzeppelin, @solady
 */

import {ReentrancyGuard} from "@solady/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {TreasuryManager} from "@flaunch/treasury/managers/TreasuryManager.sol";

contract AgentTVManager is TreasuryManager, ReentrancyGuard {

    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────
    //  CONSTANTS
    // ─────────────────────────────────────────────────

    uint256 public constant EPOCH_DURATION    = 7 days;
    uint256 public constant AUCTION_WINDOW    = 24 hours;

    /// Platform fee — 1% of all incoming ETH fees and USDC deposits → platformOwner
    uint256 public constant PLATFORM_BPS      = 100;   // 1% (basis points, /10_000)
    uint256 public constant BPS_DENOM         = 10_000;

    /// Fee shares (5 decimal precision — 100_00000 = 100%)
    uint256 public constant TOTAL_SHARES      = 100_00000;
    uint256 public constant OWNER_SHARE       = 20_00000;  // 20%
    uint256 public constant HOLDER_SHARE      = 40_00000;  // 40%
    uint256 public constant VAULT_BOOST_SHARE = 10_00000;  // 10%
    uint256 public constant CONVICTION_SHARE  = 25_00000;  // 25%
    uint256 public constant AUCTION_SHARE     =  5_00000;  //  5%

    /// Conviction pool — competitive deposit model
    uint256 public constant MAX_CONVICTION_SLOTS = 50;
    uint256 public constant SLOT_MIN_DEPOSIT     = 1e6;   // $1 USDC minimum entry
    uint256 public constant SLOT_LOCK_PRICE      = 50e6;  // $50 USDC → permanent lock
    uint256 public constant SLOT_SAFE_THRESHOLD  = 40e6;  // below $40 = can be outbid

    /// Diamond vault multipliers (basis points: 10_000 = 1x)
    uint256 public constant VAULT_30D_BP = 15_000;  // 1.5x
    uint256 public constant VAULT_60D_BP = 17_500;  // 1.75x
    uint256 public constant VAULT_90D_BP = 20_000;  // 2x

    uint256 public constant LOCK_30D = 30 days;
    uint256 public constant LOCK_60D = 60 days;
    uint256 public constant LOCK_90D = 90 days;

    // ─────────────────────────────────────────────────
    //  ERRORS
    // ─────────────────────────────────────────────────

    error AuctionAlreadySettled();
    error AuctionNotStarted();
    error AuctionStillActive();
    error AuctionWindowClosed();
    error BidTooLow();
    error DepositTooSmall();
    error EpochNotOver();
    error FlaunchContractNotSupported();
    error InvalidLockDuration();
    error NoVaultFound();
    error SlotAlreadyLocked();
    error SlotIdInvalid();
    error TokenNotDeposited();
    error UnableToSendETH(bytes reason);
    error VaultStillLocked();
    error ZeroAmount();

    // ─────────────────────────────────────────────────
    //  EVENTS
    // ─────────────────────────────────────────────────

    event EpochAdvanced(uint256 indexed epochId, uint256 holderFees, uint256 vaultFees, uint256 auctionPot);
    event BalanceSnapshotted(address indexed user, uint256 indexed epochId, uint256 weight);
    event HolderFeesClaimed(address indexed user, uint256 indexed epochId, uint256 amount);
    event VaultLocked(address indexed user, uint256 amount, uint256 unlockTime, uint256 multiplierBP);
    event VaultUnlocked(address indexed user, uint256 amount);
    event SlotDeposited(address indexed user, uint256 indexed slotId, uint256 amount, uint256 userTotal);
    event SlotLeaderChanged(uint256 indexed slotId, address indexed newLeader, uint256 amount);
    event SlotLocked(address indexed owner, uint256 indexed slotId);
    event ConvictionFeesClaimed(address indexed user, uint256 amount);
    event AuctionBid(address indexed bidder, uint256 indexed epochId, uint256 amount);
    event AuctionSettled(address indexed winner, uint256 indexed epochId, uint256 pot);
    event OwnerFeesClaimed(uint256 amount);
    event PlatformFeePaid(address indexed to, uint256 ethAmount);

    // ─────────────────────────────────────────────────
    //  STRUCTS
    // ─────────────────────────────────────────────────

    struct Epoch {
        uint256 holderFees;
        uint256 vaultFees;
        uint256 auctionPot;
        uint256 totalWeight;
        uint256 auctionEnd;
        address highestBidder;
        uint256 highestBid;
        bool    settled;
    }

    struct UserEpochData {
        uint256 weight;
        uint256 claimedHolder;
        uint256 claimedVault;
    }

    struct VaultEntry {
        uint256 amount;
        uint256 unlockTime;
        uint256 multiplierBP;
    }

    // ─────────────────────────────────────────────────
    //  STATE
    // ─────────────────────────────────────────────────

    address public memecoin;
    address public immutable usdc;
    
    /// @dev Hardcoded platform wallet — receives 1% of all trades & deposits, immutable forever
    address public constant platformOwner = 0x6946Ee4dE034c554EFAb9Ca19CBA358368Aa7Eb7;

    /// @dev Hardcoded Flaunch v1.0 contract address
    address public constant FLAUNCH_V1_0 = 0x6A53F8b799bE11a2A3264eF0bfF183dCB12d9571;

    // — Epoch tracking —
    uint256 public currentEpoch;
    uint256 public epochStart;
    mapping(uint256 => Epoch) public epochs;
    mapping(address => mapping(uint256 => UserEpochData)) public userEpochs;

    // — Owner fees —
    uint256 public ownerFeesAccrued;
    uint256 public ownerFeesClaimed;

    // — Conviction pool (competitive deposit model) —
    // Each slot: multiple depositors compete. First to $50 locks permanently.
    // Below $40 = anyone can outbid. At $50 = yours forever.
    mapping(uint256 => mapping(address => uint256))  public slotDeposits;   // slotId → depositor → amount
    mapping(uint256 => address)                      public slotLeader;     // slotId → current leader
    mapping(uint256 => uint256)                      public slotLeaderAmt;  // slotId → leader's total
    mapping(uint256 => bool)                         public slotLocked;     // slotId → permanently locked
    mapping(uint256 => address)                      public slotLockedBy;   // slotId → permanent owner
    mapping(uint256 => uint256)                      public slotTotalDeposits; // slotId → sum of all deposits
    uint256 public totalConvictionEth;                                      // lifetime ETH allocated
    mapping(address => uint256) public convictionClaimed;                   // ETH already claimed per address

    // — Diamond vaults —
    mapping(address => VaultEntry) public vaults;

    // ─────────────────────────────────────────────────
    //  CONSTRUCTOR
    // ─────────────────────────────────────────────────

    constructor(
        address _treasuryManagerFactory,
        address _feeEscrowRegistry,
        address _usdc
    ) TreasuryManager(_treasuryManagerFactory, _feeEscrowRegistry) {
        usdc = _usdc;
    }

    // ─────────────────────────────────────────────────
    //  INITIALIZATION
    // ─────────────────────────────────────────────────

    function _initialize(address /*_owner*/, bytes calldata /*_data*/) internal override {
        currentEpoch = 1;
        epochStart   = block.timestamp;
    }

    // ─────────────────────────────────────────────────
    //  DEPOSIT  (called when Flaunch NFT is deposited)
    // ─────────────────────────────────────────────────

    function _deposit(
        FlaunchToken calldata _flaunchToken,
        address /*_creator*/,
        bytes calldata /*_data*/
    ) internal override {
        // Ensure that the `FlaunchToken` is not from Flaunch 1.0 as this would not provide compatibility with the manager
        if (address(_flaunchToken.flaunch) == FLAUNCH_V1_0) {
            revert FlaunchContractNotSupported();
        }
        
        memecoin = address(_flaunchToken.flaunch.memecoin(_flaunchToken.tokenId));
    }

    // ─────────────────────────────────────────────────
    //  FEE RECEIPT
    // ─────────────────────────────────────────────────

    receive() external override payable {
        if (msg.value == 0) return;

        // 1% platform fee off the top → platformOwner wallet
        uint256 platformCut = (msg.value * PLATFORM_BPS) / BPS_DENOM;
        uint256 remainder   = msg.value - platformCut;
        if (platformCut > 0) {
            _sendETH(platformOwner, platformCut);
            emit PlatformFeePaid(platformOwner, platformCut);
        }

        // Split remaining 99% among the 5 mechanics
        uint256 ownerCut   = (remainder * OWNER_SHARE)       / TOTAL_SHARES;
        uint256 holderCut  = (remainder * HOLDER_SHARE)      / TOTAL_SHARES;
        uint256 vaultCut   = (remainder * VAULT_BOOST_SHARE) / TOTAL_SHARES;
        uint256 convCut    = (remainder * CONVICTION_SHARE)  / TOTAL_SHARES;
        uint256 auctCut    = remainder - ownerCut - holderCut - vaultCut - convCut;

        ownerFeesAccrued   += ownerCut;
        totalConvictionEth += convCut;

        Epoch storage ep = epochs[currentEpoch];
        ep.holderFees += holderCut;
        ep.vaultFees  += vaultCut;
        ep.auctionPot += auctCut;
    }

    // ─────────────────────────────────────────────────
    //  EPOCH MANAGEMENT
    // ─────────────────────────────────────────────────

    function advanceEpoch() external {
        if (block.timestamp < epochStart + EPOCH_DURATION) revert EpochNotOver();

        Epoch storage ep = epochs[currentEpoch];
        if (ep.auctionPot > 0 && ep.auctionEnd == 0) {
            ep.auctionEnd = block.timestamp + AUCTION_WINDOW;
        }

        emit EpochAdvanced(currentEpoch, ep.holderFees, ep.vaultFees, ep.auctionPot);
        unchecked { currentEpoch++; }
        epochStart = block.timestamp;
    }

    // ─────────────────────────────────────────────────
    //  📈 VOLUME SEATS
    // ─────────────────────────────────────────────────

    /// @custom:audit An attacker can steal a disproportionate share of ETH allocated to holders/vault rewards (up to the majority of
    /// `HOLDER_SHARE + VAULT_BOOST_SHARE` for an epoch) without maintaining real economic exposure, directly causing loss of funds to
    /// legitimate claimants.
    /// Base rewards on time-weighted balances or enforce snapshot timing that cannot be manipulated with transient balances (e.g.,
    /// take snapshots automatically at epoch end from a trusted oracle/snapshot mechanism, use a TWAB/averaging model, or require
    /// tokens be held/locked across the epoch to be eligible).
    function snapshotBalance() external {
        if (memecoin == address(0)) revert TokenNotDeposited();

        /// @custom:audit Vault deposits transfer tokens into the contract, but snapshots and weight computation only consider balanceOf(user)
        /// in the ERC20, so locked tokens do not contribute to (and usually reduce) the user's weight, causing the vault fee pool to be
        /// distributed to non-vault holders instead of vault participants.
        /// Include vault-held balances in snapshot weight computation (e.g., snapshot balanceOf(user) + vaults[user].amount and apply the
        /// multiplier to the vault amount). Alternatively, mint a non-transferable receipt token representing locked position and base
        /// rewards on that, or keep locked tokens in a separate staking/vault contract whose balances are explicitly included in weight
        /// snapshots.
        uint256 rawBalance = IERC20(memecoin).balanceOf(msg.sender);
        uint256 weight     = _computeWeight(msg.sender, rawBalance);

        UserEpochData storage ud = userEpochs[msg.sender][currentEpoch];
        if (weight <= ud.weight) return;

        Epoch storage ep = epochs[currentEpoch];
        ep.totalWeight = ep.totalWeight - ud.weight + weight;
        ud.weight = weight;

        emit BalanceSnapshotted(msg.sender, currentEpoch, weight);
    }

    function claimHolderFees(uint256 _epochId) external nonReentrant returns (uint256 amount_) {
        if (_epochId >= currentEpoch) revert EpochNotOver();

        UserEpochData storage ud = userEpochs[msg.sender][_epochId];
        Epoch         storage ep = epochs[_epochId];

        if (ud.weight == 0 || ep.totalWeight == 0) return 0;

        uint256 holderAlloc = (ep.holderFees * ud.weight) / ep.totalWeight;
        uint256 vaultAlloc  = (ep.vaultFees  * ud.weight) / ep.totalWeight;
        uint256 unclaimed   = (holderAlloc - ud.claimedHolder) + (vaultAlloc - ud.claimedVault);
        if (unclaimed == 0) return 0;

        ud.claimedHolder = holderAlloc;
        ud.claimedVault  = vaultAlloc;
        amount_ = unclaimed;

        _sendETH(msg.sender, amount_);
        emit HolderFeesClaimed(msg.sender, _epochId, amount_);
    }

    // ─────────────────────────────────────────────────
    //  💎 DIAMOND VAULTS
    // ─────────────────────────────────────────────────

    function lockTokens(uint256 _amount, uint256 _duration) external nonReentrant {
        if (_amount == 0) revert ZeroAmount();
        if (_duration != LOCK_30D && _duration != LOCK_60D && _duration != LOCK_90D) {
            revert InvalidLockDuration();
        }

        uint256 multiplierBP;
        if      (_duration == LOCK_30D) multiplierBP = VAULT_30D_BP;
        else if (_duration == LOCK_60D) multiplierBP = VAULT_60D_BP;
        else                            multiplierBP = VAULT_90D_BP;

        VaultEntry storage v = vaults[msg.sender];
        if (v.amount > 0 && multiplierBP < v.multiplierBP) multiplierBP = v.multiplierBP;

        IERC20(memecoin).safeTransferFrom(msg.sender, address(this), _amount);

        v.amount      += _amount;
        v.unlockTime   = block.timestamp + _duration;
        v.multiplierBP = multiplierBP;

        emit VaultLocked(msg.sender, v.amount, v.unlockTime, v.multiplierBP);
    }

    function unlockTokens() external nonReentrant {
        VaultEntry storage v = vaults[msg.sender];
        if (v.amount == 0)                  revert NoVaultFound();
        if (block.timestamp < v.unlockTime) revert VaultStillLocked();

        uint256 amount = v.amount;
        delete vaults[msg.sender];

        IERC20(memecoin).safeTransfer(msg.sender, amount);
        emit VaultUnlocked(msg.sender, amount);
    }

    // ─────────────────────────────────────────────────
    //  🎯 CONVICTION POOL — competitive deposit model
    // ─────────────────────────────────────────────────

    /**
     * @notice Deposit USDC into a conviction slot to compete for it.
     *
     *   Rules:
     *   - Any slot accepts $1 USDC minimum.
     *   - Your deposit accumulates. First to reach $50 total in a slot locks it permanently.
     *   - Once locked, no one else can deposit into that slot.
     *   - Below $40 personal total: anyone can deposit more than you and take the lead.
     *   - Fee share: locked slot owner gets full slot share.
     *                Unlocked slots split fees proportional to each depositor's total.
     *
     * @param _slotId  Which slot to deposit into (0–49)
     * @param _amount  USDC amount (6 decimals, minimum 1e6)
     */
    function depositIntoSlot(uint256 _slotId, uint256 _amount) external nonReentrant {
        if (_slotId >= MAX_CONVICTION_SLOTS) revert SlotIdInvalid();
        if (slotLocked[_slotId])             revert SlotAlreadyLocked();
        if (_amount < SLOT_MIN_DEPOSIT)      revert DepositTooSmall();

        // 1% platform fee on USDC deposit → platformOwner
        uint256 platformCut = (_amount * PLATFORM_BPS) / BPS_DENOM;
        uint256 ownerCut    = _amount - platformCut;

        IERC20(usdc).safeTransferFrom(msg.sender, platformOwner, platformCut);
        IERC20(usdc).safeTransferFrom(msg.sender, managerOwner,  ownerCut);

        slotDeposits[_slotId][msg.sender]   += _amount;
        slotTotalDeposits[_slotId]          += _amount;

        uint256 myTotal = slotDeposits[_slotId][msg.sender];

        // Check for permanent lock
        if (myTotal >= SLOT_LOCK_PRICE) {
            slotLocked[_slotId]   = true;
            slotLockedBy[_slotId] = msg.sender;
            slotLeader[_slotId]   = msg.sender;
            slotLeaderAmt[_slotId]= myTotal;
            emit SlotLocked(msg.sender, _slotId);
        } else if (myTotal > slotLeaderAmt[_slotId]) {
            slotLeader[_slotId]    = msg.sender;
            slotLeaderAmt[_slotId] = myTotal;
            emit SlotLeaderChanged(_slotId, msg.sender, myTotal);
        }

        emit SlotDeposited(msg.sender, _slotId, _amount, myTotal);
    }

    /**
     * @notice Claim accumulated ETH from the conviction pool.
     *
     *   Earnings per user:
     *   - For each locked slot they own → (1 / MAX_CONVICTION_SLOTS) × totalConvictionEth
     *   - For each unlocked slot they've deposited into →
     *       (their deposit / slot total deposits) × (1 / MAX_CONVICTION_SLOTS) × totalConvictionEth
     */
    function claimConvictionFees() external nonReentrant returns (uint256 amount_) {
        _withdrawAllFees(address(this), true);
        amount_ = _pendingConviction(msg.sender);
        if (amount_ == 0) return 0;

        convictionClaimed[msg.sender] += amount_;
        _sendETH(msg.sender, amount_);
        emit ConvictionFeesClaimed(msg.sender, amount_);
    }

    // ─────────────────────────────────────────────────
    //  🔄 WEEKLY AUCTION
    // ─────────────────────────────────────────────────

    function bid(uint256 _epochId) external payable nonReentrant {
        if (msg.value == 0) revert ZeroAmount();

        Epoch storage ep = epochs[_epochId];
        if (ep.auctionEnd == 0)              revert AuctionNotStarted();
        if (block.timestamp > ep.auctionEnd) revert AuctionWindowClosed();
        if (msg.value <= ep.highestBid)      revert BidTooLow();

        if (ep.highestBidder != address(0)) {
            _sendETH(ep.highestBidder, ep.highestBid);
        }

        ep.highestBidder = msg.sender;
        ep.highestBid    = msg.value;

        emit AuctionBid(msg.sender, _epochId, msg.value);
    }

    function settleAuction(uint256 _epochId) external nonReentrant {
        Epoch storage ep = epochs[_epochId];
        if (ep.auctionEnd == 0)              revert AuctionNotStarted();
        if (ep.settled)                       revert AuctionAlreadySettled();
        if (block.timestamp <= ep.auctionEnd) revert AuctionStillActive();

        ep.settled = true;

        if (ep.highestBidder != address(0)) {
            ownerFeesAccrued += ep.highestBid;
            _sendETH(ep.highestBidder, ep.auctionPot);
            emit AuctionSettled(ep.highestBidder, _epochId, ep.auctionPot);
        } else {
            ownerFeesAccrued += ep.auctionPot;
            emit AuctionSettled(address(0), _epochId, 0);
        }
    }

    // ─────────────────────────────────────────────────
    //  👑 OWNER FEES
    // ─────────────────────────────────────────────────

    function claimOwnerFees() external nonReentrant onlyManagerOwner returns (uint256 amount_) {
        _withdrawAllFees(address(this), true);
        amount_ = ownerFeesAccrued;
        if (amount_ == 0) return 0;

        ownerFeesClaimed += amount_;
        ownerFeesAccrued  = 0;

        _sendETH(msg.sender, amount_);
        emit OwnerFeesClaimed(amount_);
    }

    // ─────────────────────────────────────────────────
    //  ITreasuryManager OVERRIDES
    // ─────────────────────────────────────────────────

    function balances(address _recipient) public view override returns (uint256) {
        uint256 total;
        if (_recipient == managerOwner) total += ownerFeesAccrued;
        total += _pendingConviction(_recipient);
        return total;
    }

    function claim() external override nonReentrant returns (uint256 amount_) {
        _withdrawAllFees(address(this), true);

        uint256 convAmt = _pendingConviction(msg.sender);
        if (convAmt > 0) {
            convictionClaimed[msg.sender] += convAmt;
            amount_ += convAmt;
            emit ConvictionFeesClaimed(msg.sender, convAmt);
        }

        if (msg.sender == managerOwner && ownerFeesAccrued > 0) {
            amount_          += ownerFeesAccrued;
            ownerFeesClaimed += ownerFeesAccrued;
            emit OwnerFeesClaimed(ownerFeesAccrued);
            ownerFeesAccrued  = 0;
        }

        if (amount_ > 0) _sendETH(msg.sender, amount_);
    }

    // ─────────────────────────────────────────────────
    //  VIEW HELPERS
    // ─────────────────────────────────────────────────

    /// State of a slot: 0=empty, 1=open (<$40 leader), 2=contested ($40-49), 3=locked
    function slotState(uint256 _slotId) external view returns (uint8) {
        if (slotLocked[_slotId])                          return 3;
        if (slotLeaderAmt[_slotId] == 0)                  return 0;
        if (slotLeaderAmt[_slotId] >= SLOT_SAFE_THRESHOLD) return 2;
        return 1;
    }

    function epochInfo() external view returns (
        uint256 id, uint256 secsRemaining, uint256 holderFees,
        uint256 vaultFees, uint256 auctionPot, uint256 totalWeight
    ) {
        id = currentEpoch;
        uint256 ends = epochStart + EPOCH_DURATION;
        secsRemaining = block.timestamp < ends ? ends - block.timestamp : 0;
        Epoch memory ep = epochs[currentEpoch];
        return (id, secsRemaining, ep.holderFees, ep.vaultFees, ep.auctionPot, ep.totalWeight);
    }

    function vaultInfo(address _user) external view returns (
        uint256 amount, uint256 unlockTime, uint256 multiplierBP, bool isLocked
    ) {
        VaultEntry memory v = vaults[_user];
        return (v.amount, v.unlockTime, v.multiplierBP, block.timestamp < v.unlockTime);
    }

    function estimatedWeight(address _user) external view returns (uint256) {
        if (memecoin == address(0)) return 0;
        return _computeWeight(_user, IERC20(memecoin).balanceOf(_user));
    }

    function pendingConvictionFees(address _user) external view returns (uint256) {
        return _pendingConviction(_user);
    }

    // ─────────────────────────────────────────────────
    //  INTERNAL HELPERS
    // ─────────────────────────────────────────────────

    function _computeWeight(address _user, uint256 _balance) internal view returns (uint256 weight_) {
        weight_ = _balance;
        VaultEntry memory v = vaults[_user];
        if (v.amount > 0 && block.timestamp < v.unlockTime) {
            uint256 locked = v.amount < _balance ? v.amount : _balance;
            weight_ = (_balance - locked) + (locked * v.multiplierBP / 10_000);
        }
    }

    /**
     * @dev Conviction fee calculation:
     *   Each slot = (1 / MAX_CONVICTION_SLOTS) of totalConvictionEth.
     *   Locked slot: 100% of that slot's share goes to lockedBy.
     *   Unlocked slot: proportional to deposits (userDeposit / slotTotal).
     */
    function _pendingConviction(address _user) internal view returns (uint256 earned_) {
        if (totalConvictionEth == 0) return 0;

        uint256 ethPerSlot = totalConvictionEth / MAX_CONVICTION_SLOTS;

        for (uint256 i; i < MAX_CONVICTION_SLOTS; i++) {
            if (slotLocked[i]) {
                // Locked: only the permanent owner earns
                if (slotLockedBy[i] == _user) {
                    earned_ += ethPerSlot;
                }
            } else {
                // Unlocked: proportional to deposits
                uint256 total = slotTotalDeposits[i];
                if (total > 0) {
                    uint256 myDeposit = slotDeposits[i][_user];
                    if (myDeposit > 0) {
                        earned_ += (ethPerSlot * myDeposit) / total;
                    }
                }
            }
        }

        // Subtract already claimed
        if (earned_ <= convictionClaimed[_user]) return 0;
        return earned_ - convictionClaimed[_user];
    }

    function _sendETH(address _to, uint256 _amount) internal {
        if (_amount == 0 || _to == address(0)) return;
        (bool ok, bytes memory reason) = _to.call{value: _amount}("");

        /// @custom:audit If the recipient of the ETH does not implement the `receive` function, or reverts within the function callback, then
        /// this will revert. This will cause problems for bids as the `highestBidder` can prevent other users from placing bids.
        /// Any `_sendETH` calls that don't have the `msg.sender` as the `_to` address would be better to use an pull claim escrow pattern
        /// to prevent bricked calls. Alternatively, you can ignore the `ok` call and not revert if the call fails.
        if (!ok) revert UnableToSendETH(reason);
    }
}
