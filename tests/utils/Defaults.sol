// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Id } from "src/interfaces/IMorpho.sol";

import { Users } from "./Types.sol";

/// @notice Centralized test defaults. Mirrors Sablier's `Defaults` pattern.
contract Defaults {
    // ---------------------- AMOUNTS ----------------------
    uint256 public constant USDC_AMOUNT = 100_000e6;
    uint256 public constant TOKEN_AMOUNT_18 = 100_000e18;
    uint256 public constant SUPPLY_AMOUNT = 10_000e6;
    uint256 public constant APPROVAL_CAP = 1_000_000e6;

    // ---------------------- SWAP ----------------------
    uint256 public constant SWAP_AMOUNT_IN = 1000e6;
    uint256 public constant SWAP_EXPECTED_OUT = 1000e6;
    uint256 public constant ORACLE_QUOTE_1_TO_1 = 1e18;
    uint256 public constant MAX_SLIPPAGE_BPS = 50;
    /// @dev Mayan swap-path `minAmountOut` floor: source-swap + bridge round trip, wider than a single leg.
    uint256 public constant MAX_BRIDGE_SLIPPAGE_BPS = 300;
    uint256 public constant BPS_DENOMINATOR = 10_000;

    // ---------------------- BRIDGE ----------------------
    uint256 public constant BRIDGE_AMOUNT = 1000e6;
    /// @dev CCTP fast-transfer `maxFee` cap, in bps of the burn amount.
    uint256 public constant MAX_FEE_BPS = 50;
    /// @dev Across uses the EVM chain id (Base).
    uint256 public constant ACROSS_DEST_CHAIN_ID = 8453;
    /// @dev CCIP uses its own chain selector (Base mainnet).
    uint64 public constant CCIP_DEST_SELECTOR = 15_971_525_489_660_198_786;
    /// @dev CCTP uses a Circle domain id (Base).
    uint32 public constant CCTP_DEST_DOMAIN = 6;
    /// @dev Mayan/Wormhole uses a Wormhole chain id (Base).
    uint16 public constant MAYAN_DEST_WORMHOLE_CHAIN = 30;
    uint256 public constant CCIP_FEE = 0.01 ether;
    uint256 public constant BRIDGE_MAX_FEE = 1e6;
    uint32 public constant CCTP_FINALITY_THRESHOLD = 2000;
    address public constant BRIDGE_RECIPIENT_ADDR = 0x000000000000000000000000000000000000bEEF;

    /// @dev Default destination recipient, widened to the bridge registry's `bytes32` key form.
    function BRIDGE_RECIPIENT() public pure returns (bytes32) {
        return bytes32(uint256(uint160(BRIDGE_RECIPIENT_ADDR)));
    }

    // ---------------------- MARKETS ----------------------
    function MARKET_A() public pure returns (Id) {
        return Id.wrap(keccak256("MARKET_A"));
    }

    function MARKET_B() public pure returns (Id) {
        return Id.wrap(keccak256("MARKET_B"));
    }

    function MARKET_NULL() public pure returns (Id) {
        return Id.wrap(bytes32(0));
    }

    // ---------------------- TIME ----------------------
    uint256 public constant FEB_1_2025 = 1_738_368_000;

    // ---------------------- IPOR ----------------------
    /// @dev Default claim-window length on the mock IPOR WithdrawManager. Real Fusion vaults set
    ///      this per-vault on the order of hours-to-days; the tests just need a value large enough
    ///      to advance the EVM clock past it.
    uint32 public constant IPOR_WITHDRAW_WINDOW = 1 hours;

    // ---------------------- USERS ----------------------
    Users private _users;

    function setUsers(Users memory u) external {
        _users = u;
    }

    function users() external view returns (Users memory) {
        return _users;
    }
}
