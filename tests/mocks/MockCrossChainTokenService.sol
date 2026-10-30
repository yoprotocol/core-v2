// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { ICrossChainTokenService } from "src/interfaces/external/ICrossChainTokenService.sol";

/// @notice Minimal CCTPx `FeeManager` stand-in: the sink that the service pays each quoted fee to.
contract MockCctpxFeeManager {
    receive() external payable { }
}

/// @notice Minimal per-token CCTPx `TokenManager` stand-in. Like the real one, it pulls the tokens from
///         the transfer's sender with its own `transferFrom`, so the sender must approve it (not the
///         service). It keeps the tokens instead of burning them, so tests can assert its balance.
contract MockCctpxTokenManager {
    using SafeERC20 for IERC20;

    error OnlyService(address caller);
    error AllowanceNotAmount(uint256 allowance, uint256 amount);

    IERC20 public immutable token;
    address public immutable service;

    /// @notice Test mode: `takeToken` pulls this much less than asked, so the caller keeps a live allowance.
    uint256 public shortfall;

    constructor(IERC20 _token, address _service) {
        token = _token;
        service = _service;
    }

    function setShortfall(uint256 _shortfall) external {
        shortfall = _shortfall;
    }

    /// @notice Pull `amount - shortfall` from `from`. Only the service calls it. Requires `from` to approve
    ///         exactly `amount`, so a caller that approves more (and leaves a live allowance) fails a test.
    function takeToken(address from, uint256 amount) external {
        if (msg.sender != service) {
            revert OnlyService(msg.sender);
        }
        uint256 allowance = token.allowance(from, address(this));
        if (allowance != amount) {
            revert AllowanceNotAmount(allowance, amount);
        }
        token.safeTransferFrom(from, address(this), amount - shortfall);
    }
}

/// @notice Minimal CCTPx `CrossChainTokenService` stand-in. A test quote is `abi.encode(uint256 fee)`
///         instead of Circle's signed, version-prefixed encoding. Like Circle's service, it pays the quote
///         total to the fee manager out of its OWN balance: it keeps any excess `msg.value` and covers a
///         shortfall from ETH that earlier callers left in it. Like the real service, it rejects plain ETH
///         transfers, so tests pre-fund it with `vm.deal`. It pulls `amount` from the caller through the
///         token's {MockCctpxTokenManager} and records every argument of the last transfer so tests can
///         assert what the adapter forwarded.
contract MockCrossChainTokenService is ICrossChainTokenService {
    error TokenNotRegistered(bytes32 tokenId);
    error FeePaymentFailed(uint256 fee, uint256 balance);

    struct LastTransfer {
        address caller;
        bytes32 tokenId;
        uint256 amount;
        uint32 destinationDomain;
        bytes destinationAddress;
        bytes32 destinationCaller;
        uint32 minFinalityThreshold;
        bytes signedQuote;
        address refundAddress;
        bool autoExecuteHookData;
        bytes hookData;
        uint256 value;
        uint256 fee;
    }

    MockCctpxFeeManager public immutable feeManager;

    mapping(bytes32 tokenId => address token) public tokens;
    mapping(bytes32 tokenId => MockCctpxTokenManager tokenManager) public tokenManagers;

    LastTransfer internal _last;
    uint256 public callCount;

    constructor(MockCctpxFeeManager _feeManager) {
        feeManager = _feeManager;
    }

    /// @notice Register `token` under `tokenId` and deploy its token manager.
    function register(bytes32 tokenId, IERC20 token) external returns (MockCctpxTokenManager tokenManager) {
        tokenManager = new MockCctpxTokenManager(token, address(this));
        tokens[tokenId] = address(token);
        tokenManagers[tokenId] = tokenManager;
    }

    /// @notice The last recorded transfer, as a struct (the public getter would drop its `bytes` fields).
    function last() external view returns (LastTransfer memory) {
        return _last;
    }

    /// @inheritdoc ICrossChainTokenService
    function crossChainTransfer(
        bytes32 tokenId,
        uint256 amount,
        uint32 destinationDomain,
        bytes calldata destinationAddress,
        bytes32 destinationCaller,
        uint32 minFinalityThreshold,
        QuoteClaim calldata claim,
        bool autoExecuteHookData,
        bytes calldata hookData
    )
        external
        payable
    {
        MockCctpxTokenManager tokenManager = MockCctpxTokenManager(resolveTokenManager(tokenId));
        tokenManager.takeToken(msg.sender, amount);

        uint256 fee = abi.decode(claim.signedQuote, (uint256));
        (bool paid,) = address(feeManager).call{ value: fee }("");
        if (!paid) {
            revert FeePaymentFailed(fee, address(this).balance);
        }

        _last = LastTransfer({
            caller: msg.sender,
            tokenId: tokenId,
            amount: amount,
            destinationDomain: destinationDomain,
            destinationAddress: destinationAddress,
            destinationCaller: destinationCaller,
            minFinalityThreshold: minFinalityThreshold,
            signedQuote: claim.signedQuote,
            refundAddress: claim.refundAddress,
            autoExecuteHookData: autoExecuteHookData,
            hookData: hookData,
            value: msg.value,
            fee: fee
        });
        ++callCount;
    }

    /// @inheritdoc ICrossChainTokenService
    function resolveTokenManager(bytes32 tokenId) public view returns (address) {
        address tokenManager = address(tokenManagers[tokenId]);
        if (tokenManager == address(0)) {
            revert TokenNotRegistered(tokenId);
        }
        return tokenManager;
    }

    /// @inheritdoc ICrossChainTokenService
    function resolveTokenAddress(bytes32 tokenId) external view returns (address) {
        address token = tokens[tokenId];
        if (token == address(0)) {
            revert TokenNotRegistered(tokenId);
        }
        return token;
    }

    /// @inheritdoc ICrossChainTokenService
    function feeService() external view returns (address) {
        return address(feeManager);
    }
}
