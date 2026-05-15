// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { YoLidoAdapter } from "src/adapters/lido/YoLidoAdapter.sol";
import { IStETH } from "src/interfaces/external/IStETH.sol";
import { IWETH9 } from "src/interfaces/external/IWETH9.sol";
import { IWithdrawalQueueERC721 } from "src/interfaces/external/IWithdrawalQueueERC721.sol";

/// @dev Test-only extension of the queue surface. Adapters never call `finalize`; in production
///      it's invoked by Lido core during the post-oracle-report accounting flow.
interface IWithdrawalQueueExtended {
    function finalize(uint256 lastRequestIdToBeFinalized, uint256 maxShareRate) external payable;
    function getLastFinalizedRequestId() external view returns (uint256);
    function getLastRequestId() external view returns (uint256);
}

import { Fork_Test } from "../Fork_Test.t.sol";

/// @notice End-to-end: real YoVault → YoLidoAdapter → real Lido on Ethereum mainnet.
///         Covers the stake + requestUnstake flow. We skip `claimUnstake` because Lido
///         finalization usually takes 1-5 days; a single-block fork test can't realistically
///         exercise it without protocol-internal manipulation (Lido's finalize is permissioned).
contract LidoFork_Test is Fork_Test {
    uint256 internal constant MAINNET_BLOCK = 0; // late Dec 2024, well after Pectra prep

    IWETH9 internal constant WETH = IWETH9(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));
    IStETH internal constant STETH = IStETH(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84);
    IWithdrawalQueueERC721 internal constant QUEUE =
        IWithdrawalQueueERC721(0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1);

    uint256 internal constant STAKE_AMOUNT = 10 ether;

    YoLidoAdapter internal adapter;

    function setUp() public {
        _maybeSkip(_forkIfAvailable("MAINNET_RPC_URL", MAINNET_BLOCK), "MAINNET_RPC_URL");

        _deployStack(IERC20(address(WETH)), "Yo WETH Vault", "yoWETH");

        adapter = new YoLidoAdapter({
            _stETH: STETH,
            _queue: QUEUE,
            _weth: WETH,
            _referral: address(0)
        });
        vm.label(address(adapter), "YoLidoAdapter");

        // Fund the vault with WETH directly: ETH → WETH wrap.
        vm.deal(address(this), 1_000 ether);
        WETH.deposit{ value: STAKE_AMOUNT * 2 }();
        IERC20(address(WETH)).transfer(address(yoVault), STAKE_AMOUNT * 2);

        // Vault approves the adapter for WETH (stake input) and stETH (unstake input).
        _vaultApprove(IERC20(address(WETH)), address(adapter), type(uint256).max);
        _vaultApprove(IERC20(address(STETH)), address(adapter), type(uint256).max);

        // Vault grants the adapter approval-for-all on the withdrawal NFT (claim path).
        bytes memory setApprovalAll = abi.encodeWithSelector(
            bytes4(keccak256("setApprovalForAll(address,bool)")), address(adapter), true
        );
        _opManage(address(QUEUE), setApprovalAll);
    }

    function test_Fork_Lido_StakeDeliversStETH() external {
        uint256 wethBefore = IERC20(address(WETH)).balanceOf(address(yoVault));
        uint256 stETHBefore = STETH.balanceOf(address(yoVault));

        bytes memory stakeCall = abi.encodeCall(YoLidoAdapter.stake, (STAKE_AMOUNT));
        _opManage(address(adapter), stakeCall);

        assertEq(
            IERC20(address(WETH)).balanceOf(address(yoVault)),
            wethBefore - STAKE_AMOUNT,
            "WETH pulled"
        );
        // stETH is a rebasing 1:1 token at submission; allow ±1 wei of share-math rounding.
        uint256 stETHDelta = STETH.balanceOf(address(yoVault)) - stETHBefore;
        uint256 diff = stETHDelta > STAKE_AMOUNT ? stETHDelta - STAKE_AMOUNT : STAKE_AMOUNT - stETHDelta;
        assertLe(diff, 2, "stETH delta within 2 wei of staked WETH");

        // Custody invariants
        assertEq(address(adapter).balance, 0);
        assertEq(IERC20(address(WETH)).balanceOf(address(adapter)), 0);
    }

    /// @notice After `requestUnstake`, the withdrawal NFT lands on the vault, and the adapter is
    ///         left fully clean (zero shares, zero allowance) — any rounding dust gets swept back
    ///         to the vault inside the call via `transferShares`.
    function test_Fork_Lido_RequestUnstakeBurnsStETHAndMintsNFT() external {
        bytes memory stakeCall = abi.encodeCall(YoLidoAdapter.stake, (STAKE_AMOUNT));
        _opManage(address(adapter), stakeCall);

        uint256 stETHBefore = STETH.balanceOf(address(yoVault));

        bytes memory unstakeCall = abi.encodeCall(YoLidoAdapter.requestUnstake, (STAKE_AMOUNT));
        bytes memory ret = _opManage(address(adapter), unstakeCall);
        uint256 requestId = abi.decode(ret, (uint256));

        // stETH consumed. Vault balance should drop by ~STAKE_AMOUNT (±2 wei of Lido rounding).
        uint256 stETHAfter = STETH.balanceOf(address(yoVault));
        uint256 delta = stETHBefore - stETHAfter;
        assertGe(delta, STAKE_AMOUNT - 2, "at least STAKE_AMOUNT - 2 burned");
        assertLe(delta, STAKE_AMOUNT + 2, "at most STAKE_AMOUNT + 2 burned");
        // The withdrawal NFT for `requestId` is owned by the vault.
        assertEq(QUEUE.ownerOf(requestId), address(yoVault), "vault owns NFT");

        // Adapter is fully clean: dust was swept to the vault inside the call.
        assertEq(STETH.sharesOf(address(adapter)), 0, "adapter shares: zero");
        assertEq(IERC20(address(STETH)).allowance(address(adapter), address(QUEUE)), 0);
    }

    /// @notice Full stake → request → finalize → claim cycle against real Lido. In production the
    ///         finalize step happens 1-5 days after the request, triggered by Lido's accounting
    ///         oracle. Here we simulate it by impersonating Lido core (the FINALIZE_ROLE holder)
    ///         and depositing the matching ETH into the queue — everything downstream of that is
    ///         the real Lido / WithdrawalQueue / WETH9 path.
    function test_Fork_Lido_FullStakeRequestFinalizeClaim() external {
        // 1. Stake.
        _opManage(address(adapter), abi.encodeCall(YoLidoAdapter.stake, (STAKE_AMOUNT)));

        // 2. Request unstake.
        bytes memory unstakeRet = _opManage(
            address(adapter), abi.encodeCall(YoLidoAdapter.requestUnstake, (STAKE_AMOUNT))
        );
        uint256 requestId = abi.decode(unstakeRet, (uint256));

        // 3. Simulate Lido finalization.
        //    - FINALIZE_ROLE is held by Lido core, which is the stETH contract itself.
        //    - maxShareRate is 1e27-scaled ETH/share (== getPooledEthByShares(1e27)).
        //    - ETH to lock equals (roughly) the stETH amount being finalized.
        uint256 maxShareRate = STETH.getPooledEthByShares(1e27);
        address lidoCore = address(STETH);
        vm.deal(lidoCore, STAKE_AMOUNT + 1 ether); // headroom for share-rate math
        vm.prank(lidoCore);
        IWithdrawalQueueExtended(address(QUEUE)).finalize{ value: STAKE_AMOUNT }(requestId, maxShareRate);

        // Sanity: the queue records our request as finalized.
        uint256 lastFinalized = IWithdrawalQueueExtended(address(QUEUE)).getLastFinalizedRequestId();
        assertGe(lastFinalized, requestId, "queue advanced past our id");

        // 4. Claim. Vault gets WETH back; adapter ends clean.
        uint256 wethBefore = IERC20(address(WETH)).balanceOf(address(yoVault));
        bytes memory claimRet = _opManage(address(adapter), abi.encodeCall(YoLidoAdapter.claimUnstake, (requestId)));
        uint256 wethReceived = abi.decode(claimRet, (uint256));

        assertGt(wethReceived, 0, "claim delivered WETH");
        assertEq(
            IERC20(address(WETH)).balanceOf(address(yoVault)),
            wethBefore + wethReceived,
            "vault WETH delta == claim"
        );
        // The NFT is burned by claimWithdrawal — `ownerOf(requestId)` reverts after a successful claim.
        vm.expectRevert();
        QUEUE.ownerOf(requestId);

        // Adapter custody invariants.
        assertEq(address(adapter).balance, 0, "no leftover ETH");
        assertEq(IERC20(address(WETH)).balanceOf(address(adapter)), 0, "no leftover WETH");
        assertEq(STETH.sharesOf(address(adapter)), 0, "no leftover stETH shares");
    }
}
