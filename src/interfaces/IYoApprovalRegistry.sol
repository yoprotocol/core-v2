// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice On-chain allowlist that bounds which `(token, spender, amount)` triples a vault may approve.
/// @dev    Read by `YoVault.approveToken`. Written exclusively by the protocol multisig (registry owner).
interface IYoApprovalRegistry {
    /*//////////////////////////////////////////////////////////////////////////
                                       EVENTS
    //////////////////////////////////////////////////////////////////////////*/

    event ApprovalSet(address indexed vault, address indexed token, address indexed spender, uint256 maxAmount);

    /*//////////////////////////////////////////////////////////////////////////
                                       ERRORS
    //////////////////////////////////////////////////////////////////////////*/

    error ZeroAddress();

    /*//////////////////////////////////////////////////////////////////////////
                                  STATE-CHANGING
    //////////////////////////////////////////////////////////////////////////*/

    function setApproval(address vault, address token, address spender, uint256 maxAmount) external;

    /*//////////////////////////////////////////////////////////////////////////
                                       VIEWS
    //////////////////////////////////////////////////////////////////////////*/

    function maxApproval(address vault, address token, address spender) external view returns (uint256 maxAmount);
}
