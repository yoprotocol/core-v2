// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Errors } from "@openzeppelin/contracts/utils/Errors.sol";
import { Vm } from "forge-std/src/Vm.sol";

import { Configure_CctpxVault, IRolesAuthorityCctpx } from "script/Configure_CctpxVault.s.sol";
import { Deploy_CctpxAdapter } from "script/Deploy_CctpxAdapter.s.sol";
import { YoCctpxAdapter } from "src/adapters/cctpx/YoCctpxAdapter.sol";
import { IYoApprovalRegistry } from "src/interfaces/IYoApprovalRegistry.sol";
import { IYoBridgeRouteRegistry } from "src/interfaces/IYoBridgeRouteRegistry.sol";
import { IYoCctpxAdapter } from "src/interfaces/IYoCctpxAdapter.sol";
import { IYoRegistry } from "src/interfaces/IYoRegistry.sol";
import { YoVault } from "src/YoVault.sol";

import { MockERC4626 } from "../../../mocks/MockERC4626.sol";
import { Fork_Test } from "../Fork_Test.t.sol";

/// @dev The FiatToken v2.2 (EURC) minting surface.
interface IFiatTokenMint {
    function masterMinter() external view returns (address);
    function configureMinter(address minter, uint256 minterAllowedAmount) external returns (bool);
    function mint(address to, uint256 amount) external returns (bool);
}

/// @dev The CCTP V2 `MessageTransmitterV2` surface that the delivery uses.
interface IMessageTransmitterV2 {
    function attesterManager() external view returns (address);
    function enableAttester(address attester) external;
    function setSignatureThreshold(uint256 newSignatureThreshold) external;
    function receiveMessage(bytes calldata message, bytes calldata attestation) external returns (bool);
}

/// @dev The CCTPx `FeeManager` (`CrossChainTokenService.feeService()`) quote decoder.
interface ICctpxFeeManager {
    function getQuoteTotal(bytes calldata signedQuote) external view returns (uint256 totalFee, address feeToken);
}

/// @dev Circle CCTPx errors: the source chain rejects a quote that does not fit the transfer, and the
///      destination rejects a fast message at or after its expiration block.
interface ICctpxErrors {
    error QuoteExpired(uint8 expiryMode, uint256 deadline, uint256 current);
    error PreFinalityFeeMismatch();
    error QuoteArgsMismatch(string quoteType, bytes32 quoteArgsHash);
    error MessageExpired(uint256 expirationBlock, uint256 currentBlock);
}

/// @notice End-to-end: live yoEUR vault → YoCctpxAdapter → real Circle CCTPx `CrossChainTokenService` on Base
///         and Ethereum, paid with live signed Iris quotes, then delivery of the burn message through the
///         destination `MessageTransmitterV2`.
///
///         Each chain deploys the adapter with {Deploy_CctpxAdapter} at its CREATE2 address and runs the
///         {Configure_CctpxVault} Safe batch as the yoEUR owner Safe. The live role-12 operator then
///         approves the adapter and bridges through the batch `manage`, paying the quoted fee from the
///         vault's ETH. On the destination fork, a test attester replaces Circle's attesters (threshold 1),
///         signs the message as Iris would attest it, and a relayer calls `receiveMessage`. Iris fills the
///         fields that the source leaves zero: the header nonce and executed finality, and for a fast message
///         the body's `expirationBlock` (delivery does not read `feeExecuted`: the fee is paid on the source).
///
///         Fixtures: Iris `POST /v2/quote/cctpx/{EURC tokenId}/{src}/{dst}` responses for `AMOUNT`, fee in
///         native gas, no `FORWARD` request (self-relay), recorded on 2026-10-29. Each fork block is the
///         chain head read right after the quote, so it is inside the quote's validity
///         (`block.number <= expiresAtBlock`). The quote nonce is 0, so a quote is reusable until expiry.
contract CctpxForkTest is Fork_Test {
    /// @dev Base head after the Base quotes (issuedAt 1_793_307_017).
    uint256 internal constant BASE_BLOCK = 53_258_835;
    /// @dev Ethereum head after the Ethereum quote (issuedAt 1_793_307_024).
    uint256 internal constant MAINNET_BLOCK = 26_300_899;

    uint256 internal constant AMOUNT = 100e6;
    uint32 internal constant ETHEREUM_DOMAIN = 0;
    uint32 internal constant BASE_DOMAIN = 6;
    uint32 internal constant STANDARD_FINALITY = 2000;
    uint32 internal constant FAST_FINALITY = 1000;
    /// @dev `QuoteExpired` mode for a block-number deadline.
    uint8 internal constant EXPIRY_MODE_BLOCK_NUMBER = 1;

    /// @dev Base → Ethereum, standard: one `PROTOCOL` item. keccak 0x47c39335…edb618.
    uint256 internal constant BASE_STD_FEE = 110_858_231_168_236;
    /// @dev Base → Ethereum, fast: `PRE_FINALITY` 4_958_701_983_143 + `PROTOCOL`. keccak 0x4b7b818d…6c43b2.
    uint256 internal constant BASE_FAST_FEE = 115_816_933_151_379;
    /// @dev Both Base quotes expire after this block.
    uint256 internal constant BASE_QUOTE_EXPIRES_AT = 53_258_895;
    /// @dev Ethereum → Base, standard: one `PROTOCOL` item. keccak 0xf806e359…48cb1a.
    uint256 internal constant ETHEREUM_STD_FEE = 110_858_231_168_236;

    bytes internal constant BASE_STD_QUOTE = hex"0100000000000000000000000000000000000000000000000000000000000000"
        hex"2000000000000000000000000000000000000000000000000000000000000000"
        hex"a001000000000000000000000000000000000000000000000000000000032caa"
        hex"8f00000000000000000000000000000000000000000000000000000000000000"
        hex"0000000000000000000000000000000000000000000000000000000000000000"
        hex"0000000000000000000000000000000000000000000000000000000000000001"
        hex"8000000000000000000000000000000000000000000000000000000000000000"
        hex"0100000000000000000000000000000000000000000000000000000000000000"
        hex"2000000000000000000000000000000000000000000000000000000000000000"
        hex"602630b9e951a729c68427e7d5f719547078689fff6474e6642c16892202fec0"
        hex"1c000000000000000000000000000000000000000000000000000064d3317d3c"
        hex"ec00000000000000000000000000000000000000000000000000000000000000"
        hex"0850524f544f434f4c0000000000000000000000000000000000000000000000"
        hex"0000000000000000000000000000000000000000000000000000000000000000"
        hex"41a07ff7f00f26ab8e2e3967f18837bd9335eeb20f0661927e92a3505ebeb33e"
        hex"9a003805b17a031e096d2ac6849742bd3b3af70fd0578d16973b21780c868db6"
        hex"6c1b000000000000000000000000000000000000000000000000000000000000" hex"00";
    bytes internal constant BASE_FAST_QUOTE = hex"0100000000000000000000000000000000000000000000000000000000000000"
        hex"2000000000000000000000000000000000000000000000000000000000000000"
        hex"a001000000000000000000000000000000000000000000000000000000032caa"
        hex"8f00000000000000000000000000000000000000000000000000000000000000"
        hex"0000000000000000000000000000000000000000000000000000000000000000"
        hex"0000000000000000000000000000000000000000000000000000000000000002"
        hex"4000000000000000000000000000000000000000000000000000000000000000"
        hex"0200000000000000000000000000000000000000000000000000000000000000"
        hex"4000000000000000000000000000000000000000000000000000000000000000"
        hex"e000000000000000000000000000000000000000000000000000000000000000"
        hex"60616f2e49634af5af892fcac3c3bbd721cf6eaf9f699be3d69a19491c13279b"
        hex"210000000000000000000000000000000000000000000000000000048289ab95"
        hex"a700000000000000000000000000000000000000000000000000000000000000"
        hex"0c5052455f46494e414c49545900000000000000000000000000000000000000"
        hex"0000000000000000000000000000000000000000000000000000000000000000"
        hex"602630b9e951a729c68427e7d5f719547078689fff6474e6642c16892202fec0"
        hex"1c000000000000000000000000000000000000000000000000000064d3317d3c"
        hex"ec00000000000000000000000000000000000000000000000000000000000000"
        hex"0850524f544f434f4c0000000000000000000000000000000000000000000000"
        hex"0000000000000000000000000000000000000000000000000000000000000000"
        hex"410a0f0b06dec25e5173d7e4a62323fb077d5d37693a9928028aafacc8c70bf4"
        hex"2f4b06c6089ec55acea66ca7f6b5865ed170993c869200935e0d7cb21438e9f8"
        hex"7c1b000000000000000000000000000000000000000000000000000000000000" hex"00";
    bytes internal constant ETHEREUM_STD_QUOTE = hex"0100000000000000000000000000000000000000000000000000000000000000"
        hex"2000000000000000000000000000000000000000000000000000000000000000"
        hex"a001000000000000000000000000000000000000000000000000000000019151"
        hex"f000000000000000000000000000000000000000000000000000000000000000"
        hex"0000000000000000000000000000000000000000000000000000000000000000"
        hex"0000000000000000000000000000000000000000000000000000000000000001"
        hex"8000000000000000000000000000000000000000000000000000000000000000"
        hex"0100000000000000000000000000000000000000000000000000000000000000"
        hex"2000000000000000000000000000000000000000000000000000000000000000"
        hex"602630b9e951a729c68427e7d5f719547078689fff6474e6642c16892202fec0"
        hex"1c000000000000000000000000000000000000000000000000000064d3317d3c"
        hex"ec00000000000000000000000000000000000000000000000000000000000000"
        hex"0850524f544f434f4c0000000000000000000000000000000000000000000000"
        hex"0000000000000000000000000000000000000000000000000000000000000000"
        hex"415d3e5e3714f186ee7c8964deca9eda46d6af8347850627f741874d7beb2654"
        hex"d86c07a05d552b5e2f3b3ff70fc1ae4a766646a5f1e69395309c65f7ed467dd8"
        hex"6b1b000000000000000000000000000000000000000000000000000000000000" hex"00";

    YoVault internal constant YO_EUR = YoVault(payable(0x50c749aE210D3977ADC824AE11F3c7fd10c871e9));
    /// @dev Holds role 12 on yoEUR's `RolesAuthority` on both chains.
    address internal constant OPERATOR = 0x93e5260Ac975B475aF8BF818c14DEEE7fEfd5927;
    uint8 internal constant OPERATOR_ROLE = 12;
    IYoRegistry internal constant YO_REGISTRY = IYoRegistry(0x56c3119DC3B1a75763C87D5B0A2C55E489502232);
    IYoBridgeRouteRegistry internal constant ROUTE_REGISTRY =
        IYoBridgeRouteRegistry(0x5973cE676fBe8bE0ec1D2d2F371d989374FB672b);
    /// @dev The yoEUR EURC cap of the other bridge adapters.
    uint256 internal constant APPROVAL_CAP = 877_000e6;
    uint256 internal constant ETH_TOP_UP = 0.05 ether;
    /// @dev The Safe holds less than `ETH_TOP_UP` at the fork blocks; the end-to-end script run uses this.
    uint256 internal constant RUN_TOP_UP = 0.01 ether;
    /// @dev A file name of its own, so the end-to-end script run does not overwrite a real batch.
    string internal constant RUN_BATCH_SLUG = "yoeur-cctpx-enable-fork-test";

    /// @dev Circle CCTPx and CCTP V2, the same addresses on both chains.
    address internal constant SERVICE = 0x431871229103b780868f8C6BB820cd16ECf942BC;
    address internal constant FEE_MANAGER = 0x88e0FEE76fE71F467009DFddcfa759dDc6B1a575;
    address internal constant TOKEN_MANAGER = 0x8c27579e24F9f19D96724e19fC059dAcd1469e10;
    IMessageTransmitterV2 internal constant MESSAGE_TRANSMITTER =
        IMessageTransmitterV2(0x81D40F21F12A8F0E3252Bccb954D722d4c464B64);
    bytes32 internal constant TOKEN_ID = 0x6ca9e29fa53becc29becaf4a90b9ca7a995ad4d2234880da13ca38c657fb241c;
    IERC20 internal constant ETHEREUM_EURC = IERC20(0x1aBaEA1f7C830bD89Acc67eC4af516284b1bC33c);
    IERC20 internal constant BASE_EURC = IERC20(0x60a3E35Cc302bFA44Cb288Bc5a4F316Fdb1adb42);

    /// @dev yoUSD on Ethereum: an ERC-4626 vault of USDC, not of EURC.
    address internal constant YO_USD = 0x0000000f2eB9f69274678c76222B35eEc7588a65;
    address internal constant ETHEREUM_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    /// @dev Length of a CCTPx transfer message with 20-byte addresses and no hook data: the 148-byte
    ///      `MessageV2` header and the 193-byte `TransferMessage` body.
    uint256 internal constant MESSAGE_LENGTH = 341;
    /// @dev Blocks from the fast attestation to the message's `expirationBlock`, for the test attestation.
    uint256 internal constant FAST_EXPIRY_BLOCKS = 50;

    uint256 internal ethereumFork;
    uint256 internal baseFork;
    YoCctpxAdapter internal ethereumAdapter;
    YoCctpxAdapter internal baseAdapter;

    function setUp() public {
        _maybeSkip(_forkIfAvailable("MAINNET_RPC_URL", MAINNET_BLOCK), "MAINNET_RPC_URL");
        ethereumFork = vm.activeFork();
        ethereumAdapter = _deployAndEnable();

        _maybeSkip(_forkIfAvailable("BASE_RPC_URL", BASE_BLOCK), "BASE_RPC_URL");
        baseFork = vm.activeFork();
        baseAdapter = _deployAndEnable();

        vm.label(address(YO_EUR), "yoEUR");
        vm.label(OPERATOR, "Operator");
        vm.label(SERVICE, "CrossChainTokenService");
        vm.label(FEE_MANAGER, "CctpxFeeManager");
        vm.label(TOKEN_MANAGER, "EurcTokenManager");
        vm.label(address(MESSAGE_TRANSMITTER), "MessageTransmitterV2");
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    TRANSFERS
    //////////////////////////////////////////////////////////////////////////*/

    function testFork_Cctpx_BaseToEthereum_Standard() external {
        vm.selectFork(baseFork);
        bytes memory message =
            _bridge(baseAdapter, BASE_EURC, ETHEREUM_DOMAIN, STANDARD_FINALITY, BASE_STD_QUOTE, BASE_STD_FEE);
        _assertMessage(message, BASE_DOMAIN, ETHEREUM_DOMAIN, STANDARD_FINALITY, address(baseAdapter));

        vm.selectFork(ethereumFork);
        _deliver(message, ETHEREUM_EURC);
    }

    function testFork_Cctpx_EthereumToBase_Standard() external {
        vm.selectFork(ethereumFork);
        bytes memory message = _bridge(
            ethereumAdapter, ETHEREUM_EURC, BASE_DOMAIN, STANDARD_FINALITY, ETHEREUM_STD_QUOTE, ETHEREUM_STD_FEE
        );
        _assertMessage(message, ETHEREUM_DOMAIN, BASE_DOMAIN, STANDARD_FINALITY, address(ethereumAdapter));

        vm.selectFork(baseFork);
        _deliver(message, BASE_EURC);
    }

    /// @dev Source side. The `FastMessage` tests deliver it.
    function testFork_Cctpx_BaseToEthereum_Fast() external {
        vm.selectFork(baseFork);
        bytes memory message =
            _bridge(baseAdapter, BASE_EURC, ETHEREUM_DOMAIN, FAST_FINALITY, BASE_FAST_QUOTE, BASE_FAST_FEE);
        _assertMessage(message, BASE_DOMAIN, ETHEREUM_DOMAIN, FAST_FINALITY, address(baseAdapter));
    }

    /// @dev Each fixture fee is Iris' `feeTotalAmount`; the live fee manager decodes the same total.
    function testFork_Cctpx_QuoteTotalEqualsIrisFee() external {
        vm.selectFork(baseFork);
        _assertQuoteTotal(BASE_STD_QUOTE, BASE_STD_FEE);
        _assertQuoteTotal(BASE_FAST_QUOTE, BASE_FAST_FEE);

        vm.selectFork(ethereumFork);
        _assertQuoteTotal(ETHEREUM_STD_QUOTE, ETHEREUM_STD_FEE);
    }

    /// @dev A standard quote binds only the token id (its `PROTOCOL` item), not the amount: Iris need not
    ///      be asked again when the amount changes inside the quote's validity.
    function testFork_Cctpx_StandardQuote_AnyAmount() external {
        vm.selectFork(baseFork);
        uint256 otherAmount = AMOUNT / 2;
        _mintEurc(BASE_EURC, otherAmount);
        vm.prank(OPERATOR);
        YO_EUR.approveToken(address(BASE_EURC), address(baseAdapter), otherAmount);

        bytes memory call = abi.encodeCall(
            YoCctpxAdapter.crossChainTransfer,
            (otherAmount, ETHEREUM_DOMAIN, address(YO_EUR), STANDARD_FINALITY, BASE_STD_QUOTE)
        );
        uint256 sent = abi.decode(_manage(baseAdapter, call, BASE_STD_FEE)[0], (uint256));
        assertEq(sent, otherAmount, "return");
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  FAST DELIVERY
    //////////////////////////////////////////////////////////////////////////*/

    function testFork_Cctpx_FastMessage_DeliversBeforeExpiry() external {
        (bytes memory sourceMessage, uint256 expirationBlock) = _fastMessageOnEthereum();
        vm.roll(expirationBlock - 1);

        _assertDelivers(_attested(sourceMessage, FAST_FINALITY, expirationBlock), ETHEREUM_EURC);
    }

    function testFork_Cctpx_FastMessage_RevertWhen_Expired() external {
        (bytes memory sourceMessage, uint256 expirationBlock) = _fastMessageOnEthereum();
        vm.roll(expirationBlock);

        vm.expectRevert(abi.encodeWithSelector(ICctpxErrors.MessageExpired.selector, expirationBlock, expirationBlock));
        _receive(_attested(sourceMessage, FAST_FINALITY, expirationBlock));
    }

    /// @dev After the expiry, Iris attests the same message (same nonce and body) again at finality. The
    ///      finalized path does not read `expirationBlock`, so the burned EURC is not lost.
    function testFork_Cctpx_FastMessage_DeliversAtFinalityAfterExpiry() external {
        (bytes memory sourceMessage, uint256 expirationBlock) = _fastMessageOnEthereum();
        vm.roll(expirationBlock + 1);

        vm.expectRevert(
            abi.encodeWithSelector(ICctpxErrors.MessageExpired.selector, expirationBlock, expirationBlock + 1)
        );
        _receive(_attested(sourceMessage, FAST_FINALITY, expirationBlock));

        _assertDelivers(_attested(sourceMessage, STANDARD_FINALITY, expirationBlock), ETHEREUM_EURC);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                 SAFE BATCH CHECKS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Before it builds the batch, {Configure_CctpxVault} requires the recipient to be a YO vault of EURC
    ///      on the counterpart chain, read on a fork of that chain.
    function testFork_Cctpx_ConfigureRequiresEurcYoVaultRecipient() external {
        vm.selectFork(baseFork);
        Configure_CctpxVault script = new Configure_CctpxVault();
        // The script selects the counterpart fork and returns, so it must exist on both forks.
        vm.makePersistent(address(script));
        Configure_CctpxVault.Inputs memory inputs = _inputs(script, baseAdapter);
        string memory ethereumRpc = vm.envString("MAINNET_RPC_URL");

        script.checkRecipient(inputs, ethereumRpc);
        assertEq(vm.activeFork(), baseFork, "source fork not selected again");

        inputs.recipient = address(0xDEAD);
        vm.expectRevert(abi.encodeWithSelector(Configure_CctpxVault.RecipientNotVault.selector, address(0xDEAD)));
        script.checkRecipient(inputs, ethereumRpc);
        vm.selectFork(baseFork);

        // yoUSD is an ERC-4626 vault on Ethereum, but of USDC.
        inputs.recipient = YO_USD;
        vm.expectRevert(
            abi.encodeWithSelector(
                Configure_CctpxVault.RecipientAssetNotEurc.selector, YO_USD, ETHEREUM_USDC, address(ETHEREUM_EURC)
            )
        );
        script.checkRecipient(inputs, ethereumRpc);
        vm.selectFork(baseFork);

        // An ERC-4626 vault of EURC that is not a YO vault. Persistent, so the script's new Ethereum fork has it.
        vm.selectFork(ethereumFork);
        MockERC4626 notYoVault = new MockERC4626(ETHEREUM_EURC, "Not a YO vault", "nYO");
        vm.makePersistent(address(notYoVault));
        vm.selectFork(baseFork);
        inputs.recipient = address(notYoVault);
        vm.expectRevert(abi.encodeWithSelector(Configure_CctpxVault.RecipientNotYoVault.selector, address(notYoVault)));
        script.checkRecipient(inputs, ethereumRpc);
        vm.selectFork(baseFork);

        // An rpc of the source chain, not the counterpart.
        vm.expectRevert(
            abi.encodeWithSelector(Configure_CctpxVault.CounterpartChainMismatch.selector, 1, block.chainid)
        );
        script.checkRecipient(inputs, vm.envString("BASE_RPC_URL"));
    }

    /// @dev Runs {Configure_CctpxVault} as ops does, from env vars, on a new Base fork where nothing is enabled
    ///      yet, and parses the Safe Transaction Builder file that it writes. The file has a name of its own
    ///      (`RUN_BATCH_SLUG`), and the test removes it.
    function testFork_Cctpx_ConfigureRun_WritesSafeBatch() external {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), BASE_BLOCK);
        vm.setEnv("VAULT", vm.toString(address(YO_EUR)));
        vm.setEnv("VAULT_ETH_TOP_UP", vm.toString(RUN_TOP_UP));
        vm.setEnv("BATCH_SLUG", RUN_BATCH_SLUG);
        vm.setEnv("YO_REGISTRY", vm.toString(address(YO_REGISTRY)));
        vm.setEnv("YO_BRIDGE_ROUTE_REGISTRY", vm.toString(address(ROUTE_REGISTRY)));
        address adapter = new Deploy_CctpxAdapter().predictAddress(ROUTE_REGISTRY, YO_REGISTRY);
        assertEq(adapter, address(baseAdapter), "predicted adapter");
        assertEq(adapter.code.length, 0, "adapter deployed on the new fork");

        Configure_CctpxVault script = new Configure_CctpxVault();
        // The script checks the recipient on an Ethereum fork and returns.
        vm.makePersistent(address(script));
        script.run();

        string memory path = string.concat("script/safe-batches/yo-base-", RUN_BATCH_SLUG, "-safe.json");
        string memory json = vm.readFile(path);
        vm.removeFile(path);

        assertEq(vm.parseJsonString(json, ".chainId"), "8453", "chainId");
        assertEq(vm.parseJsonAddress(json, ".meta.createdFromSafeAddress"), YO_EUR.owner(), "Safe");
        assertTrue(vm.keyExistsJson(json, ".transactions[3]"), "fewer than 4 transactions");
        assertFalse(vm.keyExistsJson(json, ".transactions[4]"), "more than 4 transactions");
        _assertBatchCall(
            json,
            0,
            address(YO_EUR.approvalRegistry()),
            0,
            abi.encodeCall(
                IYoApprovalRegistry.setApproval, (address(YO_EUR), address(BASE_EURC), adapter, APPROVAL_CAP)
            )
        );
        _assertBatchCall(
            json,
            1,
            address(ROUTE_REGISTRY),
            0,
            abi.encodeCall(
                IYoBridgeRouteRegistry.setRoute,
                (
                    address(YO_EUR),
                    adapter,
                    address(BASE_EURC),
                    ETHEREUM_DOMAIN,
                    bytes32(uint256(uint160(address(YO_EUR)))),
                    bytes32(0),
                    true
                )
            )
        );
        _assertBatchCall(
            json,
            2,
            address(YO_EUR.authority()),
            0,
            abi.encodeCall(
                IRolesAuthorityCctpx.setRoleCapability,
                (OPERATOR_ROLE, adapter, YoCctpxAdapter.crossChainTransfer.selector, true)
            )
        );
        _assertBatchCall(json, 3, address(YO_EUR), RUN_TOP_UP, "");
    }

    /*//////////////////////////////////////////////////////////////////////////
                                     REVERTS
    //////////////////////////////////////////////////////////////////////////*/

    function testFork_Cctpx_RevertWhen_QuoteExpired() external {
        vm.selectFork(baseFork);
        _approve(baseAdapter, BASE_EURC);
        vm.roll(BASE_QUOTE_EXPIRES_AT + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                ICctpxErrors.QuoteExpired.selector,
                EXPIRY_MODE_BLOCK_NUMBER,
                BASE_QUOTE_EXPIRES_AT,
                BASE_QUOTE_EXPIRES_AT + 1
            )
        );
        _manage(baseAdapter, _call(ETHEREUM_DOMAIN, address(YO_EUR), STANDARD_FINALITY, BASE_STD_QUOTE), BASE_STD_FEE);
    }

    /// @dev The live service pays the quote total out of its own balance. On Base it holds a few gwei that
    ///      earlier callers left: a 1-wei shortfall is covered (the adapter catches it), a full one is not.
    function testFork_Cctpx_RevertWhen_MsgValueNotQuoteTotal() external {
        vm.selectFork(baseFork);
        _approve(baseAdapter, BASE_EURC);
        bytes memory call = _call(ETHEREUM_DOMAIN, address(YO_EUR), STANDARD_FINALITY, BASE_STD_QUOTE);
        assertGt(SERVICE.balance, 0, "service holds no ETH from earlier callers");
        assertLt(SERVICE.balance, BASE_STD_FEE, "service could pay the whole fee");

        vm.expectRevert(
            abi.encodeWithSelector(IYoCctpxAdapter.IncorrectNativeFee.selector, BASE_STD_FEE - 1, BASE_STD_FEE)
        );
        _manage(baseAdapter, call, BASE_STD_FEE - 1);

        vm.expectRevert(
            abi.encodeWithSelector(IYoCctpxAdapter.IncorrectNativeFee.selector, BASE_STD_FEE + 1, BASE_STD_FEE)
        );
        _manage(baseAdapter, call, BASE_STD_FEE + 1);

        // The service cannot pay the fee itself: its ETH transfer to the fee manager fails.
        vm.expectRevert(Errors.FailedCall.selector);
        _manage(baseAdapter, call, 0);
    }

    /// @dev On Ethereum the service holds more ETH than the whole fee: without the adapter's check, a
    ///      transfer with no `msg.value` would go through, paid by other callers' ETH.
    function testFork_Cctpx_RevertWhen_ServiceWouldPayTheFee() external {
        vm.selectFork(ethereumFork);
        _approve(ethereumAdapter, ETHEREUM_EURC);
        assertGt(SERVICE.balance, ETHEREUM_STD_FEE, "service cannot pay the whole fee");

        vm.expectRevert(abi.encodeWithSelector(IYoCctpxAdapter.IncorrectNativeFee.selector, 0, ETHEREUM_STD_FEE));
        _manage(ethereumAdapter, _call(BASE_DOMAIN, address(YO_EUR), STANDARD_FINALITY, ETHEREUM_STD_QUOTE), 0);
    }

    function testFork_Cctpx_RevertWhen_MsgValueAboveCap() external {
        vm.selectFork(baseFork);
        _approve(baseAdapter, BASE_EURC);
        uint256 cap = baseAdapter.maxNativeFee();
        assertEq(cap, 0.02 ether, "production cap");

        vm.expectRevert(abi.encodeWithSelector(IYoCctpxAdapter.NativeFeeTooHigh.selector, cap + 1, cap));
        _manage(baseAdapter, _call(ETHEREUM_DOMAIN, address(YO_EUR), STANDARD_FINALITY, BASE_STD_QUOTE), cap + 1);
    }

    function testFork_Cctpx_RevertWhen_FinalityNotQuoted() external {
        vm.selectFork(baseFork);
        _approve(baseAdapter, BASE_EURC);

        // Neither tier: the adapter rejects it before Circle.
        vm.expectRevert(abi.encodeWithSelector(IYoCctpxAdapter.InvalidFinalityThreshold.selector, uint32(1500)));
        _manage(baseAdapter, _call(ETHEREUM_DOMAIN, address(YO_EUR), 1500, BASE_STD_QUOTE), BASE_STD_FEE);

        // A fast transfer with a standard quote (no `PRE_FINALITY` item).
        vm.expectRevert(ICctpxErrors.PreFinalityFeeMismatch.selector);
        _manage(baseAdapter, _call(ETHEREUM_DOMAIN, address(YO_EUR), FAST_FINALITY, BASE_STD_QUOTE), BASE_STD_FEE);

        // A standard transfer with a fast quote.
        vm.expectRevert(ICctpxErrors.PreFinalityFeeMismatch.selector);
        _manage(baseAdapter, _call(ETHEREUM_DOMAIN, address(YO_EUR), STANDARD_FINALITY, BASE_FAST_QUOTE), BASE_FAST_FEE);
    }

    /// @dev A fast quote's `PRE_FINALITY` item binds the amount and the destination domain.
    function testFork_Cctpx_RevertWhen_FastQuoteAmountDiffers() external {
        vm.selectFork(baseFork);
        _approve(baseAdapter, BASE_EURC);
        bytes memory call = abi.encodeCall(
            YoCctpxAdapter.crossChainTransfer,
            (AMOUNT - 1, ETHEREUM_DOMAIN, address(YO_EUR), FAST_FINALITY, BASE_FAST_QUOTE)
        );

        vm.expectPartialRevert(ICctpxErrors.QuoteArgsMismatch.selector);
        _manage(baseAdapter, call, BASE_FAST_FEE);
    }

    function testFork_Cctpx_RevertWhen_RouteNotAllowed() external {
        vm.selectFork(baseFork);
        _approve(baseAdapter, BASE_EURC);

        // Not the counterpart vault.
        address stranger = address(0xDEAD);
        vm.expectRevert(abi.encodeWithSelector(IYoCctpxAdapter.RouteNotAllowed.selector, ETHEREUM_DOMAIN, stranger));
        _manage(baseAdapter, _call(ETHEREUM_DOMAIN, stranger, STANDARD_FINALITY, BASE_STD_QUOTE), BASE_STD_FEE);

        // Not the allowlisted domain.
        vm.expectRevert(abi.encodeWithSelector(IYoCctpxAdapter.RouteNotAllowed.selector, BASE_DOMAIN, address(YO_EUR)));
        _manage(baseAdapter, _call(BASE_DOMAIN, address(YO_EUR), STANDARD_FINALITY, BASE_STD_QUOTE), BASE_STD_FEE);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                     HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Deploy the adapter on the active fork and run the Safe batch, as ops would. The Safe gets the
    ///      top-up first: the live Safe may hold less ETH than `ETH_TOP_UP`.
    function _deployAndEnable() internal returns (YoCctpxAdapter adapter) {
        adapter = new Deploy_CctpxAdapter().deploy(ROUTE_REGISTRY, YO_REGISTRY);

        Configure_CctpxVault script = new Configure_CctpxVault();
        Configure_CctpxVault.Inputs memory inputs = _inputs(script, adapter);
        address safe = YO_EUR.owner();
        vm.deal(safe, safe.balance + ETH_TOP_UP);
        uint256 vaultEth = address(YO_EUR).balance;

        script.execute(safe, script.build(inputs));
        script.verify(inputs);
        assertEq(address(YO_EUR).balance, vaultEth + ETH_TOP_UP, "vault ETH top-up");
        inputs.ethTopUp = 0;
        assertEq(script.build(inputs).length, 0, "a rebuilt batch without a top-up is empty");
        vm.label(address(adapter), "YoCctpxAdapter");
    }

    /// @dev The Safe batch inputs for yoEUR on the active fork, as ops runs the script.
    function _inputs(
        Configure_CctpxVault script,
        YoCctpxAdapter adapter
    )
        internal
        view
        returns (Configure_CctpxVault.Inputs memory)
    {
        return Configure_CctpxVault.Inputs({
            vault: YO_EUR,
            adapter: address(adapter),
            routeRegistry: ROUTE_REGISTRY,
            yoRegistry: YO_REGISTRY,
            destinationDomain: script.counterpartDomain(),
            recipient: address(YO_EUR),
            approvalCap: APPROVAL_CAP,
            operatorRole: OPERATOR_ROLE,
            ethTopUp: ETH_TOP_UP
        });
    }

    /// @dev Transaction `index` of a Safe Transaction Builder file.
    function _assertBatchCall(
        string memory json,
        uint256 index,
        address to,
        uint256 value,
        bytes memory data
    )
        internal
        pure
    {
        string memory key = string.concat(".transactions[", vm.toString(index), "]");
        assertEq(vm.parseJsonAddress(json, string.concat(key, ".to")), to, "to");
        assertEq(vm.parseJsonString(json, string.concat(key, ".value")), vm.toString(value), "value");
        assertEq(vm.parseJsonBytes(json, string.concat(key, ".data")), data, "data");
    }

    /// @dev Bridge with the fast fixture on Base, then select Ethereum and enable the test attester. Iris
    ///      sets `expirationBlock` to a later destination block; the distance here is arbitrary.
    function _fastMessageOnEthereum() internal returns (bytes memory sourceMessage, uint256 expirationBlock) {
        vm.selectFork(baseFork);
        sourceMessage = _bridge(baseAdapter, BASE_EURC, ETHEREUM_DOMAIN, FAST_FINALITY, BASE_FAST_QUOTE, BASE_FAST_FEE);
        vm.selectFork(ethereumFork);
        _enableTestAttester();
        expirationBlock = block.number + FAST_EXPIRY_BLOCKS;
    }

    /// @dev Bridge `AMOUNT` from yoEUR to yoEUR on `destinationDomain` and return the `MessageSent` message.
    ///      Asserts the source side: the vault pays exactly `fee` and `AMOUNT`, the EURC is burned, and the
    ///      adapter keeps nothing.
    function _bridge(
        YoCctpxAdapter adapter,
        IERC20 eurc,
        uint32 destinationDomain,
        uint32 finality,
        bytes memory quote,
        uint256 fee
    )
        internal
        returns (bytes memory message)
    {
        _approve(adapter, eurc);
        uint256 vaultEurc = eurc.balanceOf(address(YO_EUR));
        uint256 vaultEth = address(YO_EUR).balance;
        uint256 supply = eurc.totalSupply();

        vm.recordLogs();
        bytes[] memory results = _manage(adapter, _call(destinationDomain, address(YO_EUR), finality, quote), fee);
        message = _messageSent(vm.getRecordedLogs());

        assertEq(abi.decode(results[0], (uint256)), AMOUNT, "return");
        assertEq(eurc.balanceOf(address(YO_EUR)), vaultEurc - AMOUNT, "vault EURC");
        assertEq(address(YO_EUR).balance, vaultEth - fee, "vault paid other than the fee");
        assertEq(eurc.totalSupply(), supply - AMOUNT, "EURC not burned");
        assertEq(eurc.balanceOf(address(adapter)), 0, "adapter EURC");
        assertEq(address(adapter).balance, 0, "adapter ETH");
        assertEq(eurc.allowance(address(adapter), TOKEN_MANAGER), 0, "adapter allowance to the token manager");
        assertEq(eurc.allowance(address(YO_EUR), address(adapter)), 0, "vault allowance to the adapter");
    }

    /// @dev Deliver the standard `sourceMessage` on the active (destination) fork.
    function _deliver(bytes memory sourceMessage, IERC20 eurc) internal {
        _enableTestAttester();
        _assertDelivers(_attested(sourceMessage, STANDARD_FINALITY, 0), eurc);
    }

    /// @dev Deliver the attested `message` and assert yoEUR got exactly `AMOUNT`, newly minted.
    function _assertDelivers(bytes memory message, IERC20 eurc) internal {
        uint256 vaultEurc = eurc.balanceOf(address(YO_EUR));
        uint256 supply = eurc.totalSupply();

        assertTrue(_receive(message), "receiveMessage");

        assertEq(eurc.balanceOf(address(YO_EUR)), vaultEurc + AMOUNT, "destination vault EURC");
        assertEq(eurc.totalSupply(), supply + AMOUNT, "EURC not minted");
    }

    /// @dev Make the test attester the only signature `MessageTransmitterV2` needs on the active fork.
    function _enableTestAttester() internal {
        vm.startPrank(MESSAGE_TRANSMITTER.attesterManager());
        MESSAGE_TRANSMITTER.enableAttester(makeAddr("CctpxTestAttester"));
        MESSAGE_TRANSMITTER.setSignatureThreshold(1);
        vm.stopPrank();
    }

    /// @dev Sign `message` with the test attester and relay it. `destinationCaller` is zero, so any relayer
    ///      may deliver.
    function _receive(bytes memory message) internal returns (bool) {
        (, uint256 attesterKey) = makeAddrAndKey("CctpxTestAttester");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attesterKey, keccak256(message));
        vm.prank(makeAddr("Relayer"));
        return MESSAGE_TRANSMITTER.receiveMessage(message, abi.encodePacked(r, s, v));
    }

    /// @dev The message as Iris attests it. The source leaves these fields zero: in the header, the nonce
    ///      (unique; a re-attestation keeps it) and `finalityThresholdExecuted`; in the body, `expirationBlock`
    ///      (fast messages only; 0 is no expiry). `feeExecuted` stays zero: delivery does not read it.
    function _attested(
        bytes memory sourceMessage,
        uint32 finality,
        uint256 expirationBlock
    )
        internal
        pure
        returns (bytes memory message)
    {
        message = bytes.concat(sourceMessage);
        bytes32 nonce = keccak256(sourceMessage);
        assembly ("memory-safe") {
            let header := add(message, 32)
            // nonce: bytes [12, 44).
            mstore(add(header, 12), nonce)
            // finalityThresholdExecuted: bytes [144, 148). Keep the 28 bytes after it.
            let word := mload(add(header, 144))
            mstore(add(header, 144), or(shl(224, finality), and(word, sub(shl(224, 1), 1))))
            // Body (from byte 148) expirationBlock: bytes [76, 108) of the body.
            mstore(add(header, 224), expirationBlock)
        }
    }

    function _approve(YoCctpxAdapter adapter, IERC20 eurc) internal {
        _mintEurc(eurc, AMOUNT);
        vm.prank(OPERATOR);
        YO_EUR.approveToken(address(eurc), address(adapter), AMOUNT);
    }

    /// @dev Mint EURC to yoEUR through the master minter. `deal` would write FiatToken v2.2's packed
    ///      balance-and-denylist slot.
    function _mintEurc(IERC20 eurc, uint256 amount) internal {
        IFiatTokenMint fiatToken = IFiatTokenMint(address(eurc));
        vm.prank(fiatToken.masterMinter());
        fiatToken.configureMinter(address(this), amount);
        fiatToken.mint(address(YO_EUR), amount);
    }

    function _call(
        uint32 destinationDomain,
        address recipient,
        uint32 finality,
        bytes memory quote
    )
        internal
        pure
        returns (bytes memory)
    {
        return
            abi.encodeCall(YoCctpxAdapter.crossChainTransfer, (AMOUNT, destinationDomain, recipient, finality, quote));
    }

    /// @dev The operator's batch `manage` (role 12 holds the batch overload, not the single one).
    function _manage(YoCctpxAdapter adapter, bytes memory call, uint256 value) internal returns (bytes[] memory) {
        address[] memory targets = new address[](1);
        targets[0] = address(adapter);
        bytes[] memory data = new bytes[](1);
        data[0] = call;
        uint256[] memory values = new uint256[](1);
        values[0] = value;
        vm.prank(OPERATOR);
        return YO_EUR.manage(targets, data, values);
    }

    function _messageSent(Vm.Log[] memory logs) internal pure returns (bytes memory message) {
        bytes32 topic = keccak256("MessageSent(bytes)");
        uint256 found;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == address(MESSAGE_TRANSMITTER) && logs[i].topics[0] == topic) {
                message = abi.decode(logs[i].data, (bytes));
                ++found;
            }
        }
        assertEq(found, 1, "one MessageSent");
    }

    /// @dev Header (`MessageV2`) and body (`TransferMessage`) fields at their byte offsets.
    function _assertMessage(
        bytes memory message,
        uint32 sourceDomain,
        uint32 destinationDomain,
        uint32 finality,
        address adapter
    )
        internal
        pure
    {
        assertEq(message.length, MESSAGE_LENGTH, "message length");
        assertEq(uint32(bytes4(_word(message, 0))), 1, "message version");
        assertEq(uint32(bytes4(_word(message, 4))), sourceDomain, "source domain");
        assertEq(uint32(bytes4(_word(message, 8))), destinationDomain, "destination domain");
        assertEq(_word(message, 12), bytes32(0), "nonce is set by Iris");
        assertEq(_word(message, 44), bytes32(uint256(uint160(SERVICE))), "sender");
        assertEq(_word(message, 76), bytes32(uint256(uint160(SERVICE))), "recipient");
        assertEq(_word(message, 108), bytes32(0), "destination caller");
        assertEq(uint32(bytes4(_word(message, 140))), finality, "min finality");
        assertEq(uint32(bytes4(_word(message, 144))), 0, "executed finality is set by Iris");
        assertEq(_word(message, 160), TOKEN_ID, "tokenId");
        assertEq(uint256(_word(message, 192)), AMOUNT, "amount");
        assertEq(uint8(bytes1(_word(message, 288))), 0, "autoExecuteHookData");
        assertEq(uint32(bytes4(_word(message, 289))), 20, "source address length");
        assertEq(uint32(bytes4(_word(message, 293))), 20, "destination address length");
        assertEq(uint32(bytes4(_word(message, 297))), 0, "hook data length");
        assertEq(address(bytes20(_word(message, 301))), adapter, "source address");
        assertEq(address(bytes20(_word(message, 321))), address(YO_EUR), "destination address");
    }

    function _assertQuoteTotal(bytes memory quote, uint256 fee) internal view {
        (uint256 total, address feeToken) = ICctpxFeeManager(FEE_MANAGER).getQuoteTotal(quote);
        assertEq(total, fee, "quote total");
        assertEq(feeToken, address(0), "fee token");
    }

    /// @dev The 32 bytes of `data` from `offset`.
    function _word(bytes memory data, uint256 offset) internal pure returns (bytes32 word) {
        assembly ("memory-safe") {
            word := mload(add(add(data, 32), offset))
        }
    }
}
