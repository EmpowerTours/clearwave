// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {ShareOffering} from "../src/ShareOffering.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

contract T is ERC20, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    constructor() ERC20("S","S"){ _grantRole(DEFAULT_ADMIN_ROLE, msg.sender); }
    function decimals() public pure override returns(uint8){return 6;}
    function mint(address t,uint256 a) external onlyRole(MINTER_ROLE){_mint(t,a);}
}
contract P is ERC20 { constructor() ERC20("P","P"){}
    function decimals() public pure override returns(uint8){return 6;}
    function m(address t,uint256 a) external {_mint(t,a);} }

/// Permissive validator — isolates the supply invariant from compliance concerns.
contract OkV {
    function isRegistered(address) external pure returns (bool) { return true; }
    function isPaused(address) external pure returns (bool) { return false; }
    function verify(address, address) external pure returns (bool, bool) { return (true, true); }
}

/// The co-admin bypass from audit 2, re-run against the supply invariant.
contract CoAdminTest is Test {
    T s; P p; ShareOffering o; uint256 id;
    address artist=address(0xA1); address accomplice=address(0xA2);
    address inv=address(0xB1); address inv2=address(0xB2);

    function setUp() public {
        vm.prank(artist); s = new T();
        p = new P(); o = new ShareOffering(address(p), address(new OkV()), address(this));
        vm.startPrank(artist);
        s.grantRole(s.MINTER_ROLE(), address(o));
        s.grantRole(0x00, accomplice);              // co-admin BEFORE renouncing
        id = o.createOffering(address(s), 1e6, 1000, 0, false);
        s.renounceRole(0x00, artist);
        o.sealOffering(id);                          // still seals — artist holds nothing
        vm.stopPrank();
        p.m(inv, 1e12); p.m(inv2, 1e12);
    }

    function test_invariantHaltsOfferingWhenCoAdminMints() public {
        vm.startPrank(inv); p.approve(address(o), type(uint256).max); o.buy(id, 100); vm.stopPrank();
        assertTrue(o.supplyIntact(id), "clean before attack");
        assertTrue(o.isActive(id));

        // Accomplice grants themselves MINTER and prints shares.
        vm.startPrank(accomplice); s.grantRole(s.MINTER_ROLE(), accomplice); s.mint(accomplice, 900_000e6); vm.stopPrank();

        assertFalse(o.supplyIntact(id), "dilution is now DETECTED");
        assertFalse(o.isActive(id), "offering no longer advertises as active");

        // No further buyer can be sold into the diluted supply.
        vm.startPrank(inv2); p.approve(address(o), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(
            ShareOffering.SupplyInvariantBroken.selector, id, 100e6, 900_100e6));
        o.buy(id, 1);
        vm.stopPrank();
        emit log_named_uint("shares sold before halt", o.getOffering(id).sharesSold);
        emit log_string("attacker cannot dilute AND keep selling");
    }

    function test_invariantDoesNotFireOnNormalTrading() public {
        vm.startPrank(inv); p.approve(address(o), type(uint256).max);
        o.buy(id, 10); o.buy(id, 20); o.buy(id, 5);
        vm.stopPrank();
        assertTrue(o.supplyIntact(id));
        assertEq(s.totalSupply(), 35e6);
        // Holder-to-holder transfers must not break it either.
        vm.prank(inv); s.transfer(inv2, 5e6);
        assertTrue(o.supplyIntact(id), "transfers move supply, do not create it");
        vm.startPrank(inv); o.buy(id, 1); vm.stopPrank();
        assertEq(s.totalSupply(), 36e6);
    }
}
