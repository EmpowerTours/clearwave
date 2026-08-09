// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/APassComplianceValidator.sol";

contract MockAPass {
    function balanceOf(address) external pure returns (uint256) { return 1; }
}

contract MockOracle {
    function attributesOf(address) external pure returns (uint8, uint8, bytes2) {
        return (99, 99, bytes2("US"));
    }
}

/// @notice Measures verify() cost against rule count, the loop MAX_RULES exists to bound.
contract ValidatorGasTest is Test {
    APassComplianceValidator v;
    address pool = address(0xBEEF);
    address wallet = address(0xCAFE);

    function setUp() public {
        v = new APassComplianceValidator(address(new MockAPass()), address(this));
        v.setAttributeOracle(address(new MockOracle())); // else verify() short-circuits
    }

    function _rule() internal pure returns (APassComplianceValidator.Rule memory r) {
        bytes2[] memory c = new bytes2[](0);
        r = APassComplianceValidator.Rule(0, 0, false, c);
    }

    /// @dev Rules must differ or addRule reverts DuplicateRule; vary minTier.
    function _ruleN(uint8 n) internal pure returns (APassComplianceValidator.Rule memory r) {
        bytes2[] memory c = new bytes2[](0);
        r = APassComplianceValidator.Rule(n, 0, false, c);
    }

    function test_GasByRuleCount() public {
        v.register(pool, _rule());

        uint256 g0 = gasleft();
        v.verify(pool, wallet);
        uint256 oneRule = g0 - gasleft();

        for (uint8 i = 1; i < 16; ++i) {
            v.addRule(pool, _ruleN(i));
        }
        assertEq(v.ruleCount(pool), 16, "expected MAX_RULES");

        uint256 g1 = gasleft();
        v.verify(pool, wallet);
        uint256 maxRules = g1 - gasleft();

        emit log_named_uint("verify() gas -  1 rule ", oneRule);
        emit log_named_uint("verify() gas - 16 rules", maxRules);
        emit log_named_uint("MAX_RULES cap          ", v.MAX_RULES());
    }
}
