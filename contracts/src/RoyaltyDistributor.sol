// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/**
 * @title RoyaltyDistributor
 * @notice Escrowed, pro-rata payout of streaming royalties to holders of a Clearwave
 *         royalty share.
 *
 * WHY MERKLE ROUNDS AND NOT ON-CHAIN PRO-RATA
 * Paying by share balance requires each holder's balance at a fixed moment. Cleanverse
 * A-Tokens provide no way to learn it: no ERC20Snapshot, no ERC20Votes, no
 * balanceOfAt/totalSupplyAt, and no transfer hook this contract could use to keep its own
 * accounting (all probed on-chain — every one of those calls reverts). Shares are freely
 * transferable between A-Pass holders, so reading `balanceOf` at CLAIM time is not a
 * substitute: a holder could claim, pass the shares on, and the recipient could claim the
 * same round again.
 *
 * So each payout is a ROUND: royalties deposited in full, plus a Merkle root committing to
 * (index, account, amount) for a stated snapshot block. Transfers are handled correctly
 * because the snapshot is a specific block, and double-claims are impossible because each
 * index is spendable once.
 *
 * ESCROW IS DELIBERATE: once a round is funded, every holder in it is guaranteed to be able
 * to claim. A royalty share is a security, and settlement certainty is the product promise —
 * holders should not have to trust that the artist still has the money when they turn up.
 *
 * ┌──────────────────────────────────────────────────────────────────────────────────────┐
 * │ ACCEPTED RISK — READ BEFORE DEPLOYING                                                │
 * │                                                                                      │
 * │ The payment asset is an A-Token that gates the SENDER as well as the recipient.      │
 * │ Verified on Monad testnet: a non-compliant sender reverts NoAPass(sender)             │
 * │ (0xa6725971), distinct from ERC20InsufficientBalance (0xe450d38c).                    │
 * │                                                                                      │
 * │ Therefore, if THIS CONTRACT's own A-Pass is ever revoked, every escrowed royalty is   │
 * │ frozen permanently. Not just claims — sweeps and skims too, because every exit is     │
 * │ itself a transfer. No emergency-withdraw function can help; one would be theatre.     │
 * │                                                                                      │
 * │ This was accepted knowingly in exchange for settlement certainty. Mitigations are     │
 * │ operational, not contractual:                                                        │
 * │   1. THIS CONTRACT MUST HOLD A CLEANVERSE A-PASS or it cannot receive royalties at    │
 * │      all. Issue one before the first round. Contract addresses can hold A-Passes      │
 * │      (verified on Monad testnet).                                                     │
 * │   2. Monitor that A-Pass. If it is ever at risk, drain rounds before it lapses.       │
 * │   3. Keep custody windows short — fund a round near when claims open, not months      │
 * │      ahead — so the amount exposed at any moment is small.                            │
 * │ Use {escrowAtRisk} to see how much is currently exposed.                              │
 * └──────────────────────────────────────────────────────────────────────────────────────┘
 *
 * Claimants need an A-Pass to receive a payout: enforced by the token, not by this contract.
 */
contract RoyaltyDistributor is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Asset royalties are paid in — the same A-Token used to buy shares.
    IERC20 public immutable payment;

    /// @notice Consulted to confirm a share token is vetted, and for claimant pre-checks.
    IComplianceValidator public validator;

    struct Round {
        address shareToken; // the royalty share this round pays out on
        address funder; // deposited the royalties
        address sweepTo; // where unclaimed funds go at expiry; defaults to funder
        uint256 amount; // total deposited and claimable
        uint256 claimed; // paid out so far; never exceeds `amount`
        bytes32 merkleRoot; // commits to (index, account, amount) leaves
        uint64 snapshotBlock; // block whose balances the root was computed from
        uint64 expiresAt; // after this, the remainder may be swept
        bool swept;
        string uri; // where the full holder list can be fetched and rechecked
    }

    Round[] private _rounds;

    /// @dev roundId => word index => bitmap of spent leaf indices.
    mapping(uint256 => mapping(uint256 => uint256)) private _claimedBitmap;

    /// @notice Escrowed funds owed to rounds. Anything above this is a stray transfer in.
    uint256 public totalCommitted;

    /// @notice Shortest allowed claim window, so a round cannot be swept from under holders.
    uint64 public constant MIN_CLAIM_WINDOW = 30 days;

    /// @notice Gas forwarded to the validator, so a hostile one cannot consume the whole call.
    uint256 public constant VALIDATOR_GAS = 150_000;

    event RoundCreated(
        uint256 indexed roundId,
        address indexed shareToken,
        address indexed funder,
        uint256 amount,
        bytes32 merkleRoot,
        uint64 snapshotBlock,
        uint64 expiresAt,
        string uri
    );
    event Claimed(uint256 indexed roundId, uint256 index, address indexed account, uint256 amount);
    event RoundSwept(uint256 indexed roundId, address indexed sweepTo, uint256 amount);
    event SweepRecipientSet(uint256 indexed roundId, address indexed sweepTo);
    event ValidatorSet(address indexed validator);

    error ZeroAddress();
    error ZeroAmount();
    error InvalidRound(uint256 roundId);
    error ShareTokenNotVetted(address shareToken);
    error PoolPaused(address shareToken);
    error EmptyMerkleRoot();
    error SnapshotInFuture(uint64 snapshotBlock);
    error ClaimWindowTooShort(uint64 expiresAt, uint64 minimum);
    error AlreadyClaimed(uint256 roundId, uint256 index);
    error InvalidProof(uint256 roundId, uint256 index, address account);
    error RoundExhausted(uint256 roundId, uint256 remaining, uint256 requested);
    error DepositNotReceived(uint256 expected, uint256 received);
    error PayoutNotDelivered(address account, uint256 expected, uint256 delivered);
    error NotFunder(uint256 roundId);
    error RoundNotExpired(uint256 roundId, uint64 expiresAt);
    error AlreadySwept(uint256 roundId);
    error ClaimantNotCompliant(address account);
    error OwnershipCannotBeRenounced();

    constructor(address paymentToken, address complianceValidator, address initialOwner) {
        if (
            paymentToken == address(0) || complianceValidator == address(0)
                || initialOwner == address(0)
        ) revert ZeroAddress();
        payment = IERC20(paymentToken);
        validator = IComplianceValidator(complianceValidator);
        if (initialOwner != msg.sender) _transferOwnership(initialOwner);
    }

    // ---------------------------------------------------------------- admin

    function setValidator(address v) external onlyOwner {
        if (v == address(0)) revert ZeroAddress();
        validator = IComplianceValidator(v);
        emit ValidatorSet(v);
    }

    /// @notice Disabled — an ownerless distributor could never replace a broken validator.
    function renounceOwnership() public pure override {
        revert OwnershipCannotBeRenounced();
    }

    // --------------------------------------------------------------- rounds

    /**
     * @notice Deposit royalties and open a claim round against a published Merkle root.
     * @param merkleRoot Commits to leaves keccak256(bytes.concat(keccak256(abi.encode(
     *                   index, account, amount)))) — double-hashed per OZ guidance so a leaf
     *                   can never be reinterpreted as an internal node.
     * @param snapshotBlock Block the balances were read at. Must already exist, so a
     *                   snapshot cannot be back-dated to a block nobody can inspect yet.
     * @param uri        Where the full holder list lives, so anyone can recompute the root.
     *
     * @dev The deposit is MEASURED, not assumed. The payment asset is an upgradeable
     *      A-Token: a fee-on-transfer or partially-crediting implementation would otherwise
     *      let a round promise more than it holds, and the shortfall would surface as a
     *      failed claim for whoever claimed last.
     */
    function createRound(
        address shareToken,
        uint256 amount,
        bytes32 merkleRoot,
        uint64 snapshotBlock,
        uint64 expiresAt,
        string calldata uri
    ) external nonReentrant returns (uint256 roundId) {
        if (shareToken == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (merkleRoot == bytes32(0)) revert EmptyMerkleRoot();
        if (snapshotBlock > block.number) revert SnapshotInFuture(snapshotBlock);
        if (expiresAt < block.timestamp + MIN_CLAIM_WINDOW) {
            revert ClaimWindowTooShort(expiresAt, uint64(block.timestamp) + MIN_CLAIM_WINDOW);
        }
        if (!validator.isRegistered(shareToken)) revert ShareTokenNotVetted(shareToken);
        if (validator.isPaused(shareToken)) revert PoolPaused(shareToken);

        uint256 before = payment.balanceOf(address(this));
        payment.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = payment.balanceOf(address(this)) - before;
        if (received != amount) revert DepositNotReceived(amount, received);

        totalCommitted += amount;

        roundId = _rounds.length;
        _rounds.push(
            Round({
                shareToken: shareToken,
                funder: msg.sender,
                sweepTo: msg.sender,
                amount: amount,
                claimed: 0,
                merkleRoot: merkleRoot,
                snapshotBlock: snapshotBlock,
                expiresAt: expiresAt,
                swept: false,
                uri: uri
            })
        );

        emit RoundCreated(
            roundId, shareToken, msg.sender, amount, merkleRoot, snapshotBlock, expiresAt, uri
        );
    }

    /**
     * @notice Nominate where this round's unclaimed remainder should go.
     * @dev The sweep destination is an A-Token transfer, so it must hold an A-Pass. A funder
     *      whose own A-Pass lapses would otherwise have their remainder stuck with no way to
     *      redirect it — the audit flagged exactly that. Only the funder may reassign, and
     *      only to a non-zero address.
     */
    function setSweepRecipient(uint256 roundId, address to) external {
        Round storage r = _get(roundId);
        if (msg.sender != r.funder) revert NotFunder(roundId);
        if (to == address(0)) revert ZeroAddress();
        r.sweepTo = to;
        emit SweepRecipientSet(roundId, to);
    }

    /**
     * @notice Claim a holder's share of a round.
     * @dev Permissionless in caller but not in destination: funds always go to `account`,
     *      the address committed in the leaf, so a third party may pay the gas to deliver
     *      someone else's royalties but can never redirect them.
     *
     *      The index is marked spent BEFORE the transfer and the function is nonReentrant,
     *      so a hostile payment token cannot re-enter to spend an index twice. Each round's
     *      `claimed` caps its own payouts, so an over-allocated root exhausts that round and
     *      nothing else — one round can never draw on another's escrow.
     */
    function claim(
        uint256 roundId,
        uint256 index,
        address account,
        uint256 amount,
        bytes32[] calldata proof
    ) external nonReentrant {
        Round storage r = _get(roundId);
        if (amount == 0) revert ZeroAmount();
        if (isClaimed(roundId, index)) revert AlreadyClaimed(roundId, index);

        if (!MerkleProof.verifyCalldata(proof, r.merkleRoot, _leaf(index, account, amount))) {
            revert InvalidProof(roundId, index, account);
        }

        uint256 remaining = r.amount - r.claimed;
        if (amount > remaining) revert RoundExhausted(roundId, remaining, amount);

        // UX pre-check. The payment A-Token enforces compliance again and is the real
        // authority; without this the holder would hit a bare NoAPass with no explanation.
        if (!_compliant(r.shareToken, account)) revert ClaimantNotCompliant(account);

        _setClaimed(roundId, index);
        r.claimed += amount;
        totalCommitted -= amount;

        uint256 before = payment.balanceOf(account);
        payment.safeTransfer(account, amount);
        uint256 delivered = payment.balanceOf(account) - before;
        if (delivered != amount) revert PayoutNotDelivered(account, amount, delivered);

        emit Claimed(roundId, index, account, amount);
    }

    /**
     * @notice After expiry, return whatever went unclaimed to the round's sweep recipient.
     * @dev Rounds over-provision in practice (dust, lost keys, holders who never turn up).
     *      Without this the remainder would sit here forever. It cannot run early —
     *      MIN_CLAIM_WINDOW guarantees holders at least 30 days — and it can only move that
     *      round's own unclaimed balance, never another round's.
     */
    function sweepExpired(uint256 roundId) external nonReentrant {
        Round storage r = _get(roundId);
        if (msg.sender != r.funder && msg.sender != owner()) revert NotFunder(roundId);
        if (block.timestamp <= r.expiresAt) revert RoundNotExpired(roundId, r.expiresAt);
        if (r.swept) revert AlreadySwept(roundId);

        uint256 remaining = r.amount - r.claimed;
        r.swept = true;
        if (remaining == 0) {
            emit RoundSwept(roundId, r.sweepTo, 0);
            return;
        }

        r.claimed = r.amount; // nothing further is claimable
        totalCommitted -= remaining;
        payment.safeTransfer(r.sweepTo, remaining);
        emit RoundSwept(roundId, r.sweepTo, remaining);
    }

    /**
     * @notice Recover tokens sent here by mistake, never funds owed to a round.
     * @dev Only the surplus above `totalCommitted` can move, so this can never touch money
     *      holders are entitled to. Deliberately not a general rescue function.
     */
    function skimSurplus(address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = payment.balanceOf(address(this));
        uint256 surplus = bal > totalCommitted ? bal - totalCommitted : 0;
        if (surplus == 0) revert ZeroAmount();
        payment.safeTransfer(to, surplus);
    }

    // ----------------------------------------------------------------- read

    function roundCount() external view returns (uint256) {
        return _rounds.length;
    }

    function getRound(uint256 roundId) external view returns (Round memory) {
        return _get(roundId);
    }

    function isClaimed(uint256 roundId, uint256 index) public view returns (bool) {
        return (_claimedBitmap[roundId][index / 256] >> (index % 256)) & 1 == 1;
    }

    function remainingOf(uint256 roundId) public view returns (uint256) {
        Round storage r = _get(roundId);
        return r.amount - r.claimed;
    }

    /**
     * @notice How much escrow would be frozen if this contract lost its A-Pass.
     * @dev Surfaces the accepted risk in the contract header as a number an operator can
     *      watch, rather than a caveat in a comment nobody reads.
     */
    function escrowAtRisk() external view returns (uint256) {
        return payment.balanceOf(address(this));
    }

    /// @notice Whether this exact claim would succeed right now. Mirrors {claim} exactly.
    function canClaim(
        uint256 roundId,
        uint256 index,
        address account,
        uint256 amount,
        bytes32[] calldata proof
    ) external view returns (bool) {
        if (roundId >= _rounds.length) return false;
        Round storage r = _rounds[roundId];
        if (amount == 0 || isClaimed(roundId, index)) return false;
        if (!MerkleProof.verifyCalldata(proof, r.merkleRoot, _leaf(index, account, amount))) {
            return false;
        }
        if (amount > r.amount - r.claimed) return false;
        return _compliant(r.shareToken, account);
    }

    /// @notice The leaf encoding claimants must use when building proofs.
    function leafFor(uint256 index, address account, uint256 amount)
        external
        pure
        returns (bytes32)
    {
        return _leaf(index, account, amount);
    }

    // ------------------------------------------------------------- internal

    /**
     * @dev Compliance failure must be an ANSWER, not a revert. An unguarded call let a
     *      reverting or gas-burning validator brick every claim and every canClaim, so the
     *      UI could not even say why. Failing closed is the correct direction for a
     *      compliance gate, and the gas cap stops a hostile implementation consuming the
     *      63/64 the EVM would otherwise forward.
     */
    function _compliant(address pool, address wallet) private view returns (bool) {
        try validator.verify{gas: VALIDATOR_GAS}(pool, wallet) returns (bool ok, bool) {
            return ok;
        } catch {
            return false;
        }
    }

    function _leaf(uint256 index, address account, uint256 amount)
        private
        pure
        returns (bytes32)
    {
        // Double hash: prevents a 64-byte leaf being reinterpreted as an internal node.
        return keccak256(bytes.concat(keccak256(abi.encode(index, account, amount))));
    }

    function _setClaimed(uint256 roundId, uint256 index) private {
        _claimedBitmap[roundId][index / 256] |= (1 << (index % 256));
    }

    function _get(uint256 roundId) private view returns (Round storage) {
        if (roundId >= _rounds.length) revert InvalidRound(roundId);
        return _rounds[roundId];
    }
}

interface IComplianceValidator {
    function verify(address pool, address wallet) external view returns (bool ok, bool checked);
    function isRegistered(address pool) external view returns (bool);
    function isPaused(address pool) external view returns (bool);
}
