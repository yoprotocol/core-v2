// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Minimal Lido withdrawal-queue stand-in. ERC-721 receipts + a queued/finalized state per
///         request. Tests can call `finalize(requestId, ethAmount)` to mark a request claimable.
/// @dev    Real Lido finalization happens via the protocol; here it's an explicit test-only call.
contract MockLidoWithdrawalQueue is ERC721 {
    error NotFinalized(uint256 requestId);
    error AlreadyClaimed(uint256 requestId);
    error NotOwner();
    error EthTransferFailed();

    IERC20 public immutable stETH;
    uint256 public nextRequestId = 1;

    struct Request {
        uint128 amount;
        uint128 finalizedEth;
        bool claimed;
    }

    mapping(uint256 requestId => Request) public requests;

    constructor(IERC20 _stETH) ERC721("Lido: stETH Withdrawal NFT", "unstETH") {
        stETH = _stETH;
    }

    receive() external payable { }

    function requestWithdrawals(
        uint256[] calldata amounts,
        address owner
    )
        external
        returns (uint256[] memory requestIds)
    {
        requestIds = new uint256[](amounts.length);
        for (uint256 i = 0; i < amounts.length; ++i) {
            stETH.transferFrom(msg.sender, address(this), amounts[i]);
            uint256 id = nextRequestId++;
            requests[id] = Request({ amount: uint128(amounts[i]), finalizedEth: 0, claimed: false });
            _mint(owner, id);
            requestIds[i] = id;
        }
    }

    /// @notice Test-only: mark a request as finalized at a specific ETH payout.
    function finalize(uint256 requestId, uint128 ethAmount) external {
        requests[requestId].finalizedEth = ethAmount;
    }

    function claimWithdrawal(uint256 requestId) external {
        Request storage r = requests[requestId];
        if (r.finalizedEth == 0) {
            revert NotFinalized(requestId);
        }
        if (r.claimed) {
            revert AlreadyClaimed(requestId);
        }
        if (ownerOf(requestId) != msg.sender) {
            revert NotOwner();
        }
        r.claimed = true;
        (bool ok,) = msg.sender.call{ value: r.finalizedEth }("");
        if (!ok) {
            revert EthTransferFailed();
        }
        _burn(requestId);
    }
}
