// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {RoyaltyDistributor} from "../src/RoyaltyDistributor.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

error NoAPassRD(address a);

contract RDRegistry {
    mapping(address => uint256) public balanceOf;
    function issue(address a) external { balanceOf[a] = 1; }
    function revoke(address a) external { balanceOf[a] = 0; }
}

/// Payment is an A-Token: only A-Pass holders can receive it, including this contract.
contract RDPay is ERC20 {
    RDRegistry public reg;
    uint256 public feeBps;
    constructor(RDRegistry r) ERC20("Pay", "PAY") { reg = r; }
    function decimals() public pure override returns (uint8) { return 6; }
    function mintTo(address t, uint256 a) external { _mint(t, a); }
    function setFeeBps(uint256 b) external { feeBps = b; }
    function _transfer(address f, address t, uint256 a) internal override {
        if (reg.balanceOf(t) == 0) revert NoAPassRD(t);
        uint256 fee = (a * feeBps) / 10_000;
        if (fee > 0) { super._transfer(f, t, a - fee); super._burn(f, fee); }
        else { super._transfer(f, t, a); }
    }
}

contract RDValidator {
    RDRegistry public reg;
    mapping(address => bool) public registered;
    mapping(address => bool) public pausedPool;
    constructor(RDRegistry r) { reg = r; }
    function setRegistered(address p, bool v) external { registered[p] = v; }
    function setPausedPool(address p, bool v) external { pausedPool[p] = v; }
    function isRegistered(address p) external view returns (bool) { return registered[p]; }
    function isPaused(address p) external view returns (bool) { return pausedPool[p]; }
    function verify(address, address w) external view returns (bool, bool) {
        return (reg.balanceOf(w) > 0, true);
    }
}

contract RoyaltyDistributorTest is Test {
    RDRegistry reg;
    RDPay pay;
    RDValidator val;
    RoyaltyDistributor dist;

    address artist = address(0xA1);
    address shareToken = address(0x5A1E);
    address alice = address(0xB1);
    address bob = address(0xB2);
    address carol = address(0xB3);

    // Round 1: 1000 PAY split 500 / 300 / 200.
    uint256 constant TOTAL = 1000e6;
    uint256 aliceAmt = 500e6;
    uint256 bobAmt = 300e6;
    uint256 carolAmt = 200e6;

    bytes32[] leaves;
    bytes32 root;

    function setUp() public {
        reg = new RDRegistry();
        pay = new RDPay(reg);
        val = new RDValidator(reg);
        dist = new RoyaltyDistributor(address(pay), address(val), address(this));

        reg.issue(artist); reg.issue(alice); reg.issue(bob); reg.issue(carol);
        reg.issue(address(dist)); // custodial: the contract must itself be CVI-verified
        val.setRegistered(shareToken, true);

        pay.mintTo(artist, 10_000e6);

        leaves.push(dist.leafFor(0, alice, aliceAmt));
        leaves.push(dist.leafFor(1, bob, bobAmt));
        leaves.push(dist.leafFor(2, carol, carolAmt));
        root = _root3(leaves[0], leaves[1], leaves[2]);
        vm.roll(100);
    }

    // --- minimal 3-leaf merkle helpers (sorted pairs, matching OZ MerkleProof) ---
    function _h(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }
    function _root3(bytes32 l0, bytes32 l1, bytes32 l2) internal pure returns (bytes32) {
        return _h(_h(l0, l1), l2);
    }
    function _proof(uint256 i) internal view returns (bytes32[] memory p) {
        if (i == 0) { p = new bytes32[](2); p[0] = leaves[1]; p[1] = leaves[2]; }
        else if (i == 1) { p = new bytes32[](2); p[0] = leaves[0]; p[1] = leaves[2]; }
        else { p = new bytes32[](1); p[0] = _h(leaves[0], leaves[1]); }
    }

    function _round() internal returns (uint256 id) {
        vm.startPrank(artist);
        pay.approve(address(dist), type(uint256).max);
        id = dist.createRound(
            shareToken, TOTAL, root, uint64(block.number - 1),
            uint64(block.timestamp + 60 days), "ipfs://holders"
        );
        vm.stopPrank();
    }

    // ------------------------------------------------------------- happy path

    function test_createRound_pullsFundsAndRecordsTerms() public {
        uint256 id = _round();
        RoyaltyDistributor.Round memory r = dist.getRound(id);
        assertEq(r.shareToken, shareToken);
        assertEq(r.funder, artist);
        assertEq(r.amount, TOTAL);
        assertEq(r.claimed, 0);
        assertEq(r.merkleRoot, root);
        assertEq(pay.balanceOf(address(dist)), TOTAL, "royalties escrowed up front");
        assertEq(dist.totalCommitted(), TOTAL);
        assertEq(dist.escrowAtRisk(), TOTAL, "exposure is measurable");
    }

    function test_allHoldersClaimTheirExactShare() public {
        uint256 id = _round();
        dist.claim(id, 0, alice, aliceAmt, _proof(0));
        dist.claim(id, 1, bob, bobAmt, _proof(1));
        dist.claim(id, 2, carol, carolAmt, _proof(2));
        assertEq(pay.balanceOf(alice), aliceAmt);
        assertEq(pay.balanceOf(bob), bobAmt);
        assertEq(pay.balanceOf(carol), carolAmt);
        assertEq(dist.remainingOf(id), 0);
        assertEq(pay.balanceOf(address(dist)), 0, "fully distributed");
        assertEq(dist.totalCommitted(), 0);
    }

    function test_anyoneMayPayGasButFundsGoToTheHolder() public {
        uint256 id = _round();
        vm.prank(bob); // bob pays gas to deliver alice's royalties
        dist.claim(id, 0, alice, aliceAmt, _proof(0));
        assertEq(pay.balanceOf(alice), aliceAmt, "destination is the leaf, not the caller");
        assertEq(pay.balanceOf(bob), 0);
    }

    // ---------------------------------------------------------------- attacks

    function test_doubleClaimIsRejected() public {
        uint256 id = _round();
        dist.claim(id, 0, alice, aliceAmt, _proof(0));
        vm.expectRevert(abi.encodeWithSelector(RoyaltyDistributor.AlreadyClaimed.selector, id, 0));
        dist.claim(id, 0, alice, aliceAmt, _proof(0));
    }

    /// The exact hole a claim-time balance read would have: sell your shares, claim anyway.
    function test_transferringSharesAfterSnapshotCannotDoubleClaim() public {
        uint256 id = _round();
        dist.claim(id, 0, alice, aliceAmt, _proof(0));
        // Alice's shares now sit with a new holder who was NOT in the snapshot.
        address newHolder = address(0xB9);
        reg.issue(newHolder);
        bytes32[] memory p = _proof(0);
        vm.expectRevert(abi.encodeWithSelector(RoyaltyDistributor.AlreadyClaimed.selector, id, 0));
        dist.claim(id, 0, newHolder, aliceAmt, p);
    }

    function test_inflatedAmountFailsProof() public {
        uint256 id = _round();
        vm.expectRevert(abi.encodeWithSelector(
            RoyaltyDistributor.InvalidProof.selector, id, 0, alice));
        dist.claim(id, 0, alice, aliceAmt + 1, _proof(0));
    }

    function test_wrongAccountFailsProof() public {
        uint256 id = _round();
        vm.expectRevert(abi.encodeWithSelector(
            RoyaltyDistributor.InvalidProof.selector, id, 0, bob));
        dist.claim(id, 0, bob, aliceAmt, _proof(0));
    }

    function test_proofFromAnotherRoundIsRejected() public {
        uint256 id = _round();
        bytes32[] memory bogus = new bytes32[](1);
        bogus[0] = keccak256("nope");
        vm.expectRevert(abi.encodeWithSelector(
            RoyaltyDistributor.InvalidProof.selector, id, 0, alice));
        dist.claim(id, 0, alice, aliceAmt, bogus);
    }

    /// An over-allocated root must drain only its own round, never another's.
    function test_overAllocatedRootCannotBleedIntoOtherRounds() public {
        uint256 idA = _round();
        uint256 idB = _round(); // second, independently funded round

        // Round A's root promises 1000 total; claim it all.
        dist.claim(idA, 0, alice, aliceAmt, _proof(0));
        dist.claim(idA, 1, bob, bobAmt, _proof(1));
        dist.claim(idA, 2, carol, carolAmt, _proof(2));
        assertEq(dist.remainingOf(idA), 0);
        assertEq(dist.remainingOf(idB), TOTAL, "round B untouched");
        assertEq(pay.balanceOf(address(dist)), TOTAL);
    }

    function test_claimCappedByRoundBalance() public {
        // A root whose single leaf over-promises relative to the deposit.
        bytes32 leaf = dist.leafFor(0, alice, 10_000e6);
        vm.startPrank(artist);
        pay.approve(address(dist), type(uint256).max);
        uint256 id = dist.createRound(
            shareToken, 100e6, leaf, uint64(block.number - 1),
            uint64(block.timestamp + 60 days), "ipfs://x");
        vm.stopPrank();
        bytes32[] memory empty;
        vm.expectRevert(abi.encodeWithSelector(
            RoyaltyDistributor.RoundExhausted.selector, id, 100e6, 10_000e6));
        dist.claim(id, 0, alice, 10_000e6, empty);
    }

    function test_nonCompliantClaimantRejected() public {
        uint256 id = _round();
        reg.revoke(alice);
        vm.expectRevert(abi.encodeWithSelector(
            RoyaltyDistributor.ClaimantNotCompliant.selector, alice));
        dist.claim(id, 0, alice, aliceAmt, _proof(0));
    }

    function test_feeOnTransferDepositRejected() public {
        pay.setFeeBps(100);
        vm.startPrank(artist);
        pay.approve(address(dist), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(
            RoyaltyDistributor.DepositNotReceived.selector, TOTAL, 990e6));
        dist.createRound(shareToken, TOTAL, root, uint64(block.number - 1),
            uint64(block.timestamp + 60 days), "ipfs://x");
        vm.stopPrank();
    }

    /// The escrow guarantee: once funded, a holder is paid regardless of the funder.
    function test_escrowGuaranteesPaymentEvenIfFunderIsDrained() public {
        uint256 id = _round();
        uint256 rest = pay.balanceOf(artist); // read BEFORE pranking; a call consumes it
        vm.prank(artist);
        pay.transfer(bob, rest); // funder empties their wallet
        assertEq(pay.balanceOf(artist), 0);
        dist.claim(id, 0, alice, aliceAmt, _proof(0));
        assertEq(pay.balanceOf(alice), aliceAmt, "settlement certainty is the point of escrow");
    }

    function test_feeOnTransferPayoutRejected() public {
        uint256 id = _round();
        pay.setFeeBps(100); // asset turns hostile after funding
        vm.expectRevert(abi.encodeWithSelector(
            RoyaltyDistributor.PayoutNotDelivered.selector, alice, aliceAmt, 495e6));
        dist.claim(id, 0, alice, aliceAmt, _proof(0));
    }

    // ------------------------------------------------------- creation guards

    function test_unvettedShareTokenRejected() public {
        vm.startPrank(artist);
        pay.approve(address(dist), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(
            RoyaltyDistributor.ShareTokenNotVetted.selector, address(0xDEAD)));
        dist.createRound(address(0xDEAD), TOTAL, root, uint64(block.number - 1),
            uint64(block.timestamp + 60 days), "u");
        vm.stopPrank();
    }

    function test_pausedPoolRejected() public {
        val.setPausedPool(shareToken, true);
        vm.startPrank(artist);
        pay.approve(address(dist), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(
            RoyaltyDistributor.PoolPaused.selector, shareToken));
        dist.createRound(shareToken, TOTAL, root, uint64(block.number - 1),
            uint64(block.timestamp + 60 days), "u");
        vm.stopPrank();
    }

    function test_futureSnapshotRejected() public {
        vm.startPrank(artist);
        pay.approve(address(dist), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(
            RoyaltyDistributor.SnapshotInFuture.selector, uint64(block.number + 10)));
        dist.createRound(shareToken, TOTAL, root, uint64(block.number + 10),
            uint64(block.timestamp + 60 days), "u");
        vm.stopPrank();
    }

    function test_shortClaimWindowRejected() public {
        vm.startPrank(artist);
        pay.approve(address(dist), type(uint256).max);
        vm.expectRevert();
        dist.createRound(shareToken, TOTAL, root, uint64(block.number - 1),
            uint64(block.timestamp + 1 days), "u");
        vm.stopPrank();
    }

    function test_emptyRootRejected() public {
        vm.startPrank(artist);
        pay.approve(address(dist), type(uint256).max);
        vm.expectRevert(RoyaltyDistributor.EmptyMerkleRoot.selector);
        dist.createRound(shareToken, TOTAL, bytes32(0), uint64(block.number - 1),
            uint64(block.timestamp + 60 days), "u");
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- sweep

    function test_sweepReturnsOnlyUnclaimedAndOnlyAfterExpiry() public {
        uint256 id = _round();
        dist.claim(id, 0, alice, aliceAmt, _proof(0));
        vm.prank(artist);
        vm.expectRevert();
        dist.sweepExpired(id); // holders are guaranteed MIN_CLAIM_WINDOW

        vm.warp(block.timestamp + 61 days);
        uint256 before = pay.balanceOf(artist);
        vm.prank(artist);
        dist.sweepExpired(id);
        assertEq(pay.balanceOf(artist) - before, bobAmt + carolAmt, "only the unclaimed part");
        assertEq(dist.totalCommitted(), 0);
    }

    function test_sweepIsOnceOnlyAndFunderGated() public {
        uint256 id = _round();
        vm.warp(block.timestamp + 61 days);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(RoyaltyDistributor.NotFunder.selector, id));
        dist.sweepExpired(id);
        vm.prank(artist);
        dist.sweepExpired(id);
        vm.prank(artist);
        vm.expectRevert(abi.encodeWithSelector(RoyaltyDistributor.AlreadySwept.selector, id));
        dist.sweepExpired(id);
    }

    /// AUDIT FIX: a funder whose own A-Pass lapses can redirect their remainder.
    function test_sweepRecipientCanBeReassigned() public {
        uint256 id = _round();
        address backup = address(0xC0FFEE);
        reg.issue(backup);
        vm.prank(artist);
        dist.setSweepRecipient(id, backup);

        reg.revoke(artist); // funder loses compliance; previously this stranded the funds
        vm.warp(block.timestamp + 61 days);
        vm.prank(artist);
        dist.sweepExpired(id);
        assertEq(pay.balanceOf(backup), TOTAL, "remainder rescued to a compliant address");
    }

    function test_onlyFunderMayReassignSweepRecipient() public {
        uint256 id = _round();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(RoyaltyDistributor.NotFunder.selector, id));
        dist.setSweepRecipient(id, bob);
    }

    function test_sweepBlocksLaterClaims() public {
        uint256 id = _round();
        vm.warp(block.timestamp + 61 days);
        vm.prank(artist);
        dist.sweepExpired(id);
        vm.expectRevert(abi.encodeWithSelector(
            RoyaltyDistributor.RoundExhausted.selector, id, 0, aliceAmt));
        dist.claim(id, 0, alice, aliceAmt, _proof(0));
    }

    function test_skimCannotTouchCommittedFunds() public {
        address treasury = address(0xC0FFEE);
        reg.issue(treasury);
        _round();
        vm.expectRevert(RoyaltyDistributor.ZeroAmount.selector);
        dist.skimSurplus(treasury); // nothing above totalCommitted

        pay.mintTo(address(dist), 7e6); // stray transfer in
        dist.skimSurplus(treasury);
        assertEq(pay.balanceOf(treasury), 7e6, "only the stray amount moved");
        assertEq(pay.balanceOf(address(dist)), TOTAL, "round funds untouched");
    }

    function test_renounceOwnershipDisabled() public {
        vm.expectRevert(RoyaltyDistributor.OwnershipCannotBeRenounced.selector);
        dist.renounceOwnership();
    }

    function test_canClaimMirrorsClaim() public {
        uint256 id = _round();
        assertTrue(dist.canClaim(id, 0, alice, aliceAmt, _proof(0)));
        dist.claim(id, 0, alice, aliceAmt, _proof(0));
        assertFalse(dist.canClaim(id, 0, alice, aliceAmt, _proof(0)), "spent");
        assertFalse(dist.canClaim(id, 1, bob, bobAmt + 1, _proof(1)), "bad amount");
        reg.revoke(carol);
        assertFalse(dist.canClaim(id, 2, carol, carolAmt, _proof(2)), "non-compliant");
    }

    function test_invalidRoundReverts() public {
        vm.expectRevert(abi.encodeWithSelector(RoyaltyDistributor.InvalidRound.selector, 99));
        dist.getRound(99);
    }
}
