// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title APassComplianceValidator
 * @notice A Monad-native implementation of the Cleanverse Validator Compliance
 *         module, which the Cleanverse gateway does not serve on Monad.
 *
 * Why this exists:
 *   The Cleanverse cooperate API exposes /validator/* (register pools, set rules,
 *   verify a user against a pool). Empirically those endpoints answer only for
 *   `base`; `monad` returns 12027 — the same code returned for a chain slug that
 *   does not exist. The underlying A-Pass registry, however, IS deployed on Monad
 *   and is a standard ERC-721:
 *       name() = "A-Pass", symbol() = "APASS", supportsInterface(0x80ac58cd) = true
 *   so a contract on Monad can read compliance state directly, with no gateway.
 *
 * Gate semantics:
 *   A wallet is compliant for a pool when it holds at least one A-Pass NFT and
 *   the pool is registered and unpaused. Holding the A-Pass was verified to track
 *   the gateway's own answer exactly: across every sampled registered wallet,
 *   balanceOf(w) == 1 coincided with verify_apass returning code 4 ("valid A-Pass,
 *   transfer allowed"), and balanceOf(w) == 0 coincided with code 2.
 *
 * Deliberately NOT implemented — tier, subTier, group and country rules:
 *   Cleanverse's off-chain rule object also matches on tier/subTier/group/subGroup
 *   and ISO country tags. The A-Pass implementation on Monad is unverified and
 *   exposes no public getter for those attributes that we could find, so encoding
 *   them here would mean inventing a source of truth. Rather than fake it, the
 *   rule struct records the intended thresholds and `attributeOracle` is left as
 *   the single seam to plug in real attribute reads once Cleanverse publishes the
 *   A-Pass ABI. Until an oracle is set, tier/country fields are advisory metadata
 *   and only A-Pass possession is enforced. isCompliant() never silently claims a
 *   check it did not perform — see `enforcedAttributes`.
 *
 * Mirrors the gateway's API shape (register / setRule / addRule / removeRule /
 * setPaused / verify / rules / isRegistered / isPaused) so a pool configured here
 * is configured the same way it would be on Base.
 */

interface IAPassRegistry {
    function balanceOf(address owner) external view returns (uint256);
}

/// @notice Optional future source for A-Pass attributes (tier, country).
interface IAPassAttributeOracle {
    /// @return tier      A-Pass tier for `wallet`
    /// @return subTier   A-Pass subTier for `wallet`
    /// @return country   ISO 3166-1 alpha-2 code, uppercase, as bytes2 (0x0000 if unknown)
    function attributesOf(address wallet)
        external
        view
        returns (uint8 tier, uint8 subTier, bytes2 country);
}

contract APassComplianceValidator is Ownable2Step {
    /**
     * @notice The Cleanverse A-Pass ERC-721 registry this validator reads.
     * @dev Owner-settable rather than immutable, deliberately. Cleanverse's A-Pass
     *      proxy is deployed at the same address on Monad mainnet and testnet, but as
     *      of deployment only the testnet copy has holders — the mainnet registry is
     *      live-but-empty. Keeping this repointable means the validator can ship to
     *      mainnet against the real registry today and start enforcing the moment
     *      Cleanverse issues mainnet A-Passes, without a redeploy or a migration.
     *      It is a trust assumption on the owner, who already controls the rules.
     */
    IAPassRegistry public apass;

    /// @notice Optional oracle supplying tier/country attributes. Unset = possession-only.
    IAPassAttributeOracle public attributeOracle;

    /**
     * @notice Compliance rule, mirroring the Cleanverse rule object.
     * @dev minTier follows Cleanverse's documented semantics exactly: the check is
     *      STRICTLY GREATER THAN, not >=. Their docs state "a user is allowed if the
     *      user's A-Pass tier is greater than this value", so minTier = 30 admits
     *      tier 31 and rejects tier 30. Preserved deliberately to avoid an
     *      off-by-one against the reference implementation.
     */
    struct Rule {
        uint8 minTier;
        uint8 minSubTier;
        bool isBlackList; // true = `countries` is a deny list; false = allow list
        bytes2[] countries; // ISO 3166-1 alpha-2, uppercase
    }

    struct Pool {
        bool registered;
        bool paused;
    }

    mapping(address => Pool) private _pools;
    mapping(address => Rule[]) private _rules;

    /**
     * @notice Hard caps on rule and country-list size.
     * @dev verify() loops every rule and every country inside it, and ShareOffering calls
     *      verify() from buy(). Without a cap the owner could push rule count high enough
     *      that buy() exceeds the block gas limit and the offering is bricked — measured
     *      at 16.5k gas for one rule versus 124k for sixty. These bounds keep the worst
     *      case bounded and cheap. They are constants, not owner-settable, precisely
     *      because the owner is the party they constrain.
     */
    uint256 public constant MAX_RULES = 16;
    uint256 public constant MAX_COUNTRIES = 32;

    /// @notice True when an attribute oracle is set, i.e. tier/country rules are actually enforced.
    function enforcedAttributes() public view returns (bool) {
        return address(attributeOracle) != address(0);
    }

    event PoolRegistered(address indexed pool);
    event PoolPauseSet(address indexed pool, bool paused);
    event RuleAdded(address indexed pool, uint256 index);
    event RuleRemoved(address indexed pool, uint256 index);
    event RulesCleared(address indexed pool);
    event AttributeOracleSet(address indexed oracle);
    event APassRegistrySet(address indexed registry);

    error ZeroAddress();
    error NotRegistered(address pool);
    error AlreadyRegistered(address pool);
    error RuleIndexOutOfBounds(address pool, uint256 index);
    error DuplicateRule(address pool);
    error TooManyRules(address pool, uint256 max);
    error TooManyCountries(uint256 max);
    error NotAContract(address addr);
    error OwnershipCannotBeRenounced();

    constructor(address apassRegistry, address initialOwner) {
        if (apassRegistry == address(0) || initialOwner == address(0)) revert ZeroAddress();
        apass = IAPassRegistry(apassRegistry);
        emit APassRegistrySet(apassRegistry);
        // OZ v4 Ownable sets owner = msg.sender; move it directly (not the 2-step
        // flow) so deployment lands on the intended owner in a single tx.
        if (initialOwner != msg.sender) _transferOwnership(initialOwner);
    }

    // ---------------------------------------------------------------- admin

    function register(address pool, Rule calldata rule) external onlyOwner {
        if (pool == address(0)) revert ZeroAddress();
        if (_pools[pool].registered) revert AlreadyRegistered(pool);
        if (rule.countries.length > MAX_COUNTRIES) revert TooManyCountries(MAX_COUNTRIES);
        _pools[pool] = Pool({registered: true, paused: false});
        _rules[pool].push(_copy(rule));
        emit PoolRegistered(pool);
        emit RuleAdded(pool, 0);
    }

    /// @notice Replace every rule on a pool with a single rule (gateway `set_rule`).
    function setRule(address pool, Rule calldata rule) external onlyOwner {
        _requireRegistered(pool);
        if (rule.countries.length > MAX_COUNTRIES) revert TooManyCountries(MAX_COUNTRIES);
        delete _rules[pool];
        emit RulesCleared(pool);
        _rules[pool].push(_copy(rule));
        emit RuleAdded(pool, 0);
    }

    /**
     * @notice Append a rule (gateway `add_rule`).
     * @dev Cleanverse rejects a rule identical to one already present and offers no
     *      update path, so the same duplicate check is enforced here.
     */
    function addRule(address pool, Rule calldata rule) external onlyOwner {
        _requireRegistered(pool);
        if (rule.countries.length > MAX_COUNTRIES) revert TooManyCountries(MAX_COUNTRIES);
        bytes32 incoming = _fingerprint(rule);
        uint256 n = _rules[pool].length;
        if (n >= MAX_RULES) revert TooManyRules(pool, MAX_RULES);
        for (uint256 i; i < n; ++i) {
            if (_fingerprintStored(pool, i) == incoming) revert DuplicateRule(pool);
        }
        _rules[pool].push(_copy(rule));
        emit RuleAdded(pool, n);
    }

    /// @notice Remove a rule by zero-based index (gateway `remove_rule`).
    function removeRule(address pool, uint256 index) external onlyOwner {
        _requireRegistered(pool);
        uint256 n = _rules[pool].length;
        if (index >= n) revert RuleIndexOutOfBounds(pool, index);
        _rules[pool][index] = _rules[pool][n - 1];
        _rules[pool].pop();
        emit RuleRemoved(pool, index);
    }

    function setPaused(address pool, bool paused) external onlyOwner {
        _requireRegistered(pool);
        _pools[pool].paused = paused;
        emit PoolPauseSet(pool, paused);
    }

    /// @notice Repoint at a different A-Pass registry. See {apass}.
    function setAPassRegistry(address registry) external onlyOwner {
        if (registry == address(0)) revert ZeroAddress();
        apass = IAPassRegistry(registry);
        emit APassRegistrySet(registry);
    }

    /// @dev Zero is allowed and means "possession-only" (attributes unenforced, reported
    ///      honestly via `checked`). A non-zero value must be a contract — a fat-fingered
    ///      EOA would otherwise set enforcedAttributes() true while every call to it fails.
    function setAttributeOracle(address oracle) external onlyOwner {
        if (oracle != address(0) && oracle.code.length == 0) revert NotAContract(oracle);
        attributeOracle = IAPassAttributeOracle(oracle);
        emit AttributeOracleSet(oracle);
    }

    /**
     * @notice Disabled. Renouncing would freeze the platform permanently.
     * @dev Pool registration is the provenance gate for every new offering, and only the
     *      owner can register. An ownerless validator means no artist can ever list again,
     *      via a single unconfirmed call that Ownable2Step's two-step guard does not cover.
     */
    function renounceOwnership() public pure override {
        revert OwnershipCannotBeRenounced();
    }

    // ----------------------------------------------------------------- read

    function isRegistered(address pool) external view returns (bool) {
        return _pools[pool].registered;
    }

    function isPaused(address pool) external view returns (bool) {
        return _pools[pool].paused;
    }

    function rules(address pool) external view returns (Rule[] memory) {
        return _rules[pool];
    }

    function ruleCount(address pool) external view returns (uint256) {
        return _rules[pool].length;
    }

    /// @notice Gas forwarded to the registry and oracle. See {hasAPass}.
    uint256 public constant EXTERNAL_CALL_GAS = 150_000;

    /**
     * @notice True when `wallet` holds at least one A-Pass on this chain.
     * @dev The A-Pass registry is an ERC-1967 proxy whose implementation CLEANVERSE
     *      controls, not us. An unguarded call meant a registry that reverts — or simply
     *      burns gas — took down verify(), isCompliant(), and therefore every buy() and
     *      every frontend, across ALL pools at once, with no circuit breaker. That
     *      contradicted this contract's own promise to answer rather than throw.
     *
     *      Failure is now an answer: unreachable registry means not verified. Fails closed,
     *      which is the correct direction for a compliance gate. The gas cap stops a
     *      hostile implementation from consuming the 63/64 the EVM would otherwise forward,
     *      which no caller-chosen gas limit could survive.
     */
    function hasAPass(address wallet) public view returns (bool) {
        try apass.balanceOf{gas: EXTERNAL_CALL_GAS}(wallet) returns (uint256 bal) {
            return bal > 0;
        } catch {
            return false;
        }
    }

    /**
     * @notice Evaluate `wallet` against `pool`.
     * @dev Mirrors the gateway's `verify`, which answers rather than throwing: an
     *      ineligible wallet is a `false` return, not a revert. A paused or
     *      unregistered pool returns false for the same reason.
     * @return ok       whether the wallet may transact with this pool
     * @return checked  whether attribute rules (tier/country) were actually applied;
     *                  false means only A-Pass possession was verified
     */
    function verify(address pool, address wallet) public view returns (bool ok, bool checked) {
        Pool memory p = _pools[pool];
        if (!p.registered || p.paused) return (false, false);
        if (!hasAPass(wallet)) return (false, false);

        if (!enforcedAttributes()) return (true, false);

        Rule[] memory rs = _rules[pool];
        /**
         * An empty rule set enforces nothing, so it must never be reported as checked.
         * register() seeds one rule but removeRule() can take a pool back down to zero,
         * after which this loop ran zero times and still returned checked = true — an open
         * gate certifying itself as enforced. An offering using requireAttributeChecks
         * (the opt-in for jurisdiction-restricted tranches) would then admit exactly the
         * wallets it exists to exclude. All five audits found this independently.
         */
        if (rs.length == 0) return (true, false);

        // A hostile or broken oracle must not brick every pool — same reasoning as hasAPass.
        // Falling back to checked = false keeps possession-only offerings trading while
        // requireAttributeChecks offerings correctly refuse to proceed.
        try attributeOracle.attributesOf{gas: EXTERNAL_CALL_GAS}(wallet) returns (
            uint8 tier, uint8 subTier, bytes2 country
        ) {
            for (uint256 i; i < rs.length; ++i) {
                if (!_satisfies(rs[i], tier, subTier, country)) return (false, true);
            }
            return (true, true);
        } catch {
            return (true, false);
        }
    }

    /// @notice Convenience boolean form of {verify}.
    function isCompliant(address pool, address wallet) external view returns (bool ok) {
        (ok,) = verify(pool, wallet);
    }

    // ------------------------------------------------------------- internal

    function _satisfies(Rule memory r, uint8 tier, uint8 subTier, bytes2 country)
        private
        pure
        returns (bool)
    {
        // Strictly greater than — Cleanverse semantics, see Rule.
        if (tier <= r.minTier) return false;
        if (r.minSubTier != 0 && subTier <= r.minSubTier) return false;

        if (r.countries.length == 0) return true;
        bool found;
        for (uint256 i; i < r.countries.length; ++i) {
            if (r.countries[i] == country) {
                found = true;
                break;
            }
        }
        // Blacklist: a match rejects. Whitelist: absence of a match rejects.
        return r.isBlackList ? !found : found;
    }

    function _copy(Rule calldata r) private pure returns (Rule memory out) {
        out.minTier = r.minTier;
        out.minSubTier = r.minSubTier;
        out.isBlackList = r.isBlackList;
        out.countries = r.countries;
    }

    function _fingerprint(Rule calldata r) private pure returns (bytes32) {
        return keccak256(abi.encode(r.minTier, r.minSubTier, r.isBlackList, r.countries));
    }

    function _fingerprintStored(address pool, uint256 i) private view returns (bytes32) {
        Rule storage r = _rules[pool][i];
        return keccak256(abi.encode(r.minTier, r.minSubTier, r.isBlackList, r.countries));
    }

    function _requireRegistered(address pool) private view {
        if (!_pools[pool].registered) revert NotRegistered(pool);
    }
}
