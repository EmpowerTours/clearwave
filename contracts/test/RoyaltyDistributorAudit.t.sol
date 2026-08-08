// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {RoyaltyDistributor} from "../src/RoyaltyDistributor.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

error NoAPassA(address a);

contract ARegistry {
    mapping(address => uint256) public balanceOf;
    function issue(address a) external { balanceOf[a] = 1; }
    function revoke(address a) external { balanceOf[a] = 0; }
}

/**
 * Mirrors the REAL Cleanverse A-Token, verified on Monad testnet 2026-07-29: it gates the
 * SENDER as well as the recipient. Confirmed against the live token — a non-compliant sender
 * reverts NoAPass(sender) (0xa6725971) while an over-balance transfer from a compliant sender
 * reverts with a distinct ERC20InsufficientBalance (0xe450d38c). Two different selectors, so
 * the sender check is definitely compliance and not a balance artifact.
 */
contract APay is ERC20 {
    ARegistry public reg;
    constructor(ARegistry r) ERC20("Pay", "PAY") { reg = r; }
    function decimals() public pure override returns (uint8) { return 6; }
    function mintTo(address t, uint256 a) external { _mint(t, a); }
    function _transfer(address f, address t, uint256 a) internal override {
        if (reg.balanceOf(f) == 0) revert NoAPassA(f); // SENDER gated
        if (reg.balanceOf(t) == 0) revert NoAPassA(t); // recipient gated
        super._transfer(f, t, a);
    }
}

contract AValidator {
    ARegistry public reg;
    mapping(address => bool) public registered;
    bool public reverts;
    bool public burnsGas;
    constructor(ARegistry r) { reg = r; }
    function setRegistered(address p, bool v) external { registered[p] = v; }
    function setReverts(bool v) external { reverts = v; }
    function setBurnsGas(bool v) external { burnsGas = v; }
    function isRegistered(address p) external view returns (bool) { return registered[p]; }
    function isPaused(address) external pure returns (bool) { return false; }
    function verify(address, address w) external view returns (bool, bool) {
        if (burnsGas) { uint256 i; while (true) { i++; } }
        if (reverts) revert("validator down");
        return (reg.balanceOf(w) > 0, true);
    }
}

contract RDAudit is Test {
    ARegistry reg;
    APay pay;
    AValidator val;
    RoyaltyDistributor dist;

    address artist = address(0xA1);
    address shareToken = address(0x5A1E);
    address alice = address(0xB1);

    uint256 constant TOTAL = 1000e6;

    function setUp() public {
        reg = new ARegistry();
        pay = new APay(reg);
        val = new AValidator(reg);
        dist = new RoyaltyDistributor(address(pay), address(val), address(this));
        reg.issue(artist); reg.issue(alice);
        reg.issue(address(dist)); // custodial: the contract must be CVI-verified to operate
        val.setRegistered(shareToken, true);
        pay.mintTo(artist, 10_000e6);
        vm.roll(100);
    }

    function _round(bytes32 root) internal returns (uint256 id) {
        vm.prank(artist);
        pay.approve(address(dist), type(uint256).max);
        vm.prank(artist);
        id = dist.createRound(shareToken, TOTAL, root, uint64(block.number - 1),
            uint64(block.timestamp + 60 days), "ipfs://x");
    }

    /**
     * ACCEPTED RISK, PINNED BY TEST — not a bug report, a deliberate design consequence.
     *
     * Escrow was chosen for settlement certainty. The cost is that this contract is the
     * SENDER on every payout, and the A-Token gates senders, so revoking THIS CONTRACT's
     * A-Pass closes every exit at once: claim, sweep and skim are all transfers. No
     * emergency-withdraw could help, because an emergency withdraw is also a transfer.
     *
     * This test exists so the behaviour is recorded and cannot be discovered by surprise in
     * production. If it ever starts failing, the token's semantics changed and the risk
     * assessment in the contract header must be revisited.
     */
    function test_A_ACCEPTED_revokingContractAPassFreezesEscrow() public {
        bytes32 leaf = dist.leafFor(0, alice, 500e6);
        uint256 id = _round(leaf);
        assertEq(dist.escrowAtRisk(), TOTAL, "operators can watch this number");

        reg.revoke(address(dist)); // Cleanverse revokes the contract's identity

        bytes32[] memory empty;
        vm.expectRevert(abi.encodeWithSelector(NoAPassA.selector, address(dist)));
        dist.claim(id, 0, alice, 500e6, empty);

        vm.warp(block.timestamp + 61 days);
        vm.prank(artist);
        vm.expectRevert(abi.encodeWithSelector(NoAPassA.selector, address(dist)));
        dist.sweepExpired(id);

        pay.mintTo(address(dist), 1e6);
        vm.expectRevert(abi.encodeWithSelector(NoAPassA.selector, address(dist)));
        dist.skimSurplus(artist);

        assertEq(pay.balanceOf(address(dist)), TOTAL + 1e6, "every exit is closed");

        // ...and it is fully reversible if the A-Pass is restored. The funds are frozen,
        // not destroyed, which is what makes monitoring a real mitigation.
        reg.issue(address(dist));
        dist.claim(id, 0, alice, 500e6, empty);
        assertEq(pay.balanceOf(alice), 500e6, "service resumes once compliance is restored");
    }

    /// FIXED: a hostile validator no longer bricks claims (was unguarded, now try/catch).
    function test_B_revertingValidatorFailsClosedNotOpen() public {
        bytes32 leaf = dist.leafFor(0, alice, 500e6);
        uint256 id = _round(leaf);
        bytes32[] memory empty;

        val.setReverts(true);
        assertFalse(dist.canClaim(id, 0, alice, 500e6, empty), "answers instead of throwing");
        vm.expectRevert(abi.encodeWithSelector(
            RoyaltyDistributor.ClaimantNotCompliant.selector, alice));
        dist.claim(id, 0, alice, 500e6, empty);

        val.setReverts(false);
        assertTrue(dist.canClaim(id, 0, alice, 500e6, empty), "recovers when validator returns");
    }

    function test_B2_gasBurningValidatorCannotConsumeTheWholeCall() public {
        bytes32 leaf = dist.leafFor(0, alice, 500e6);
        uint256 id = _round(leaf);
        bytes32[] memory empty;
        val.setBurnsGas(true);
        assertFalse(dist.canClaim(id, 0, alice, 500e6, empty), "gas cap contains it");
    }

    /// Correct Merkle behaviour for a one-holder round; pinned so nobody "fixes" it later.
    function test_C_singleLeafRootAcceptsEmptyProof() public {
        bytes32 leaf = dist.leafFor(0, alice, 500e6);
        uint256 id = _round(leaf);
        bytes32[] memory empty;
        assertTrue(dist.canClaim(id, 0, alice, 500e6, empty));
        dist.claim(id, 0, alice, 500e6, empty);
        assertEq(pay.balanceOf(alice), 500e6);
    }

    /// A round can never pay more than it escrowed, regardless of what its root claims.
    function test_D_roundCannotOverpayItsOwnEscrow() public {
        bytes32 leaf = dist.leafFor(0, alice, 5_000e6); // root promises 5x the escrow
        vm.prank(artist);
        pay.approve(address(dist), type(uint256).max);
        vm.prank(artist);
        uint256 id = dist.createRound(shareToken, TOTAL, leaf, uint64(block.number - 1),
            uint64(block.timestamp + 60 days), "u");
        bytes32[] memory empty;
        vm.expectRevert(abi.encodeWithSelector(
            RoyaltyDistributor.RoundExhausted.selector, id, TOTAL, 5_000e6));
        dist.claim(id, 0, alice, 5_000e6, empty);
    }

    /// FIXED: a funder who loses compliance can redirect the remainder instead of stranding it.
    function test_E_sweepRecipientRescuesANonCompliantFunder() public {
        bytes32 leaf = dist.leafFor(0, alice, 400e6);
        uint256 id = _round(leaf);
        address backup = address(0xC0FFEE);
        reg.issue(backup);

        vm.prank(artist);
        dist.setSweepRecipient(id, backup);
        reg.revoke(artist);

        vm.warp(block.timestamp + 61 days);
        vm.prank(artist);
        dist.sweepExpired(id);
        assertEq(pay.balanceOf(backup), TOTAL, "remainder rescued rather than stranded");
    }

    /// Claims remain possible after expiry until a sweep actually happens — intended.
    function test_F_claimsSurviveExpiryUntilSwept() public {
        bytes32 leaf = dist.leafFor(0, alice, 400e6);
        uint256 id = _round(leaf);
        vm.warp(block.timestamp + 61 days);
        bytes32[] memory empty;
        dist.claim(id, 0, alice, 400e6, empty); // expiry gates sweeping, not claiming
        assertEq(pay.balanceOf(alice), 400e6);
    }

    /// canClaim must never promise something claim would refuse.
    function test_G_canClaimMirrorsClaimAcrossFailureModes() public {
        bytes32 leaf = dist.leafFor(0, alice, 500e6);
        uint256 id = _round(leaf);
        bytes32[] memory empty;

        assertTrue(dist.canClaim(id, 0, alice, 500e6, empty));

        reg.revoke(alice); // claimant non-compliant
        assertFalse(dist.canClaim(id, 0, alice, 500e6, empty));
        reg.issue(alice);

        dist.claim(id, 0, alice, 500e6, empty); // spent
        assertFalse(dist.canClaim(id, 0, alice, 500e6, empty));
    }

    /// Escrow accounting stays exact across claim, skim and sweep.
    function test_H_accountingIsExactAcrossFullLifecycle() public {
        bytes32 leaf = dist.leafFor(0, alice, 400e6);
        uint256 id = _round(leaf);
        assertEq(dist.totalCommitted(), TOTAL);

        bytes32[] memory empty;
        dist.claim(id, 0, alice, 400e6, empty);
        assertEq(dist.totalCommitted(), TOTAL - 400e6);

        pay.mintTo(address(dist), 50e6); // stray funds arrive
        dist.skimSurplus(artist);
        assertEq(dist.totalCommitted(), TOTAL - 400e6, "skim never touches commitments");
        assertEq(pay.balanceOf(address(dist)), TOTAL - 400e6, "exactly the owed amount remains");

        vm.warp(block.timestamp + 61 days);
        vm.prank(artist);
        dist.sweepExpired(id);
        assertEq(dist.totalCommitted(), 0);
        assertEq(pay.balanceOf(address(dist)), 0, "drains to zero, nothing stranded");
    }
}
