// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { YoLidoAdapter } from "src/adapters/lido/YoLidoAdapter.sol";
import { IStETH } from "src/interfaces/external/IStETH.sol";
import { IWETH9 } from "src/interfaces/external/IWETH9.sol";
import { IWithdrawalQueueERC721 } from "src/interfaces/external/IWithdrawalQueueERC721.sol";

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
}
