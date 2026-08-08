// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {APassComplianceValidator} from "../src/APassComplianceValidator.sol";
import {ShareOffering} from "../src/ShareOffering.sol";

interface IAccessControlLike {
    function grantRole(bytes32 role, address account) external;
    function renounceRole(bytes32 role, address account) external;
    function hasRole(bytes32 role, address account) external view returns (bool);
}

/**
 * Runs the five-step artist flow end to end. The order is NOT stylistic — step 3 needs the
 * artist to still hold DEFAULT_ADMIN_ROLE and step 5 needs it gone, so the sequence is the
 * only one that works:
 *
 *   1. platform  validator.register(shareToken, rule)
 *   2. artist    shareToken.grantRole(MINTER_ROLE, shareOffering)
 *   3. artist    createOffering(...)
 *   4. artist    shareToken.renounceRole(DEFAULT_ADMIN_ROLE, artist)
 *   5. artist    sealOffering(id)
 *
 *   forge script script/SetupOffering.s.sol:SetupOffering \
 *     --rpc-url monad_testnet --broadcast
 *
 * Required env: DEPLOYER_PRIVATE_KEY, ARTIST_PRIVATE_KEY, CLEARWAVE_VALIDATOR,
 * CLEARWAVE_SHARE_OFFERING, CLEARWAVE_SHARE_TOKEN, plus the offering terms below.
 *
 * The A-Token must have been issued with admin_address = the ARTIST wallet. If any other
 * address also holds DEFAULT_ADMIN_ROLE, step 4 does not remove it and that co-admin can
 * mint shares behind the offering's back. The supply invariant catches it at buy time,
 * but the offering is then dead rather than merely degraded.
 */
contract SetupOffering is Script {
    bytes32 constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;

    /// A silent seal failure on 2026-07-29 was just the artist out of gas at 0.0017 MON.
    uint256 constant MIN_ARTIST_GAS = 0.05 ether;

    function run() external {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        uint256 artistPk = vm.envUint("ARTIST_PRIVATE_KEY");
        address artist = vm.addr(artistPk);

        APassComplianceValidator validator =
            APassComplianceValidator(vm.envAddress("CLEARWAVE_VALIDATOR"));
        ShareOffering offering = ShareOffering(vm.envAddress("CLEARWAVE_SHARE_OFFERING"));
        address shareToken = vm.envAddress("CLEARWAVE_SHARE_TOKEN");

        uint256 pricePerShare = vm.envUint("CLEARWAVE_PRICE_PER_SHARE"); // 6dp, e.g. 5000000
        uint256 totalShares = vm.envUint("CLEARWAVE_TOTAL_SHARES");
        uint64 closesAt = uint64(vm.envUint("CLEARWAVE_CLOSES_AT")); // 0 = no deadline

        require(block.chainid == 10143, "expected Monad testnet 10143");
        require(artist.balance >= MIN_ARTIST_GAS, "fund the artist wallet with MON first");
        require(
            IAccessControlLike(shareToken).hasRole(DEFAULT_ADMIN_ROLE, artist),
            "artist is not the A-Token admin - reissue with admin_address = artist"
        );

        // 1. Platform vets the token. Unregistered pools fail closed, so skipping this
        //    makes canBuy return false with no obvious cause.
        if (!validator.isRegistered(shareToken)) {
            vm.startBroadcast(deployerPk);
            APassComplianceValidator.Rule memory rule = APassComplianceValidator.Rule({
                minTier: 0,
                minSubTier: 0,
                isBlackList: false,
                countries: new bytes2[](0)
            });
            validator.register(shareToken, rule);
            vm.stopBroadcast();
            console2.log("1. registered pool");
        } else {
            console2.log("1. pool already registered, skipping");
        }

        vm.startBroadcast(artistPk);

        // 2. The offering can only mint if the artist grants it MINTER_ROLE.
        IAccessControlLike(shareToken).grantRole(MINTER_ROLE, address(offering));
        console2.log("2. granted MINTER_ROLE to ShareOffering");

        // 3. Needs the artist to still be admin.
        uint256 id = offering.createOffering(
            shareToken, pricePerShare, totalShares, closesAt, false
        );
        console2.log("3. created offering", id);

        // 4. Drop admin so nobody can mint shares outside the offering.
        IAccessControlLike(shareToken).renounceRole(DEFAULT_ADMIN_ROLE, artist);
        console2.log("4. artist renounced DEFAULT_ADMIN_ROLE");

        // 5. Only now is it buyable.
        offering.sealOffering(id);
        console2.log("5. sealed - offering is live");

        vm.stopBroadcast();

        string memory reason = offering.inactiveReason(id);
        require(bytes(reason).length == 0, string.concat("offering inactive: ", reason));
        console2.log("verified active, shares remaining", offering.sharesRemaining(id));
    }
}
