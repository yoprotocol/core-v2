// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Shared mutable state across invariant handlers.
/// @dev    Ghost variables are append-only — never decremented — so cross-handler invariants can
///         compare end-of-run state against the cumulative trace.
contract Store {
    // ---- Adapter activity ----
    uint256 public totalSupplied;
    uint256 public totalWithdrawn;
    uint256 public totalSwapIn;
    uint256 public totalSwapOut;

    // ---- Vault share supply (cumulative) ----
    uint256 public cumulativeMinted;
    uint256 public cumulativeBurned;

    // ---- Vault pending-redeem tracking ----
    address[] private _pendingRecipientsList;
    mapping(address => bool) private _seenPendingRecipient;

    // ---- Pause snapshot ----
    bool public frozen;
    uint256 public frozenSupply;

    // ---- Fee tracking ----
    uint256 public cumulativeFeesAccrued;

    // ---- Approval-registry consistency at call time ----
    bool public approveTokenViolation;

    // ---- Swap output binding ----
    bool public swapOutputViolation;

    // ---- Oracle drift / timestamp / window-rotation ----
    bool public oracleViolation;

    function recordSupply(uint256 assets) external {
        totalSupplied += assets;
    }

    function recordWithdraw(uint256 assets) external {
        totalWithdrawn += assets;
    }

    function recordSwap(uint256 amountIn, uint256 amountOut) external {
        totalSwapIn += amountIn;
        totalSwapOut += amountOut;
    }

    function recordMint(uint256 shares) external {
        cumulativeMinted += shares;
    }

    function recordBurn(uint256 shares) external {
        cumulativeBurned += shares;
    }

    function recordPendingRecipient(address recipient) external {
        if (!_seenPendingRecipient[recipient]) {
            _seenPendingRecipient[recipient] = true;
            _pendingRecipientsList.push(recipient);
        }
    }

    function pendingRecipients() external view returns (address[] memory) {
        return _pendingRecipientsList;
    }

    function recordPause(uint256 totalSupplyAtPause) external {
        frozen = true;
        frozenSupply = totalSupplyAtPause;
    }

    function recordUnpause() external {
        frozen = false;
        frozenSupply = 0;
    }

    function recordFeeAccrued(uint256 amount) external {
        cumulativeFeesAccrued += amount;
    }

    function flagApproveTokenViolation() external {
        approveTokenViolation = true;
    }

    function flagSwapOutputViolation() external {
        swapOutputViolation = true;
    }

    function flagOracleViolation() external {
        oracleViolation = true;
    }
}
