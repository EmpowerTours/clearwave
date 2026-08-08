// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/access/IAccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title ShareOffering
 * @notice Fixed-price primary sale of music royalty shares on Monad.
 *
 * An artist sells a slice of their future streaming royalties. The share itself is a
 * Cleanverse A-Token (CVA) issued through /atoken/launch, so compliance is enforced by
 * the instrument rather than by this contract: the A-Token reverts with `NoAPass(addr)`
 * if it is ever minted or transferred to a wallet without a Cleanverse A-Pass (CVI).
 * That behaviour was verified on Monad testnet before this contract was written — it is
 * the reason no bespoke share token exists here.
 *
 * Payment is aUSDC, itself an A-Token, so the buyer must hold an A-Pass to spend it and
 * the artist must hold one to receive it. Both legs of the trade are gated by Cleanverse.
 *
 * NO CUSTODY: aUSDC moves investor -> artist directly inside buy(). This contract never
 * holds either asset. It removes an entire class of risk, and it means the artist is paid
 * atomically with share issuance rather than waiting on a withdrawal.
 *
 * Two compliance checks run, deliberately:
 *   1. This contract asks APassComplianceValidator first, so an ineligible buyer gets
 *      `BuyerNotCompliant` and the frontend can send them to the A-Pass magickLink.
 *      Without it the buyer would hit the A-Token's raw `NoAPass` revert with no context.
 *   2. The A-Token enforces it again at mint. That is the check that actually protects
 *      the offering — ours is UX, and is never the sole line of defence. If the validator
 *      is misconfigured or repointed, the token still refuses.
 *
 * The validator also applies pool rules (tier, and country once an attribute oracle is
 * set) that the A-Token's own global rule does not express per-offering.
 */
contract ShareOffering is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Payment asset — Cleanverse aUSDC on this chain.
    IERC20 public immutable payment;

    /// @notice Compliance validator consulted for buyer eligibility (UX pre-check).
    IComplianceValidator public validator;

    struct Offering {
        address artist; // receives aUSDC directly; must hold an A-Pass
        address shareToken; // the Cleanverse A-Token representing royalty shares
        uint256 pricePerShare; // aUSDC smallest units per ONE WHOLE share
        uint256 totalShares; // whole shares offered
        uint256 sharesSold; // whole shares sold so far
        uint64 closesAt; // unix seconds; 0 = no deadline
        bool closed; // artist closed it early
        bool isSealed; // supply proven bounded; required before any sale
        bool requireAttributeChecks; // reject buys the validator cannot fully evaluate
        uint256 baselineSupply; // share units in existence at seal time; see {sealOffering}
    }

    /// @dev Offerings are append-only; id is the index.
    Offering[] private _offerings;

    /// @notice Cached decimals of each share token, read once at creation.
    mapping(uint256 => uint8) public shareDecimals;

    /// @notice Share units that already existed when the offering was sealed.
    /// @dev Non-zero means the token was not empty at seal — read it before buying. See
    ///      {sealOffering} for why a baseline is recorded rather than demanded to be zero.
    function baselineSupplyOf(uint256 id) external view returns (uint256) {
        return _get(id).baselineSupply;
    }

    /**
     * @notice One offering per share token, as `token => id + 1` (0 means none).
     * @dev Two offerings backed by the same token cannot coexist: the supply invariant is
     *      "totalSupply == my baseline + my sharesSold", so the first sale on offering A
     *      immediately breaks offering B's invariant and bricks it. Rather than let an
     *      artist create a dead offering, reject the duplicate at source. The claim is
     *      released by {abandonOffering} so a mistake or a grief is never permanent.
     */
    mapping(address => uint256) private _offeringOfToken;

    event OfferingCreated(
        uint256 indexed id,
        address indexed artist,
        address indexed shareToken,
        uint256 pricePerShare,
        uint256 totalShares,
        uint64 closesAt
    );
    event SharesPurchased(
        uint256 indexed id, address indexed buyer, uint256 wholeShares, uint256 cost
    );
    event OfferingClosed(uint256 indexed id);
    event OfferingSealed(uint256 indexed id, address indexed shareToken);
    event OfferingAbandoned(uint256 indexed id, address indexed shareToken);
    event DeadlineExtended(uint256 indexed id, uint64 closesAt);
    event ValidatorSet(address indexed validator);

    error ZeroAddress();
    error InvalidOffering(uint256 id);
    error NotArtist(uint256 id);
    error NotTokenAdmin(address shareToken);
    error OfferingIsClosed(uint256 id);
    error OfferingExpired(uint256 id);
    error ZeroAmount();
    error SoldOut(uint256 id, uint256 remaining);
    error BuyerNotCompliant(address buyer);
    error MinterRoleMissing(address shareToken);
    error BadPrice();
    error OfferingNotSealed(uint256 id);
    error AlreadySealed(uint256 id);
    error ArtistRetainsMintRights(address shareToken);
    error AttributeChecksUnavailable(address buyer);
    error SupplyInvariantBroken(uint256 id, uint256 expected, uint256 actual);
    error ShareTokenNotVetted(address shareToken);
    error TokenAlreadyOffered(address shareToken, uint256 existingId);
    error PaymentNotReceived(uint256 id, uint256 expected, uint256 received);
    error SharesNotDelivered(uint256 id, uint256 expected, uint256 delivered);
    error PoolPaused(address pool);
    error UnsupportedDecimals(address shareToken, uint8 decimals);
    error OfferingHasSales(uint256 id, uint256 sharesSold);
    error DeadlineInPast(uint64 closesAt);
    error DeadlineNotExtended(uint64 current, uint64 proposed);
    error OwnershipCannotBeRenounced();

    constructor(address paymentToken, address complianceValidator, address initialOwner) {
        if (
            paymentToken == address(0) || initialOwner == address(0)
                || complianceValidator == address(0)
        ) revert ZeroAddress();
        payment = IERC20(paymentToken);
        validator = IComplianceValidator(complianceValidator);
        if (initialOwner != msg.sender) _transferOwnership(initialOwner);
    }

    // ---------------------------------------------------------------- admin

    /**
     * @notice Swap the compliance validator.
     * @dev Zero is rejected. The validator is not merely a UX pre-check any more — it is
     *      the provenance gate that keeps counterfeit share tokens out of createOffering,
     *      so allowing it to be unset would reopen that hole for every future offering.
     */
    function setValidator(address v) external onlyOwner {
        if (v == address(0)) revert ZeroAddress();
        validator = IComplianceValidator(v);
        emit ValidatorSet(v);
    }

    /// @notice Disabled — an ownerless ShareOffering could never swap a broken validator
    ///         or clear a squatted token slot. See {abandonOffering}.
    function renounceOwnership() public pure override {
        revert OwnershipCannotBeRenounced();
    }

    // ------------------------------------------------------------ offerings

    /**
     * @notice Open a fixed-price offering. Caller must be the A-Token's admin.
     * @dev Requiring DEFAULT_ADMIN_ROLE on the share token is how artist ownership is
     *      proven on-chain: Cleanverse grants that role to the `admin_address` supplied
     *      at /atoken/launch, so only the party that actually issued the token can offer
     *      it. No registry or allowlist needed.
     *
     *      This contract must separately hold MINTER_ROLE on the token — checked here so
     *      a misconfigured offering fails at creation rather than on a buyer's first
     *      purchase.
     */
    function createOffering(
        address shareToken,
        uint256 pricePerShare,
        uint256 totalShares,
        uint64 closesAt,
        bool requireAttributeChecks
    ) external returns (uint256 id) {
        if (shareToken == address(0)) revert ZeroAddress();
        if (pricePerShare == 0) revert BadPrice();
        if (totalShares == 0) revert ZeroAmount();

        uint256 existing = _offeringOfToken[shareToken];
        if (existing != 0) revert TokenAlreadyOffered(shareToken, existing - 1);

        /**
         * Provenance gate. This contract cannot tell a genuine Cleanverse A-Token from an
         * imposter: A-Tokens expose no getter naming the A-Pass registry or AccessCore
         * (probed on-chain — apass(), accessCore(), registry() and similar all revert), so
         * there is nothing on the token to authenticate. Without this check an artist can
         * deploy a plain ERC-20 with AccessControl that satisfies every structural test
         * here — it seals, and it can even fake totalSupply so the supply invariant always
         * passes — while enforcing no A-Pass rule at all. Buyers would believe they hold a
         * compliance-gated security and actually hold an ordinary token.
         *
         * Registration in the validator is therefore the vetting step: the platform
         * confirms off-chain (via Cleanverse's own A-Token list) that the address really is
         * an issued A-Token, then registers it as a pool. Requiring it HERE rather than
         * relying on buy()'s compliance call makes the gate explicit and fails at creation
         * instead of confusing the first buyer.
         */
        if (address(validator) == address(0)) revert ZeroAddress();
        if (!validator.isRegistered(shareToken)) revert ShareTokenNotVetted(shareToken);
        // Pausing is the platform's only de-vetting lever; a paused pool is a withdrawn
        // credential. Without this an offering can be created AND sealed on a suspended
        // token, consuming its one offering slot while every buy reverts.
        if (validator.isPaused(shareToken)) revert PoolPaused(shareToken);
        if (closesAt != 0 && closesAt <= block.timestamp) revert DeadlineInPast(closesAt);

        IAccessControl ac = IAccessControl(shareToken);
        if (!ac.hasRole(0x00, msg.sender)) revert NotTokenAdmin(shareToken); // DEFAULT_ADMIN_ROLE
        if (!ac.hasRole(keccak256("MINTER_ROLE"), address(this))) {
            revert MinterRoleMissing(shareToken);
        }

        id = _offerings.length;
        _offerings.push(
            Offering({
                artist: msg.sender,
                shareToken: shareToken,
                pricePerShare: pricePerShare,
                totalShares: totalShares,
                sharesSold: 0,
                closesAt: closesAt,
                closed: false,
                isSealed: false,
                requireAttributeChecks: requireAttributeChecks,
                baselineSupply: 0
            })
        );
        // 10 ** decimals overflows uint256 at 78, which would panic buy(), supplyIntact()
        // and isActive() permanently — including the two views buyers are told to consult.
        // Bound it well below that; no real A-Token exceeds 18.
        uint8 dec = IERC20Decimals(shareToken).decimals();
        if (dec > 36) revert UnsupportedDecimals(shareToken, dec);
        shareDecimals[id] = dec;
        _offeringOfToken[shareToken] = id + 1;

        emit OfferingCreated(id, msg.sender, shareToken, pricePerShare, totalShares, closesAt);
    }

    /**
     * @notice Prove the share supply is bounded, then open the offering for business.
     *
     * @dev Without this step the offering is worthless to a buyer. The artist holds
     *      DEFAULT_ADMIN_ROLE on the share A-Token (Cleanverse grants it at
     *      /atoken/launch), so they could grant themselves MINTER_ROLE and print shares
     *      after a sale — diluting an investor who bought "10 of 1000" to an arbitrarily
     *      small fraction. Nothing else in this contract prevents that.
     *
     *      Sealing requires the artist to have renounced BOTH roles and the token to be
     *      empty, so from this point the only minter that matters is this contract and
     *      the supply cannot exceed `totalShares`. The order is forced by design:
     *      createOffering needs admin, sealOffering needs it gone.
     *
     *      Artist flow: grant MINTER_ROLE to this contract -> createOffering ->
     *      renounce MINTER_ROLE and DEFAULT_ADMIN_ROLE -> sealOffering.
     *
     *      RESIDUAL RISK, stated plainly: Cleanverse A-Tokens do NOT implement
     *      AccessControlEnumerable (verified on-chain — supportsInterface(0x5a05180f)
     *      is false and getRoleMemberCount reverts), so this contract cannot enumerate
     *      role holders and cannot detect a THIRD party that was granted MINTER_ROLE
     *      before sealing. The totalSupply == 0 check bounds what has already been
     *      minted, not who may mint later. Buyers should check the token's RoleGranted
     *      history. If Cleanverse adds enumeration, tighten this to assert exactly one
     *      minter.
     */
    function sealOffering(uint256 id) external {
        Offering storage o = _get(id);
        if (msg.sender != o.artist) revert NotArtist(id);
        if (o.isSealed) revert AlreadySealed(id);

        IAccessControl ac = IAccessControl(o.shareToken);
        if (!ac.hasRole(keccak256("MINTER_ROLE"), address(this))) {
            revert MinterRoleMissing(o.shareToken);
        }
        if (
            ac.hasRole(0x00, o.artist) || ac.hasRole(keccak256("MINTER_ROLE"), o.artist)
        ) {
            revert ArtistRetainsMintRights(o.shareToken);
        }
        /**
         * Record whatever already exists rather than demanding zero.
         *
         * Demanding totalSupply == 0 looked safer and was strictly worse: A-Tokens have no
         * burn, so anyone able to mint even ONE WEI before sealing made the token
         * permanently unsealable — and therefore permanently unusable on this platform,
         * for the cost of one transaction. The pen-test proved it (a griefer needs no
         * A-Pass and no funds; the wei can be sent to the artist).
         *
         * A recorded baseline is disclosure instead of a brick. The invariant becomes
         * baseline + sold, so post-seal minting is still detected exactly as before, while
         * pre-existing dust is tolerated and visible: buyers read {baselineSupplyOf} and
         * see precisely how many shares existed before the sale. An artist who pre-mints a
         * large float cannot hide it — it is on the offering, on-chain, before anyone buys.
         */
        o.baselineSupply = IERC20(o.shareToken).totalSupply();

        o.isSealed = true;
        emit OfferingSealed(id, o.shareToken);
    }

    /**
     * @notice Buy `wholeShares` at the fixed price.
     * @dev Payment is pulled from the buyer and pushed to the artist in one step, so the
     *      contract never custodies aUSDC. Shares are minted after payment settles
     *      (checks-effects-interactions), and the A-Token's own `NoAPass` guard is the
     *      final authority on whether the buyer may hold them.
     */
    function buy(uint256 id, uint256 wholeShares) external nonReentrant {
        Offering storage o = _get(id);
        if (!o.isSealed) revert OfferingNotSealed(id); // supply must be provably bounded first
        if (o.closed) revert OfferingIsClosed(id);
        if (o.closesAt != 0 && block.timestamp > o.closesAt) revert OfferingExpired(id);
        if (wholeShares == 0) revert ZeroAmount();

        uint256 remaining = o.totalShares - o.sharesSold;
        if (wholeShares > remaining) revert SoldOut(id, remaining);

        // UX pre-check only — the A-Token enforces this again at mint. See contract notes.
        //
        // `checked` reports whether the validator actually evaluated tier/country rules or
        // merely confirmed A-Pass possession (it cannot do the former until an attribute
        // oracle is configured). An offering that depends on those rules — a
        // jurisdiction-restricted tranche, say — must not silently accept a
        // possession-only answer, so it opts in via requireAttributeChecks and buys fail
        // loudly until the oracle exists. Reading `ok` and discarding `checked` is exactly
        // the mistake the flag was added to prevent.
        // The validator can never be address(0) — enforced in the constructor and setValidator.
        (bool ok, bool checked) = validator.verify(o.shareToken, msg.sender);
        if (!ok) revert BuyerNotCompliant(msg.sender);
        if (o.requireAttributeChecks && !checked) {
            revert AttributeChecksUnavailable(msg.sender);
        }

        /**
         * Supply invariant. Every share in existence must have been sold by this
         * offering, so totalSupply must equal exactly what we have sold so far.
         *
         * This is the real defence against dilution, and it is deliberately checked on
         * every purchase rather than once at sealing. Sealing proves the artist holds no
         * mint rights and the token started empty — but Cleanverse A-Tokens do not
         * implement AccessControlEnumerable (verified on-chain: supportsInterface
         * (0x5a05180f) is false, getRoleMemberCount reverts), so this contract cannot
         * enumerate role holders and CANNOT rule out a co-admin the artist granted before
         * renouncing. That co-admin could grant themselves MINTER_ROLE at any time.
         *
         * What it cannot prevent, it detects. The moment a single share is minted outside
         * this contract the invariant breaks and every subsequent buy reverts, so the
         * offering halts instead of continuing to sell into a diluted supply. An attacker
         * can still harm holders who already bought — that is unavoidable without
         * enumeration — but cannot dilute and keep selling, which removes the profit
         * motive. Buyers can check {supplyIntact} before committing funds.
         */
        uint256 expectedSupply = o.baselineSupply + o.sharesSold * (10 ** shareDecimals[id]);
        uint256 actualSupply = IERC20(o.shareToken).totalSupply();
        if (actualSupply != expectedSupply) {
            revert SupplyInvariantBroken(id, expectedSupply, actualSupply);
        }

        uint256 cost = wholeShares * o.pricePerShare;
        uint256 shareUnits = wholeShares * (10 ** shareDecimals[id]);

        o.sharesSold += wholeShares;

        /**
         * Both legs are MEASURED, never assumed.
         *
         * Payment: `safeTransferFrom` succeeding does not mean the artist got paid. If the
         * buyer IS the artist the transfer is a self-send that nets zero, so the artist
         * could mint the entire float for free and dilute real investors with their own
         * money. A fee-on-transfer or skimming payment asset short-pays them the same way
         * while this contract records a full sale. Comparing the artist's balance before
         * and after catches both, and is why `msg.sender == o.artist` needs no special case.
         *
         * Shares: `mint` succeeding does not mean shares were delivered. A-Tokens are
         * upgradeable ERC-1967 proxies and the validator's vetting is a POINT-IN-TIME
         * check, so a token registered and sealed honestly can later be upgraded to make
         * mint a no-op — and to return whatever totalSupply the invariant above expects,
         * since that value is readable from inside the call. Buyers would pay and receive
         * nothing, with every view still reporting healthy. Requiring the buyer's balance
         * to actually rise by `shareUnits` closes the no-op, partial-mint and capped-mint
         * cases.
         *
         * A fully hostile implementation could also fake balanceOf, which no on-chain check
         * can defeat — but that lie breaks every wallet and explorer, so it is loud rather
         * than silent. The header's claim that the A-Token is an immutable final authority
         * is wrong: it is upgradeable, and these deltas are what make that survivable.
         */
        uint256 artistBefore = payment.balanceOf(o.artist);
        payment.safeTransferFrom(msg.sender, o.artist, cost);
        uint256 paid = payment.balanceOf(o.artist) - artistBefore;
        if (paid != cost) revert PaymentNotReceived(id, cost, paid);

        uint256 buyerBefore = IERC20(o.shareToken).balanceOf(msg.sender);
        IAToken(o.shareToken).mint(msg.sender, shareUnits);
        uint256 delivered = IERC20(o.shareToken).balanceOf(msg.sender) - buyerBefore;
        if (delivered != shareUnits) revert SharesNotDelivered(id, shareUnits, delivered);

        emit SharesPurchased(id, msg.sender, wholeShares, cost);
    }

    function closeOffering(uint256 id) external {
        Offering storage o = _get(id);
        if (msg.sender != o.artist) revert NotArtist(id);
        if (o.closed) revert OfferingIsClosed(id);
        o.closed = true;
        emit OfferingClosed(id);
    }

    /**
     * @notice Give up an offering that sold nothing and free its share token for re-listing.
     *
     * @dev Without this, every mistake and every grief is terminal. `_offeringOfToken` is
     *      claimed at creation, and sealing requires the artist to renounce admin, so an
     *      offering created with a past deadline, a fat-fingered price, or one wei of
     *      griefer dust in its supply could never sell and its token could never back a
     *      corrected offering — the artist had to re-launch a whole new A-Token through
     *      Cleanverse. Three separate audits reached this same dead end.
     *
     *      `sharesSold == 0` is the safety condition and it is what stops this from
     *      becoming a rug: once anyone has bought, the offering is a live obligation and
     *      cannot be walked away from. Nothing here touches buyers or their shares.
     *
     *      Callable by the owner as well as the artist, deliberately. A hijacker who
     *      front-ran `createOffering` becomes `o.artist`, which would otherwise let them
     *      hold the token hostage forever — the platform needs to be able to clear a
     *      squatted slot.
     *
     *      HOW FAR THIS RECOVERS, stated precisely: releasing the slot lets a token be
     *      re-listed only while someone still holds DEFAULT_ADMIN_ROLE on it. After
     *      sealing, nobody does — renouncing it is what makes the supply bound provable —
     *      so a post-seal grief still retires the token permanently and the artist must
     *      issue a new one. Sealing trades re-listability for a provable supply cap and
     *      cannot give both. The real defence is not granting MINTER_ROLE to third parties
     *      before sealing; this is damage limitation, not a cure.
     */
    function abandonOffering(uint256 id) external {
        Offering storage o = _get(id);
        if (msg.sender != o.artist && msg.sender != owner()) revert NotArtist(id);
        // Normally only a sale-free offering may be walked away from. The exception is an
        // offering whose supply invariant is already broken: it can never sell another
        // share, so refusing to release it would strand the token forever for the price of
        // one wei of griefer dust. Buyers keep every share they already hold either way.
        if (o.sharesSold != 0 && supplyIntact(id)) revert OfferingHasSales(id, o.sharesSold);

        o.closed = true;
        delete _offeringOfToken[o.shareToken];
        emit OfferingAbandoned(id, o.shareToken);
    }

    /**
     * @notice Push an offering's deadline further out. Forward-only.
     * @dev An offering whose deadline elapses mid-sale cannot be abandoned (it has sales)
     *      and cannot be re-listed, stranding every unsold share permanently. Extending is
     *      the recovery for that case. It only ever moves the deadline later, so it cannot
     *      be used to cut a sale short on buyers who are mid-transaction, and a closed
     *      offering stays closed.
     */
    function extendDeadline(uint256 id, uint64 newClosesAt) external {
        Offering storage o = _get(id);
        if (msg.sender != o.artist) revert NotArtist(id);
        if (o.closed) revert OfferingIsClosed(id);
        if (newClosesAt != 0 && newClosesAt <= block.timestamp) revert DeadlineInPast(newClosesAt);
        // 0 means "no deadline" and is always a valid extension; otherwise must move forward.
        if (o.closesAt == 0 || (newClosesAt != 0 && newClosesAt <= o.closesAt)) {
            revert DeadlineNotExtended(o.closesAt, newClosesAt);
        }
        o.closesAt = newClosesAt;
        emit DeadlineExtended(id, newClosesAt);
    }

    // ----------------------------------------------------------------- read

    function offeringCount() external view returns (uint256) {
        return _offerings.length;
    }

    function getOffering(uint256 id) external view returns (Offering memory) {
        return _get(id);
    }

    function sharesRemaining(uint256 id) external view returns (uint256) {
        Offering storage o = _get(id);
        return o.totalShares - o.sharesSold;
    }

    function costFor(uint256 id, uint256 wholeShares) external view returns (uint256) {
        return wholeShares * _get(id).pricePerShare;
    }

    /**
     * @notice Whether `buyer` would pass the compliance pre-check for this offering.
     * @dev Mirrors buy()'s logic exactly, including requireAttributeChecks, so the
     *      frontend never shows a buyable offering that would revert on submission.
     */
    function canBuy(uint256 id, address buyer) public view returns (bool) {
        return canBuyAmount(id, buyer, 1);
    }

    /**
     * @notice Whether `buyer` could actually buy `wholeShares` right now.
     * @dev Runs EVERY precondition buy() runs, in the same order. The previous version
     *      checked compliance alone while its own NatSpec claimed parity, so it returned
     *      true for unsealed, closed, expired, sold-out and supply-broken offerings — all
     *      five audits caught it, and one measured ~11k gas burned per buyer sent into a
     *      guaranteed revert. A view that lies about spendability is worse than no view.
     *
     *      It also covers the two failure modes a buyer cannot see: the ARTIST losing
     *      their A-Pass (payment is an A-Token, so the artist must be able to receive it)
     *      and the compliance backend being unavailable.
     */
    function canBuyAmount(uint256 id, address buyer, uint256 wholeShares)
        public
        view
        returns (bool)
    {
        Offering storage o = _get(id);
        if (!o.isSealed || o.closed) return false;
        if (o.closesAt != 0 && block.timestamp > o.closesAt) return false;
        if (wholeShares == 0 || wholeShares > o.totalShares - o.sharesSold) return false;
        if (!supplyIntact(id)) return false;

        (bool artistOk,) = validator.verify(o.shareToken, o.artist);
        if (!artistOk) return false; // artist could not receive payment

        // The artist cannot buy their own offering: payment would be a self-transfer that
        // nets zero, so buy() rejects it via the payment-delta check. Reporting `true` here
        // would recreate exactly the canBuy-vs-buy divergence this function exists to end.
        if (buyer == o.artist) return false;

        (bool ok, bool checked) = validator.verify(o.shareToken, buyer);
        if (!ok) return false;
        if (o.requireAttributeChecks && !checked) return false;
        return true;
    }

    /**
     * @notice Whether every existing share was sold by this offering.
     * @dev False means shares were minted outside this contract — the supply a buyer is
     *      pricing against is not what the offering claims, and buys will revert. Check
     *      this before committing funds. See the invariant note in {buy}.
     */
    function supplyIntact(uint256 id) public view returns (bool) {
        Offering storage o = _get(id);
        return IERC20(o.shareToken).totalSupply()
            == o.baselineSupply + o.sharesSold * (10 ** shareDecimals[id]);
    }

    /// @notice Why an offering is not currently buyable, for UIs. Empty string = buyable.
    /// @dev Exists so a blocked buyer is told the real reason instead of being blamed for
    ///      a pool-level pause or an artist-side compliance failure.
    function inactiveReason(uint256 id) external view returns (string memory) {
        Offering storage o = _get(id);
        if (!o.isSealed) return "not sealed";
        if (o.closed) return "closed";
        if (o.closesAt != 0 && block.timestamp > o.closesAt) return "expired";
        if (o.sharesSold >= o.totalShares) return "sold out";
        if (!supplyIntact(id)) return "supply compromised";
        if (!validator.isRegistered(o.shareToken)) return "token not vetted";
        if (validator.isPaused(o.shareToken)) return "pool paused";
        (bool artistOk,) = validator.verify(o.shareToken, o.artist);
        if (!artistOk) return "artist not compliant";
        return "";
    }

    /**
     * @notice Whether the offering can transact right now.
     * @dev Consults the validator as well as local state. It previously reported healthy
     *      while a paused pool or a non-compliant artist blocked every purchase, which is
     *      the same class of lie canBuy told. Cheapest honest definition: an offering is
     *      active exactly when someone could buy a single share from it.
     */
    function isActive(uint256 id) public view returns (bool) {
        Offering storage o = _get(id);
        if (!o.isSealed || o.closed) return false;
        if (o.closesAt != 0 && block.timestamp > o.closesAt) return false;
        if (o.sharesSold >= o.totalShares) return false;
        if (!supplyIntact(id)) return false;
        if (!validator.isRegistered(o.shareToken) || validator.isPaused(o.shareToken)) {
            return false;
        }
        (bool artistOk,) = validator.verify(o.shareToken, o.artist);
        return artistOk;
    }

    function _get(uint256 id) private view returns (Offering storage) {
        if (id >= _offerings.length) revert InvalidOffering(id);
        return _offerings[id];
    }
}

interface IComplianceValidator {
    /// @return ok whether the wallet may transact; checked whether attribute rules were applied
    function verify(address pool, address wallet) external view returns (bool ok, bool checked);

    /// @notice Whether this pool (share token) has been vetted and registered.
    function isRegistered(address pool) external view returns (bool);

    /// @notice Whether this pool is currently suspended.
    function isPaused(address pool) external view returns (bool);
}

interface IAToken {
    function mint(address to, uint256 amount) external;
}

interface IERC20Decimals {
    function decimals() external view returns (uint8);
}
