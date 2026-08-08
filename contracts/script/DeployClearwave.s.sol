// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {APassComplianceValidator} from "../src/APassComplianceValidator.sol";
import {RoyaltyDistributor} from "../src/RoyaltyDistributor.sol";
import {ShareOffering} from "../src/ShareOffering.sol";

/**
 * Deploys the three Clearwave contracts to Monad testnet (10143), Cleanverse's sandbox chain.
 *
 *   forge script script/DeployClearwave.s.sol:DeployClearwave \
 *     --rpc-url monad_testnet --broadcast --verify --chain 10143
 *
 * Required env: DEPLOYER_PRIVATE_KEY, CLEARWAVE_APASS_REGISTRY, CLEARWAVE_PAYMENT_TOKEN.
 *
 * Do NOT point this at Monad mainnet (143). The A-Pass registry there has no holders, so
 * every compliance check fails closed and nothing is buyable.
 */
contract DeployClearwave is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address apassRegistry = vm.envAddress("CLEARWAVE_APASS_REGISTRY");
        address paymentToken = vm.envAddress("CLEARWAVE_PAYMENT_TOKEN");
        address owner = vm.addr(pk);

        require(block.chainid == 10143, "expected Monad testnet 10143");

        vm.startBroadcast(pk);

        APassComplianceValidator validator =
            new APassComplianceValidator(apassRegistry, owner);
        ShareOffering offering =
            new ShareOffering(paymentToken, address(validator), owner);
        RoyaltyDistributor distributor =
            new RoyaltyDistributor(paymentToken, address(validator), owner);

        vm.stopBroadcast();

        console2.log("APassComplianceValidator", address(validator));
        console2.log("ShareOffering           ", address(offering));
        console2.log("RoyaltyDistributor      ", address(distributor));
        console2.log("");
        console2.log("NEXT: the RoyaltyDistributor needs its OWN Cleanverse A-Pass before it");
        console2.log("can hold or pay out anything. Issue one to the address above, then run");
        console2.log("SetupOffering.s.sol. Update src/lib/contracts.ts in clearwave-app too.");
    }
}
