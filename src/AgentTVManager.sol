// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title AgentTVManager
 * @author Alfred & Linds
 * @notice A novel Flaunch TreasuryManager combining four fee mechanics:
 *
 *   📈 VOLUME SEATS   (40%) — Hold the token, snapshot your balance weekly, earn proportionally.
 *                             Diamond Vault holders get a multiplier on their snapshot weight.
 *   💎 DIAMOND VAULTS (10%) — Lock tokens 30/60/90 days → 1.5x/1.75x/2x multiplier on seat weight.
 *   🎯 CONVICTION POOL(25%) — 50 slots, one-time USDC buy-in (bonding curve), earn forever.
 *                             Slots are transferable — secondary market built-in.
 *   🔄 WEEKLY AUCTION  (5%) — Each epoch's pot goes to the highest ETH bidder. Bid wars = fun.
 *   👑 OWNER          (20%) — Immediate allocation, claimable anytime.
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

    /// Fee shares (5 decimal precision — 100_00000 = 100%)
    uint256 public constant TOTAL_SHARES      = 100_00000;
    uint256 public constant OWNER_SHARE       = 20_00000;  // 20%
    uint256 public constant HOLDER_SHARE      = 40_00000;  // 40%
    uint256 public constant VAULT_BOOST_SHARE = 10_00000;  // 10%
    uint256 public constant CONVICTION_SHARE  = 25_00000;  // 25%
    uint256 public constant AUCTION_SHARE     =  5_00000;  //  5%

    /// Conviction pool
    uint256 public constant MAX_CONVICTION_SLOTS  = 50;
    uint256 public constant CONVICTION_BASE_PRICE = 1e6;   // $1 USDC base
    uint256 public constant CONVICTION_STEP       = 1e6;   // +$1 per slot sold

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
    error ConvictionSlotsFull();
    error EpochNotOver();
    error InvalidLockDuration();
    error NoVaultFound();
    error NotSlotOwner();
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
    event ConvictionSlotBought(address indexed buyer, uint256 slotId, uint256 priceUsdc);
    event ConvictionSlotTransferred(uint256 indexed slotId, address indexed from, address indexed to);
    event ConvictionFeesClaimed(address indexed user, uint256 amount);
    event AuctionBid(address indexed bidder, uint256 indexed epochId, uint256 amount);
    event AuctionSettled(address indexed winner, uint256 indexed epochId, uint256 pot);
    event OwnerFeesClaimed(uint256 amount);

    // ─────────────────────────────────────────────────
    //  STRUCTS
    // ─────────────────────────────────────────────────

    struct Epoch {
        uint256 holderFees;           // ETH for holder pool
        uint256 vaultFees;            // ETH for vault boosters
        uint256 auctionPot;           // ETH for weekly auction
        uint256 totalWeight;          // sum of all snapshotted weights
        uint256 auctionEnd;           // timestamp when bidding closes
        address highestBidder;
        uint256 highestBid;
        bool    settled;
    }

    struct UserEpochData {
        uint256 weight;          // snapshotted weight (balance + vault boost)
        uint256 claimedHolder;   // ETH already claimed from holderFees
        uint256 claimedVault;    // ETH already claimed from vaultFees
    }

    struct VaultEntry {
        uint256 amount;          // tokens locked
        uint256 unlockTime;      // when lockup expires
        uint256 multiplierBP;    // 15000 / 17500 / 20000
    }

    // ─────────────────────────────────────────────────
    //  STATE
    // ─────────────────────────────────────────────────

    /// Memecoin address (set on first deposit)
    address public memecoin;

    /// USDC address (for conviction pool purchases)
    address public immutable usdc;

    // — Epoch tracking —
    uint256 public currentEpoch;
    uint256 public epochStart;
    mapping(uint256 => Epoch) public epochs;
    mapping(address => mapping(uint256 => UserEpochData)) public userEpochs;

    // — Owner fees —
    uint256 public ownerFeesAccrued;
    uint256 public ownerFeesClaimed;

    // — Conviction pool —
    mapping(uint256 => address) public convictionSlotOwner;  // slotId → owner
    uint256 public slotsSold;
    uint256 public totalConvictionEth;                        // lifetime ETH allocated
    mapping(address => uint256) public convictionClaimed;     // ETH already claimed per address

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
    //  INITIALIZATION  (called once by TreasuryManagerFactory)
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
        // Resolve and store the memecoin address for balance lookups
        memecoin = address(_flaunchToken.flaunch.memecoin(_flaunchToken.tokenId));
    }

    // ─────────────────────────────────────────────────
    //  FEE RECEIPT  (ETH flows in here from FeeEscrow)
    // ─────────────────────────────────────────────────

    receive() external override payable {
        if (msg.value == 0) return;

        uint256 ownerCut   = (msg.value * OWNER_SHARE)       / TOTAL_SHARES;
        uint256 holderCut  = (msg.value * HOLDER_SHARE)      / TOTAL_SHARES;
        uint256 vaultCut   = (msg.value * VAULT_BOOST_SHARE) / TOTAL_SHARES;
        uint256 convCut    = (msg.value * CONVICTION_SHARE)  / TOTAL_SHARES;
        // Remainder (avoids rounding loss)
        uint256 auctCut    = msg.value - ownerCut - holderCut - vaultCut - convCut;

        ownerFeesAccrued  += ownerCut;
        totalConvictionEth += convCut;

        Epoch storage ep = epochs[currentEpoch];
        ep.holderFees += holderCut;
        ep.vaultFees  += vaultCut;
        ep.auctionPot += auctCut;
    }

    // ─────────────────────────────────────────────────
    //  EPOCH MANAGEMENT
    // ─────────────────────────────────────────────────

    /**
     * @notice Advance to the next epoch. Callable by anyone after EPOCH_DURATION.
     *         Opens a 24hr auction window for the current epoch's pot.
     */
    function advanceEpoch() external {
        if (block.timestamp < epochStart + EPOCH_DURATION) revert EpochNotOver();

        // Open auction window for the epoch that just ended
        Epoch storage ep = epochs[currentEpoch];
        if (ep.auctionPot > 0 && ep.auctionEnd == 0) {
            ep.auctionEnd = block.timestamp + AUCTION_WINDOW;
        }

        emit EpochAdvanced(currentEpoch, ep.holderFees, ep.vaultFees, ep.auctionPot);

        unchecked { currentEpoch++; }
        epochStart = block.timestamp;
    }

    // ─────────────────────────────────────────────────
    //  📈 VOLUME SEATS — snapshot + claim
    // ─────────────────────────────────────────────────

    /**
     * @notice Record your token balance for the current epoch.
     *         Call anytime during the epoch. Weight = balance + vault boost.
     *         Can be called multiple times — only updates if weight increases.
     */
    function snapshotBalance() external {
        if (memecoin == address(0)) revert TokenNotDeposited();

        uint256 rawBalance = IERC20(memecoin).balanceOf(msg.sender);
        uint256 weight     = _computeWeight(msg.sender, rawBalance);

        UserEpochData storage ud = userEpochs[msg.sender][currentEpoch];
        if (weight <= ud.weight) return; // only grow, never shrink

        Epoch storage ep = epochs[currentEpoch];
        ep.totalWeight = ep.totalWeight - ud.weight + weight;
        ud.weight = weight;

        emit BalanceSnapshotted(msg.sender, currentEpoch, weight);
    }

    /**
     * @notice Claim holder-pool + vault-boost fees for a completed epoch.
     * @param _epochId Must be a past epoch (< currentEpoch)
     */
    function claimHolderFees(uint256 _epochId) external nonReentrant returns (uint256 amount_) {
        if (_epochId >= currentEpoch) revert EpochNotOver();

        UserEpochData storage ud  = userEpochs[msg.sender][_epochId];
        Epoch         storage ep  = epochs[_epochId];

        if (ud.weight == 0 || ep.totalWeight == 0) return 0;

        uint256 holderAlloc = (ep.holderFees * ud.weight) / ep.totalWeight;
        uint256 vaultAlloc  = (ep.vaultFees  * ud.weight) / ep.totalWeight;

        uint256 unclaimed = (holderAlloc - ud.claimedHolder) + (vaultAlloc - ud.claimedVault);
        if (unclaimed == 0) return 0;

        ud.claimedHolder = holderAlloc;
        ud.claimedVault  = vaultAlloc;
        amount_ = unclaimed;

        _sendETH(msg.sender, amount_);
        emit HolderFeesClaimed(msg.sender, _epochId, amount_);
    }

    // ─────────────────────────────────────────────────
    //  💎 DIAMOND VAULTS — lock tokens for multiplier
    // ─────────────────────────────────────────────────

    /**
     * @notice Lock memecoin tokens to earn a multiplier on your holder seat weight.
     *         Stacks with existing vault (takes best multiplier, longest unlock time).
     * @param _amount    Token amount to lock (requires ERC20 approval)
     * @param _duration  LOCK_30D (1.5x) | LOCK_60D (1.75x) | LOCK_90D (2x)
     */
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

        // If upgrading an existing vault, take the better terms
        if (v.amount > 0) {
            if (multiplierBP < v.multiplierBP) multiplierBP = v.multiplierBP;
        }

        IERC20(memecoin).safeTransferFrom(msg.sender, address(this), _amount);

        v.amount       += _amount;
        v.unlockTime    = block.timestamp + _duration;
        v.multiplierBP  = multiplierBP;

        emit VaultLocked(msg.sender, v.amount, v.unlockTime, v.multiplierBP);
    }

    /**
     * @notice Withdraw tokens from a vault after the lock period expires.
     */
    function unlockTokens() external nonReentrant {
        VaultEntry storage v = vaults[msg.sender];
        if (v.amount == 0)                      revert NoVaultFound();
        if (block.timestamp < v.unlockTime)     revert VaultStillLocked();

        uint256 amount = v.amount;
        delete vaults[msg.sender];

        IERC20(memecoin).safeTransfer(msg.sender, amount);
        emit VaultUnlocked(msg.sender, amount);
    }

    // ─────────────────────────────────────────────────
    //  🎯 CONVICTION POOL — buy a permanent fee share
    // ─────────────────────────────────────────────────

    /**
     * @notice Buy the next available conviction slot.
     *         Price = $1 + ($1 × slotsSold). Slot 0 = $1, Slot 49 = $50.
     *         Requires USDC approval. USDC goes directly to managerOwner.
     * @return slotId_ The ID of the slot purchased (0–49)
     */
    function buyConvictionSlot() external nonReentrant returns (uint256 slotId_) {
        if (slotsSold >= MAX_CONVICTION_SLOTS) revert ConvictionSlotsFull();

        slotId_ = slotsSold;
        uint256 price = CONVICTION_BASE_PRICE + (slotId_ * CONVICTION_STEP);

        IERC20(usdc).safeTransferFrom(msg.sender, managerOwner, price);

        convictionSlotOwner[slotId_] = msg.sender;
        unchecked { slotsSold++; }

        emit ConvictionSlotBought(msg.sender, slotId_, price);
    }

    /**
     * @notice Transfer a conviction slot to another address (OTC / secondary sale).
     */
    function transferConvictionSlot(uint256 _slotId, address _to) external {
        if (convictionSlotOwner[_slotId] != msg.sender) revert NotSlotOwner();
        convictionSlotOwner[_slotId] = _to;
        emit ConvictionSlotTransferred(_slotId, msg.sender, _to);
    }

    /**
     * @notice Claim accumulated ETH from conviction pool.
     *         Earnings = (slots you own / total slots sold) × totalConvictionEth
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
    //  🔄 WEEKLY AUCTION — bid on the epoch pot
    // ─────────────────────────────────────────────────

    /**
     * @notice Bid ETH on an epoch's auction pot.
     *         Bidding opens after that epoch's advanceEpoch() call.
     *         Previous bidder is automatically refunded.
     * @param _epochId The epoch to bid on
     */
    function bid(uint256 _epochId) external payable nonReentrant {
        if (msg.value == 0) revert ZeroAmount();

        Epoch storage ep = epochs[_epochId];
        if (ep.auctionEnd == 0)                     revert AuctionNotStarted();
        if (block.timestamp > ep.auctionEnd)         revert AuctionWindowClosed();
        if (msg.value <= ep.highestBid)              revert BidTooLow();

        // Refund the previous bidder
        if (ep.highestBidder != address(0)) {
            _sendETH(ep.highestBidder, ep.highestBid);
        }

        ep.highestBidder = msg.sender;
        ep.highestBid    = msg.value;

        emit AuctionBid(msg.sender, _epochId, msg.value);
    }

    /**
     * @notice Settle an auction after the bidding window closes.
     *         Winner receives the pot. Their bid flows to the owner.
     *         If no bids, the pot rolls to the owner.
     */
    function settleAuction(uint256 _epochId) external nonReentrant {
        Epoch storage ep = epochs[_epochId];
        if (ep.auctionEnd == 0)               revert AuctionNotStarted();
        if (ep.settled)                        revert AuctionAlreadySettled();
        if (block.timestamp <= ep.auctionEnd)  revert AuctionStillActive();

        ep.settled = true;

        if (ep.highestBidder != address(0)) {
            ownerFeesAccrued += ep.highestBid;
            _sendETH(ep.highestBidder, ep.auctionPot);
            emit AuctionSettled(ep.highestBidder, _epochId, ep.auctionPot);
        } else {
            // No bids — pot goes to owner
            ownerFeesAccrued += ep.auctionPot;
            emit AuctionSettled(address(0), _epochId, 0);
        }
    }

    // ─────────────────────────────────────────────────
    //  👑 OWNER FEES
    // ─────────────────────────────────────────────────

    /**
     * @notice Claim all accumulated owner fees. Only callable by managerOwner.
     */
    function claimOwnerFees() external nonReentrant onlyManagerOwner returns (uint256 amount_) {
        _withdrawAllFees(address(this), true);
        amount_ = ownerFeesAccrued;
        if (amount_ == 0) return 0;

        ownerFeesClaimed  += amount_;
        ownerFeesAccrued   = 0;

        _sendETH(msg.sender, amount_);
        emit OwnerFeesClaimed(amount_);
    }

    // ─────────────────────────────────────────────────
    //  ITreasuryManager REQUIRED OVERRIDES
    // ─────────────────────────────────────────────────

    function balances(address _recipient) public view override returns (uint256) {
        uint256 total;
        if (_recipient == managerOwner) total += ownerFeesAccrued;
        total += _pendingConviction(_recipient);
        return total;
    }

    function claim() external override nonReentrant returns (uint256 amount_) {
        _withdrawAllFees(address(this), true);

        // Conviction fees
        uint256 convAmt = _pendingConviction(msg.sender);
        if (convAmt > 0) {
            convictionClaimed[msg.sender] += convAmt;
            amount_ += convAmt;
            emit ConvictionFeesClaimed(msg.sender, convAmt);
        }

        // Owner fees
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

    /// Next conviction slot price in USDC (6 decimals)
    function nextSlotPrice() external view returns (uint256) {
        return CONVICTION_BASE_PRICE + (slotsSold * CONVICTION_STEP);
    }

    /// How many conviction slots an address owns
    function convictionSlotsOwned(address _user) external view returns (uint256 count_) {
        for (uint256 i; i < slotsSold; i++) {
            if (convictionSlotOwner[i] == _user) count_++;
        }
    }

    /// Pending conviction ETH for an address (not yet claimed)
    function pendingConvictionFees(address _user) external view returns (uint256) {
        return _pendingConviction(_user);
    }

    /// Current epoch summary
    function epochInfo() external view returns (
        uint256 id,
        uint256 secsRemaining,
        uint256 holderFees,
        uint256 vaultFees,
        uint256 auctionPot,
        uint256 totalWeight
    ) {
        id = currentEpoch;
        uint256 ends = epochStart + EPOCH_DURATION;
        secsRemaining = block.timestamp < ends ? ends - block.timestamp : 0;
        Epoch memory ep = epochs[currentEpoch];
        return (id, secsRemaining, ep.holderFees, ep.vaultFees, ep.auctionPot, ep.totalWeight);
    }

    /// Vault info for a user
    function vaultInfo(address _user) external view returns (
        uint256 amount,
        uint256 unlockTime,
        uint256 multiplierBP,
        bool    isLocked
    ) {
        VaultEntry memory v = vaults[_user];
        return (v.amount, v.unlockTime, v.multiplierBP, block.timestamp < v.unlockTime);
    }

    /// Estimated weight for an address in the current epoch
    function estimatedWeight(address _user) external view returns (uint256) {
        if (memecoin == address(0)) return 0;
        return _computeWeight(_user, IERC20(memecoin).balanceOf(_user));
    }

    // ─────────────────────────────────────────────────
    //  INTERNAL HELPERS
    // ─────────────────────────────────────────────────

    function _computeWeight(address _user, uint256 _balance) internal view returns (uint256 weight_) {
        weight_ = _balance;
        VaultEntry memory v = vaults[_user];
        if (v.amount > 0 && block.timestamp < v.unlockTime) {
            uint256 locked = v.amount < _balance ? v.amount : _balance;
            // Replace locked portion with boosted weight
            weight_ = (_balance - locked) + (locked * v.multiplierBP / 10_000);
        }
    }

    function _pendingConviction(address _user) internal view returns (uint256) {
        if (slotsSold == 0) return 0;
        uint256 owned;
        for (uint256 i; i < slotsSold; i++) {
            if (convictionSlotOwner[i] == _user) owned++;
        }
        if (owned == 0) return 0;
        uint256 earned = (totalConvictionEth * owned) / slotsSold;
        return earned > convictionClaimed[_user] ? earned - convictionClaimed[_user] : 0;
    }

    function _sendETH(address _to, uint256 _amount) internal {
        if (_amount == 0 || _to == address(0)) return;
        (bool ok, bytes memory reason) = _to.call{value: _amount}("");
        if (!ok) revert UnableToSendETH(reason);
    }
}
