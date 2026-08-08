// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ShareOffering} from "../src/ShareOffering.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * Mocks mirror the REAL behaviour observed on Monad testnet against Cleanverse's
 * contracts, not idealised versions:
 *   - MockAToken reverts with NoAPass(address) on mint/transfer to a wallet without an
 *     A-Pass, matching selector 0xa6725971 seen on-chain.
 *   - MINTER_ROLE is plain keccak("MINTER_ROLE") and the deployer holds
 *     DEFAULT_ADMIN_ROLE, matching what /atoken/launch actually grants.
 */
error NoAPass(address account);

contract MockAPassRegistry {
    mapping(address => uint256) public balanceOf;

    function issue(address to) external {
        balanceOf[to] = 1;
    }

    function revoke(address to) external {
        balanceOf[to] = 0;
    }
}

contract MockAToken is ERC20, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    MockAPassRegistry public immutable apass;

    constructor(MockAPassRegistry r) ERC20("Clearwave Royalty Share", "CWRS") {
        apass = r;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        if (apass.balanceOf(to) == 0) revert NoAPass(to);
        _mint(to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal override {
        if (apass.balanceOf(to) == 0) revert NoAPass(to);
        super._transfer(from, to, amount);
    }
}

/// aUSDC is itself an A-Token, so the payment leg is gated too.
contract MockAUSDC is ERC20 {
    MockAPassRegistry public immutable apass;

    constructor(MockAPassRegistry r) ERC20("Cleanverse aUSDC", "aUSDC") {
        apass = r;
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mintTo(address to, uint256 a) external {
        _mint(to, a);
    }

    function _transfer(address from, address to, uint256 amount) internal override {
        if (apass.balanceOf(to) == 0) revert NoAPass(to);
        super._transfer(from, to, amount);
    }
}

contract MockValidator {
    MockAPassRegistry public immutable apass;
    bool public forceFalse;
    /// Mirrors the real validator: false until an attribute oracle is configured.
    bool public attributesChecked;

    constructor(MockAPassRegistry r) {
        apass = r;
    }

    function setForceFalse(bool v) external {
        forceFalse = v;
    }

    function setAttributesChecked(bool v) external {
        attributesChecked = v;
    }

    mapping(address => bool) public registered;

    function setRegistered(address pool, bool v) external {
        registered[pool] = v;
    }

    function isRegistered(address pool) external view returns (bool) {
        return registered[pool];
    }

    mapping(address => bool) public pausedPool;

    function setPausedPool(address pool, bool v) external {
        pausedPool[pool] = v;
    }

    function isPaused(address pool) external view returns (bool) {
        return pausedPool[pool];
    }

    function verify(address, address wallet) external view returns (bool, bool) {
        if (forceFalse) return (false, attributesChecked);
        return (apass.balanceOf(wallet) > 0, attributesChecked);
    }
}

contract ShareOfferingTest is Test {
    MockAPassRegistry apass;
    MockAToken share;
    MockAUSDC usdc;
    MockValidator validator;
    ShareOffering offering;

    address artist = address(0xA1);
    address investor = address(0xB1);
    address outsider = address(0xC1);

    uint256 constant PRICE = 5_000_000; // 5 aUSDC per whole share
    uint256 constant TOTAL = 1_000;

    function setUp() public {
        apass = new MockAPassRegistry();
        usdc = new MockAUSDC(apass);
        validator = new MockValidator(apass);

        // Artist issues the share A-Token, so the artist is its DEFAULT_ADMIN.
        vm.prank(artist);
        share = new MockAToken(apass);

        offering = new ShareOffering(address(usdc), address(validator), address(this));

        // Cleanverse-verified parties.
        apass.issue(artist);
        apass.issue(investor);
        // `outsider` deliberately has no A-Pass.

        // Read the role BEFORE pranking — an external call would otherwise consume the prank.
        bytes32 minter = share.MINTER_ROLE();
        vm.prank(artist);
        share.grantRole(minter, address(offering));

        // The platform vets the share token by registering it as a validator pool.
        validator.setRegistered(address(share), true);

        // Must cover buying out the whole offering: TOTAL * PRICE = 5,000 aUSDC.
        usdc.mintTo(investor, 1_000_000e6);
        usdc.mintTo(outsider, 1_000_000e6);
    }

    /// Create WITHOUT sealing — for tests that exercise the unsealed state.
    function _createUnsealed() internal returns (uint256 id) {
        vm.prank(artist);
        id = offering.createOffering(address(share), PRICE, TOTAL, 0, false);
    }

    /// The full artist flow: create, renounce mint rights, seal. Sales need all three.
    function _create() internal returns (uint256 id) {
        id = _createUnsealed();
        _renounceAndSeal(id);
    }

    function _renounceAndSeal(uint256 id) internal {
        vm.startPrank(artist);
        share.renounceRole(share.DEFAULT_ADMIN_ROLE(), artist);
        offering.sealOffering(id);
        vm.stopPrank();
    }

    // ------------------------------------------------------------ creation

    function test_createOffering_setsFields() public {
        uint256 id = _create();
        ShareOffering.Offering memory o = offering.getOffering(id);
        assertEq(o.artist, artist);
        assertEq(o.shareToken, address(share));
        assertEq(o.pricePerShare, PRICE);
        assertEq(o.totalShares, TOTAL);
        assertEq(o.sharesSold, 0);
        assertTrue(offering.isActive(id));
        assertEq(offering.shareDecimals(id), 6);
    }

    function test_createOffering_revertsIfNotTokenAdmin() public {
        vm.prank(investor);
        vm.expectRevert(
            abi.encodeWithSelector(ShareOffering.NotTokenAdmin.selector, address(share))
        );
        offering.createOffering(address(share), PRICE, TOTAL, 0, false);
    }

    function test_createOffering_revertsIfOfferingLacksMinterRole() public {
        vm.prank(artist);
        MockAToken other = new MockAToken(apass);
        validator.setRegistered(address(other), true); // vetted, but no MINTER_ROLE granted
        vm.prank(artist);
        vm.expectRevert(
            abi.encodeWithSelector(ShareOffering.MinterRoleMissing.selector, address(other))
        );
        offering.createOffering(address(other), PRICE, TOTAL, 0, false);
    }

    function test_createOffering_rejectsZeroPriceAndAmount() public {
        vm.startPrank(artist);
        vm.expectRevert(ShareOffering.BadPrice.selector);
        offering.createOffering(address(share), 0, TOTAL, 0, false);
        vm.expectRevert(ShareOffering.ZeroAmount.selector);
        offering.createOffering(address(share), PRICE, 0, 0, false);
        vm.stopPrank();
    }

    // ----------------------------------------------------------------- buy

    function test_buy_happyPath_paysArtistAndMintsShares() public {
        uint256 id = _create();
        vm.startPrank(investor);
        usdc.approve(address(offering), type(uint256).max);
        offering.buy(id, 10);
        vm.stopPrank();

        assertEq(usdc.balanceOf(artist), 10 * PRICE, "artist paid directly");
        assertEq(share.balanceOf(investor), 10 * 1e6, "shares minted at token decimals");
        assertEq(offering.sharesRemaining(id), TOTAL - 10);
        assertEq(usdc.balanceOf(address(offering)), 0, "contract must never custody");
        assertEq(share.balanceOf(address(offering)), 0);
    }

    /// The whole point of the project: a buyer without an A-Pass cannot acquire the security.
    function test_buy_revertsForBuyerWithoutAPass() public {
        uint256 id = _create();
        vm.startPrank(outsider);
        usdc.approve(address(offering), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(ShareOffering.BuyerNotCompliant.selector, outsider)
        );
        offering.buy(id, 1);
        vm.stopPrank();
    }

    /// Even with our validator bypassed, the A-Token itself must still refuse.
    function test_buy_aTokenStillBlocksWhenValidatorDisabled() public {
        uint256 id = _create();
        validator.setForceFalse(false);
        offering.setValidator(address(new AlwaysOkValidator(address(share)))); // bypass our pre-check
        vm.startPrank(outsider);
        usdc.approve(address(offering), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(NoAPass.selector, outsider));
        offering.buy(id, 1);
        vm.stopPrank();
    }

    /// A revoked A-Pass must stop further purchases.
    function test_buy_revertsAfterAPassRevoked() public {
        uint256 id = _create();
        vm.startPrank(investor);
        usdc.approve(address(offering), type(uint256).max);
        offering.buy(id, 1);
        vm.stopPrank();

        apass.revoke(investor);

        vm.prank(investor);
        vm.expectRevert(
            abi.encodeWithSelector(ShareOffering.BuyerNotCompliant.selector, investor)
        );
        offering.buy(id, 1);
    }

    function test_buy_cannotExceedRemaining() public {
        uint256 id = _create();
        vm.startPrank(investor);
        usdc.approve(address(offering), type(uint256).max);
        offering.buy(id, TOTAL - 5);
        vm.expectRevert(abi.encodeWithSelector(ShareOffering.SoldOut.selector, id, 5));
        offering.buy(id, 6);
        offering.buy(id, 5); // exactly the remainder is fine
        vm.stopPrank();
        assertFalse(offering.isActive(id), "sold out");
        assertEq(offering.sharesRemaining(id), 0);
    }

    function test_buy_revertsAfterClose() public {
        uint256 id = _create();
        vm.prank(artist);
        offering.closeOffering(id);
        vm.startPrank(investor);
        usdc.approve(address(offering), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(ShareOffering.OfferingIsClosed.selector, id));
        offering.buy(id, 1);
        vm.stopPrank();
    }

    function test_buy_revertsAfterDeadline() public {
        vm.prank(artist);
        uint256 id = offering.createOffering(address(share), PRICE, TOTAL, uint64(block.timestamp + 1 days), false);
        _renounceAndSeal(id);
        vm.warp(block.timestamp + 2 days);
        vm.startPrank(investor);
        usdc.approve(address(offering), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(ShareOffering.OfferingExpired.selector, id));
        offering.buy(id, 1);
        vm.stopPrank();
    }

    function test_buy_revertsOnZeroShares() public {
        uint256 id = _create();
        vm.prank(investor);
        vm.expectRevert(ShareOffering.ZeroAmount.selector);
        offering.buy(id, 0);
    }

    function test_buy_revertsWithoutApproval() public {
        uint256 id = _create();
        vm.prank(investor);
        vm.expectRevert();
        offering.buy(id, 1);
    }

    // --------------------------------------------------------------- admin

    function test_closeOffering_onlyArtist() public {
        uint256 id = _create();
        vm.prank(investor);
        vm.expectRevert(abi.encodeWithSelector(ShareOffering.NotArtist.selector, id));
        offering.closeOffering(id);
    }

    function test_getOffering_revertsOnBadId() public {
        vm.expectRevert(abi.encodeWithSelector(ShareOffering.InvalidOffering.selector, 42));
        offering.getOffering(42);
    }

    function test_canBuy_reflectsAPassState() public {
        uint256 id = _create();
        assertTrue(offering.canBuy(id, investor));
        assertFalse(offering.canBuy(id, outsider));
    }

    // --------------------------------------------------------------- fuzz

    function testFuzz_costIsLinearAndSharesMatch(uint96 n) public {
        uint256 wholeShares = bound(uint256(n), 1, TOTAL);
        uint256 id = _create();
        vm.startPrank(investor);
        usdc.approve(address(offering), type(uint256).max);
        uint256 quoted = offering.costFor(id, wholeShares);
        offering.buy(id, wholeShares);
        vm.stopPrank();
        assertEq(quoted, wholeShares * PRICE);
        assertEq(usdc.balanceOf(artist), quoted);
        assertEq(share.balanceOf(investor), wholeShares * 1e6);
    }
}

/**
 * Regression tests for the three audit fixes. Each asserts the vulnerability is closed,
 * not merely that the happy path still works.
 */
contract ShareOfferingAuditFixesTest is ShareOfferingTest {
    // ---- FIX 1: dilution ----

    /// The original critical finding: artist self-mints and dilutes buyers to dust.
    function test_fix1_sealBlocksTheDilutionPath() public {
        uint256 id = _createUnsealed();
        // Artist still admin -> cannot seal, so cannot sell.
        vm.prank(artist);
        vm.expectRevert(
            abi.encodeWithSelector(ShareOffering.ArtistRetainsMintRights.selector, address(share))
        );
        offering.sealOffering(id);

        vm.prank(investor);
        vm.expectRevert(abi.encodeWithSelector(ShareOffering.OfferingNotSealed.selector, id));
        offering.buy(id, 1);
    }

    /// Once sealed, the artist provably cannot regain mint rights.
    function test_fix1_afterSealArtistCannotMintOrRegrant() public {
        uint256 id = _create();
        bytes32 minter = share.MINTER_ROLE();

        vm.prank(artist);
        vm.expectRevert(); // no DEFAULT_ADMIN_ROLE any more
        share.grantRole(minter, artist);

        vm.prank(artist);
        vm.expectRevert(); // and no MINTER_ROLE either
        share.mint(artist, 1);

        // Supply can never exceed what the offering itself sells.
        vm.startPrank(investor);
        usdc.approve(address(offering), type(uint256).max);
        offering.buy(id, TOTAL);
        vm.stopPrank();
        assertEq(share.totalSupply(), TOTAL * 1e6, "supply is exactly totalShares");
        assertEq(share.balanceOf(investor), TOTAL * 1e6, "investor holds 100%, undilutable");
    }

    /**
     * A pre-minted token now SEALS and records the pre-existing float as a baseline.
     * This replaced a totalSupply == 0 requirement: because A-Tokens cannot burn, that rule
     * let anyone with mint rights brick a token permanently with one wei. Disclosure beats
     * a brick — the float is on-chain and readable before anyone buys.
     */
    function test_fix1_preMintedSupplyIsRecordedAsBaseline() public {
        uint256 id = _createUnsealed();
        bytes32 minter = share.MINTER_ROLE();
        vm.startPrank(artist);
        share.grantRole(minter, artist);
        share.mint(artist, 1); // artist holds an A-Pass so this succeeds
        share.renounceRole(minter, artist);
        share.renounceRole(share.DEFAULT_ADMIN_ROLE(), artist);
        offering.sealOffering(id);
        vm.stopPrank();

        assertEq(offering.baselineSupplyOf(id), 1, "pre-existing float disclosed");
        assertTrue(offering.supplyIntact(id), "baseline is the reference, not zero");

        vm.startPrank(investor);
        usdc.approve(address(offering), type(uint256).max);
        offering.buy(id, 1);
        vm.stopPrank();
        assertEq(share.balanceOf(investor), 1e6, "sale proceeds normally over the baseline");
    }

    function test_fix1_sealIsOnlyArtistAndOnlyOnce() public {
        // A second offering needs its OWN token — one offering per share token — and both
        // must be created while the artist still holds admin, since _create() renounces it.
        vm.prank(artist);
        MockAToken share2 = new MockAToken(apass);
        validator.setRegistered(address(share2), true);
        bytes32 minter2 = share2.MINTER_ROLE();
        vm.prank(artist);
        share2.grantRole(minter2, address(offering));
        vm.prank(artist);
        uint256 id2 = offering.createOffering(address(share2), PRICE, TOTAL, 0, false);

        uint256 id = _create();

        vm.prank(artist);
        vm.expectRevert(abi.encodeWithSelector(ShareOffering.AlreadySealed.selector, id));
        offering.sealOffering(id);

        vm.prank(investor);
        vm.expectRevert(abi.encodeWithSelector(ShareOffering.NotArtist.selector, id2));
        offering.sealOffering(id2);
    }

    function test_fix1_unsealedOfferingIsNotActive() public {
        uint256 id = _createUnsealed();
        assertFalse(offering.isActive(id), "must not advertise as tradeable before sealing");
    }

    // ---- FIX 3: the `checked` flag is honoured ----

    function test_fix3_requireAttributeChecks_blocksPossessionOnlyAnswer() public {
        vm.prank(artist);
        uint256 id = offering.createOffering(address(share), PRICE, TOTAL, 0, true);
        _renounceAndSeal(id);

        validator.setAttributesChecked(false); // oracle absent, as in production today
        vm.startPrank(investor);
        usdc.approve(address(offering), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(ShareOffering.AttributeChecksUnavailable.selector, investor)
        );
        offering.buy(id, 1);
        vm.stopPrank();
        assertFalse(offering.canBuy(id, investor), "canBuy must agree with buy");
    }

    function test_fix3_requireAttributeChecks_passesOnceOracleExists() public {
        vm.prank(artist);
        uint256 id = offering.createOffering(address(share), PRICE, TOTAL, 0, true);
        _renounceAndSeal(id);

        validator.setAttributesChecked(true);
        assertTrue(offering.canBuy(id, investor));
        vm.startPrank(investor);
        usdc.approve(address(offering), type(uint256).max);
        offering.buy(id, 1);
        vm.stopPrank();
        assertEq(share.balanceOf(investor), 1e6);
    }

    function test_fix3_noValidatorCannotSatisfyAttributeRequirement() public {
        vm.prank(artist);
        uint256 id = offering.createOffering(address(share), PRICE, TOTAL, 0, true);
        _renounceAndSeal(id);
        offering.setValidator(address(new AlwaysOkNoAttrValidator(address(share))));

        assertFalse(offering.canBuy(id, investor));
        vm.startPrank(investor);
        usdc.approve(address(offering), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(ShareOffering.AttributeChecksUnavailable.selector, investor)
        );
        offering.buy(id, 1);
        vm.stopPrank();
    }
}

/// Passes everything, including attribute checks — used to prove the A-Token is the
/// final authority even when our own pre-check is fully permissive.
contract AlwaysOkValidator {
    address immutable pool;
    constructor(address p) { pool = p; }
    function isRegistered(address) external pure returns (bool) { return true; }
    function isPaused(address) external pure returns (bool) { return false; }
    function verify(address, address) external pure returns (bool, bool) { return (true, true); }
}

/// Permissive on eligibility but reports attributes as UNCHECKED.
contract AlwaysOkNoAttrValidator {
    address immutable pool;
    constructor(address p) { pool = p; }
    function isRegistered(address) external pure returns (bool) { return true; }
    function isPaused(address) external pure returns (bool) { return false; }
    function verify(address, address) external pure returns (bool, bool) { return (true, false); }
}

/// Regression tests for audit-3 findings: counterfeit share tokens and duplicate offerings.
contract ShareOfferingProvenanceTest is ShareOfferingTest {
    function test_unvettedTokenCannotBackAnOffering() public {
        vm.prank(artist);
        MockAToken counterfeit = new MockAToken(apass);
        bytes32 m = counterfeit.MINTER_ROLE();
        vm.prank(artist);
        counterfeit.grantRole(m, address(offering));
        // Never registered with the validator -> never vetted.
        vm.prank(artist);
        vm.expectRevert(
            abi.encodeWithSelector(ShareOffering.ShareTokenNotVetted.selector, address(counterfeit))
        );
        offering.createOffering(address(counterfeit), PRICE, TOTAL, 0, false);
    }

    function test_oneOfferingPerShareToken() public {
        uint256 id = _createUnsealed();
        vm.prank(artist);
        vm.expectRevert(
            abi.encodeWithSelector(ShareOffering.TokenAlreadyOffered.selector, address(share), id)
        );
        offering.createOffering(address(share), PRICE, TOTAL, 0, false);
    }

    function test_validatorCannotBeUnset() public {
        vm.expectRevert(ShareOffering.ZeroAddress.selector);
        offering.setValidator(address(0));
    }

    function test_constructorRejectsZeroValidator() public {
        vm.expectRevert(ShareOffering.ZeroAddress.selector);
        new ShareOffering(address(usdc), address(0), address(this));
    }
}
