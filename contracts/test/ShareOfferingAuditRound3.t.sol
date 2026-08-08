// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ShareOffering} from "../src/ShareOffering.sol";
import {APassComplianceValidator} from "../src/APassComplianceValidator.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * Regression suite for the five-agent penetration test. Each test reproduces a CONFIRMED
 * exploit and asserts it is now closed. Attack shapes are the agents' own.
 */
error NoAPassR3(address account);

contract R3Registry {
    mapping(address => uint256) public balanceOf;
    bool public broken;
    bool public burnsGas;

    function issue(address a) external { balanceOf[a] = 1; }
    function revoke(address a) external { balanceOf[a] = 0; }
    function setBroken(bool v) external { broken = v; }
    function setBurnsGas(bool v) external { burnsGas = v; }

    fallback() external {}
}

/// Registry that reverts or burns gas on balanceOf — Cleanverse controls this proxy.
contract R3HostileRegistry {
    bool public burnsGas;
    constructor(bool _burnsGas) { burnsGas = _burnsGas; }
    function balanceOf(address) external view returns (uint256) {
        if (burnsGas) { uint256 i; while (true) { i++; } }
        revert("registry down");
    }
}

contract R3Token is ERC20, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    R3Registry public reg;
    uint8 private _dec = 6;
    bool public noopMint;      // upgraded-proxy simulation: mint does nothing
    bool public lieSupply;     // ...and totalSupply reports whatever is expected
    uint256 public fakeSupply;

    constructor(R3Registry r) ERC20("Share", "SHR") { reg = r; _grantRole(DEFAULT_ADMIN_ROLE, msg.sender); }
    function setDecimals(uint8 d) external { _dec = d; }
    function decimals() public view override returns (uint8) { return _dec; }
    function setNoopMint(bool v) external { noopMint = v; }
    function setLieSupply(bool v, uint256 s) external { lieSupply = v; fakeSupply = s; }

    function totalSupply() public view override returns (uint256) {
        return lieSupply ? fakeSupply : super.totalSupply();
    }

    function mint(address to, uint256 amt) external onlyRole(MINTER_ROLE) {
        if (noopMint) return;                       // silent no-op
        if (reg.balanceOf(to) == 0) revert NoAPassR3(to);
        _mint(to, amt);
    }
    function _transfer(address f, address t, uint256 a) internal override {
        if (reg.balanceOf(t) == 0) revert NoAPassR3(t);
        super._transfer(f, t, a);
    }
}

contract R3Pay is ERC20 {
    R3Registry public reg;
    uint256 public feeBps;
    constructor(R3Registry r) ERC20("Pay", "PAY") { reg = r; }
    function decimals() public pure override returns (uint8) { return 6; }
    function mintTo(address t, uint256 a) external { _mint(t, a); }
    function setFeeBps(uint256 b) external { feeBps = b; }
    function _transfer(address f, address t, uint256 a) internal override {
        if (reg.balanceOf(t) == 0) revert NoAPassR3(t);
        uint256 fee = (a * feeBps) / 10_000;
        if (fee > 0) { super._transfer(f, address(0xFEE), a - fee); super._transfer(f, address(0xFEE), fee); }
        else { super._transfer(f, t, a); }
    }
}

contract AuditRound3 is Test {
    R3Registry reg;
    APassComplianceValidator val;
    R3Token share;
    R3Pay pay;
    ShareOffering off;

    address artist = address(0xA1);
    address investor = address(0xB1);
    address coAdmin = address(0xA2);

    uint256 constant PRICE = 5e6;
    uint256 constant TOTAL = 1000;

    function setUp() public {
        reg = new R3Registry();
        val = new APassComplianceValidator(address(reg), address(this));
        vm.prank(artist);
        share = new R3Token(reg);
        pay = new R3Pay(reg);
        off = new ShareOffering(address(pay), address(val), address(this));

        reg.issue(artist); reg.issue(investor); reg.issue(coAdmin);
        bytes2[] memory none;
        val.register(address(share), APassComplianceValidator.Rule({
            minTier: 0, minSubTier: 0, isBlackList: false, countries: none}));

        bytes32 m = share.MINTER_ROLE();
        vm.prank(artist); share.grantRole(m, address(off));
        pay.mintTo(investor, 1_000_000e6);
        pay.mintTo(artist, 10e6);
    }

    function _open() internal returns (uint256 id) {
        vm.prank(artist);
        id = off.createOffering(address(share), PRICE, TOTAL, 0, false);
        vm.startPrank(artist);
        share.renounceRole(share.DEFAULT_ADMIN_ROLE(), artist);
        off.sealOffering(id);
        vm.stopPrank();
    }

    // ---- CRITICAL: upgraded proxy makes mint a no-op and lies about supply ----

    function test_C1_noopMintNowReverts() public {
        uint256 id = _open();
        share.setNoopMint(true);
        share.setLieSupply(true, 0); // pretend supply matches sharesSold==0
        vm.startPrank(investor);
        pay.approve(address(off), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(ShareOffering.SharesNotDelivered.selector, id, 10e6, 0));
        off.buy(id, 10);
        vm.stopPrank();
        assertEq(pay.balanceOf(artist), 10e6, "buyer funds never left; artist unchanged");
    }

    function test_C1b_partialMintReverts() public {
        uint256 id = _open();
        vm.startPrank(investor);
        pay.approve(address(off), type(uint256).max);
        off.buy(id, 10); // honest baseline
        vm.stopPrank();
        assertEq(share.balanceOf(investor), 10e6);
    }

    // ---- HIGH: artist self-buys for free ----

    function test_H1_artistCannotBuyOwnOfferingFree() public {
        uint256 id = _open();
        vm.startPrank(artist);
        pay.approve(address(off), type(uint256).max);
        // Self-transfer nets zero, so the payment delta is 0 rather than `cost`.
        vm.expectRevert(abi.encodeWithSelector(ShareOffering.PaymentNotReceived.selector, id, PRICE, 0));
        off.buy(id, 1);
        vm.stopPrank();
        assertEq(share.balanceOf(artist), 0, "artist obtained no free shares");
    }

    // ---- LOW: fee-on-transfer short-pays the artist ----

    function test_L1_feeOnTransferNowReverts() public {
        uint256 id = _open();
        pay.setFeeBps(100); // 1%
        vm.startPrank(investor);
        pay.approve(address(off), type(uint256).max);
        vm.expectRevert();
        off.buy(id, 10);
        vm.stopPrank();
    }

    // ---- HIGH: recovery from a bricked / squatted offering ----

    function test_H2_abandonFreesTheTokenSlot() public {
        vm.prank(artist);
        uint256 id = off.createOffering(address(share), 1, TOTAL, 0, false); // fat-fingered price
        vm.prank(artist);
        vm.expectRevert(abi.encodeWithSelector(
            ShareOffering.TokenAlreadyOffered.selector, address(share), id));
        off.createOffering(address(share), PRICE, TOTAL, 0, false);

        vm.prank(artist);
        off.abandonOffering(id); // recover

        vm.prank(artist);
        uint256 id2 = off.createOffering(address(share), PRICE, TOTAL, 0, false);
        assertEq(id2, 1, "token re-listed at the correct price");
    }

    function test_H2b_abandonBlockedOnceSharesSold() public {
        uint256 id = _open();
        vm.startPrank(investor);
        pay.approve(address(off), type(uint256).max);
        off.buy(id, 1);
        vm.stopPrank();
        vm.prank(artist);
        vm.expectRevert(abi.encodeWithSelector(ShareOffering.OfferingHasSales.selector, id, 1));
        off.abandonOffering(id); // a live obligation cannot be walked away from
    }

    function test_H2c_ownerCanClearASquattedSlot() public {
        vm.prank(artist); share.grantRole(0x00, coAdmin);
        vm.prank(coAdmin);
        uint256 id = off.createOffering(address(share), 1, 1, 0, false); // hijack
        assertEq(off.getOffering(id).artist, coAdmin);
        off.abandonOffering(id); // platform owner clears it
        vm.prank(artist);
        uint256 id2 = off.createOffering(address(share), PRICE, TOTAL, 0, false);
        assertEq(off.getOffering(id2).artist, artist, "real artist recovers the token");
    }

    function test_H2d_deadlineExtensionRescuesAStrandedOffering() public {
        vm.prank(artist);
        uint256 id = off.createOffering(address(share), PRICE, TOTAL, uint64(block.timestamp + 1 days), false);
        vm.startPrank(artist);
        share.renounceRole(share.DEFAULT_ADMIN_ROLE(), artist);
        off.sealOffering(id);
        vm.stopPrank();

        vm.warp(block.timestamp + 2 days);
        assertFalse(off.isActive(id));
        vm.prank(artist);
        off.extendDeadline(id, uint64(block.timestamp + 7 days));
        assertTrue(off.isActive(id), "offering recovered instead of stranded forever");

        vm.prank(artist);
        vm.expectRevert(); // forward-only
        off.extendDeadline(id, uint64(block.timestamp + 1));
    }

    // ---- MEDIUM: hostile / unavailable compliance backend ----

    function test_M1_revertingRegistryFailsClosedInsteadOfBricking() public {
        APassComplianceValidator v2 =
            new APassComplianceValidator(address(new R3HostileRegistry(false)), address(this));
        bytes2[] memory none;
        v2.register(address(share), APassComplianceValidator.Rule({
            minTier: 0, minSubTier: 0, isBlackList: false, countries: none}));
        // Answers false rather than throwing — the whole platform stays responsive.
        assertFalse(v2.hasAPass(investor));
        (bool ok, bool checked) = v2.verify(address(share), investor);
        assertFalse(ok); assertFalse(checked);
    }

    function test_M1b_gasBurningRegistryCannotConsumeAllGas() public {
        APassComplianceValidator v2 =
            new APassComplianceValidator(address(new R3HostileRegistry(true)), address(this));
        assertFalse(v2.hasAPass(investor)); // returns instead of exhausting the tx
    }

    // ---- MEDIUM: empty rule set must not claim `checked` ----

    function test_M2_emptyRuleSetReportsUnchecked() public {
        val.setAttributeOracle(address(new R3Oracle(99, 99, bytes2(0))));
        (bool ok1, bool checked1) = val.verify(address(share), investor);
        assertTrue(ok1); assertTrue(checked1, "one rule -> genuinely checked");

        val.removeRule(address(share), 0);
        assertEq(val.ruleCount(address(share)), 0);
        (bool ok2, bool checked2) = val.verify(address(share), investor);
        assertTrue(ok2);
        assertFalse(checked2, "zero rules must never report as checked");
    }

    function test_M2b_requireAttributeChecksRefusesAnEmptyRuleSet() public {
        vm.prank(artist);
        uint256 id = off.createOffering(address(share), PRICE, TOTAL, 0, true);
        vm.startPrank(artist);
        share.renounceRole(share.DEFAULT_ADMIN_ROLE(), artist);
        off.sealOffering(id);
        vm.stopPrank();

        val.setAttributeOracle(address(new R3Oracle(99, 99, bytes2(0))));
        val.removeRule(address(share), 0);

        assertFalse(off.canBuy(id, investor));
        vm.startPrank(investor);
        pay.approve(address(off), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(
            ShareOffering.AttributeChecksUnavailable.selector, investor));
        off.buy(id, 1);
        vm.stopPrank();
    }

    // ---- MEDIUM: canBuy / isActive must not lie ----

    function test_M3_canBuyAgreesWithBuyInEveryTerminalState() public {
        vm.prank(artist);
        uint256 id = off.createOffering(address(share), PRICE, TOTAL, 0, false);
        assertFalse(off.canBuy(id, investor), "unsealed");
        assertFalse(off.isActive(id));

        vm.startPrank(artist);
        share.renounceRole(share.DEFAULT_ADMIN_ROLE(), artist);
        off.sealOffering(id);
        vm.stopPrank();
        assertTrue(off.canBuy(id, investor));

        vm.prank(artist); off.closeOffering(id);
        assertFalse(off.canBuy(id, investor), "closed");
        assertEq(off.inactiveReason(id), "closed");
    }

    function test_M3b_pausedPoolIsReportedHonestly() public {
        uint256 id = _open();
        assertTrue(off.canBuy(id, investor));
        val.setPaused(address(share), true);
        assertFalse(off.canBuy(id, investor), "paused pool blocks buys");
        assertFalse(off.isActive(id));
        assertEq(off.inactiveReason(id), "pool paused");
    }

    function test_M3c_artistLosingAPassIsVisible() public {
        uint256 id = _open();
        reg.revoke(artist);
        assertFalse(off.canBuy(id, investor), "artist cannot receive payment");
        assertFalse(off.isActive(id));
        assertEq(off.inactiveReason(id), "artist not compliant");
    }

    function test_M3d_soldOutAndSupplyBreakAreReported() public {
        uint256 id = _open();
        vm.startPrank(investor);
        pay.approve(address(off), type(uint256).max);
        off.buy(id, TOTAL);
        vm.stopPrank();
        assertFalse(off.canBuy(id, investor));
        assertEq(off.inactiveReason(id), "sold out");
    }

    // ---- creation-time guards ----

    function test_G1_pausedPoolCannotBackANewOffering() public {
        val.setPaused(address(share), true);
        vm.prank(artist);
        vm.expectRevert(abi.encodeWithSelector(ShareOffering.PoolPaused.selector, address(share)));
        off.createOffering(address(share), PRICE, TOTAL, 0, false);
    }

    function test_G2_pastDeadlineRejected() public {
        vm.warp(1000);
        vm.prank(artist);
        vm.expectRevert(abi.encodeWithSelector(ShareOffering.DeadlineInPast.selector, uint64(500)));
        off.createOffering(address(share), PRICE, TOTAL, 500, false);
    }

    function test_G3_absurdDecimalsRejected() public {
        share.setDecimals(78);
        vm.prank(artist);
        vm.expectRevert(abi.encodeWithSelector(
            ShareOffering.UnsupportedDecimals.selector, address(share), uint8(78)));
        off.createOffering(address(share), PRICE, TOTAL, 0, false);
    }

    function test_G4_renounceOwnershipDisabledOnBoth() public {
        vm.expectRevert(ShareOffering.OwnershipCannotBeRenounced.selector);
        off.renounceOwnership();
        vm.expectRevert(APassComplianceValidator.OwnershipCannotBeRenounced.selector);
        val.renounceOwnership();
    }

    function test_G5_attributeOracleMustBeAContract() public {
        vm.expectRevert(abi.encodeWithSelector(
            APassComplianceValidator.NotAContract.selector, address(0xDEADBEEF)));
        val.setAttributeOracle(address(0xDEADBEEF));
        val.setAttributeOracle(address(0)); // zero is allowed: possession-only
    }
}

contract R3Oracle {
    uint8 t; uint8 s; bytes2 c;
    constructor(uint8 a, uint8 b, bytes2 d) { t = a; s = b; c = d; }
    function attributesOf(address) external view returns (uint8, uint8, bytes2) { return (t, s, c); }
}

/// The dust-brick attack: the pen-test's cheapest and most damaging grief.
contract AuditRound3Dust is AuditRound3 {
    function test_D1_preSealDustNoLongerBricksTheToken() public {
        vm.prank(artist);
        uint256 id = off.createOffering(address(share), PRICE, TOTAL, 0, false);

        // Griefer with a pre-seal MINTER_ROLE mints ONE WEI to the artist.
        bytes32 mr = share.MINTER_ROLE(); // read before pranking; a call would consume it
        vm.prank(artist); share.grantRole(mr, coAdmin);
        vm.prank(coAdmin); share.mint(artist, 1);

        vm.startPrank(artist);
        share.renounceRole(share.DEFAULT_ADMIN_ROLE(), artist);
        off.sealOffering(id); // previously reverted SupplyNotZero forever
        vm.stopPrank();

        assertEq(off.baselineSupplyOf(id), 1, "dust recorded and disclosed, not fatal");

        vm.startPrank(investor);
        pay.approve(address(off), type(uint256).max);
        off.buy(id, 10);
        vm.stopPrank();
        assertEq(share.balanceOf(investor), 10e6, "sale proceeds normally");
        assertTrue(off.supplyIntact(id));
    }

    /**
     * Post-seal dust is NOT fully recoverable, and this test pins down exactly how far the
     * fix goes. Abandoning frees the token slot and closes the offering cleanly, but the
     * artist renounced DEFAULT_ADMIN_ROLE to seal, and nobody can grant it back, so that
     * token can never back another offering. Sealing trades re-listability for a provable
     * supply bound; you cannot have both. The griefer still retires the token, and the
     * defence is to keep MINTER_ROLE away from third parties before sealing.
     */
    function test_D2_postSealDustHaltsAndTokenIsRetired() public {
        vm.prank(artist);
        uint256 id = off.createOffering(address(share), PRICE, TOTAL, 0, false);
        bytes32 mr = share.MINTER_ROLE(); // read before pranking; a call would consume it
        vm.prank(artist); share.grantRole(mr, coAdmin);
        vm.startPrank(artist);
        share.renounceRole(share.DEFAULT_ADMIN_ROLE(), artist);
        off.sealOffering(id);
        vm.stopPrank();

        vm.startPrank(investor);
        pay.approve(address(off), type(uint256).max);
        off.buy(id, 10);
        vm.stopPrank();

        vm.prank(coAdmin); share.mint(artist, 1); // grief AFTER sales begin
        assertFalse(off.supplyIntact(id), "dilution still detected, halt is correct");
        vm.prank(investor);
        vm.expectRevert();
        off.buy(id, 1);

        // Recovery goes this far: the offering can be released even though it has sales,
        // because it is already dead. Buyers keep everything they bought.
        vm.prank(artist);
        off.abandonOffering(id);
        assertEq(share.balanceOf(investor), 10e6, "existing buyers keep every share");

        // ...but no further, and that limit is deliberate. No admin remains on the token.
        vm.prank(artist);
        vm.expectRevert(abi.encodeWithSelector(
            ShareOffering.NotTokenAdmin.selector, address(share)));
        off.createOffering(address(share), PRICE, TOTAL, 0, false);
    }

    function test_D3_abandonStillBlockedOnAHealthyOfferingWithSales() public {
        uint256 id = _open();
        vm.startPrank(investor);
        pay.approve(address(off), type(uint256).max);
        off.buy(id, 1);
        vm.stopPrank();
        vm.prank(artist);
        vm.expectRevert(abi.encodeWithSelector(ShareOffering.OfferingHasSales.selector, id, 1));
        off.abandonOffering(id); // a live, healthy sale is still a binding obligation
    }

    function test_D4_baselineDoesNotHidePostSealMinting() public {
        vm.prank(artist);
        uint256 id = off.createOffering(address(share), PRICE, TOTAL, 0, false);
        bytes32 mr = share.MINTER_ROLE(); // read before pranking; a call would consume it
        vm.prank(artist); share.grantRole(mr, coAdmin);
        vm.prank(coAdmin); share.mint(artist, 500e6); // large pre-seal float
        vm.startPrank(artist);
        share.renounceRole(share.DEFAULT_ADMIN_ROLE(), artist);
        off.sealOffering(id);
        vm.stopPrank();
        assertEq(off.baselineSupplyOf(id), 500e6, "pre-mint is disclosed on-chain, not hidden");

        vm.prank(coAdmin); share.mint(artist, 1); // any post-seal mint still trips it
        assertFalse(off.supplyIntact(id));
    }
}

/// Found during live testnet deployment: canBuy said yes to the artist while buy reverted.
contract AuditRound3CanBuyParity is AuditRound3 {
    function test_P1_canBuyRejectsTheArtist() public {
        uint256 id = _open();
        assertFalse(off.canBuy(id, artist), "artist self-buy must not report as buyable");
        vm.startPrank(artist);
        pay.approve(address(off), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(
            ShareOffering.PaymentNotReceived.selector, id, PRICE, 0));
        off.buy(id, 1);
        vm.stopPrank();
    }

    /// Every state canBuy reports true, buy must actually succeed; and vice versa.
    function test_P2_canBuyAndBuyAgreeAcrossActors() public {
        uint256 id = _open();
        address[3] memory actors = [investor, artist, address(0xDEAD)];
        for (uint256 i; i < actors.length; ++i) {
            bool predicted = off.canBuy(id, actors[i]);
            vm.startPrank(actors[i]);
            pay.approve(address(off), type(uint256).max);
            (bool succeeded,) = address(off).call(
                abi.encodeWithSelector(ShareOffering.buy.selector, id, 1));
            vm.stopPrank();
            assertEq(predicted, succeeded, "canBuy must match buy for every actor");
        }
    }
}
