// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";

/* contracts */
/*import {ZAMM} from "../src/ZAMM.sol";
import {zCoins, zToken, PoolKey} from "../src/zCoins.sol";

/* ─────────────────────────────────────────────────────────────────── */
/**
 * Minimal end‑to‑end sanity suite for zCoins.
 *
 * Covers:
 *  1. create() → metadata & totalSupply
 *  2. transfer()
 *  3. taxed swapExactIn  (ETH → coin)
 *  4. addLiquidity & removeLiquidity helpers
 *  5. zToken façade ERC‑20 workflow
 *
 * Works on a mainnet fork with the canonical ZAMM already deployed.
 */
/*contract ZCoinsTest is Test {
    /* live singleton */
/*ZAMM constant zamm = ZAMM(payable(0x000000000000040470635EB91b7CE4D132D616eD));

    zCoins zc;

    /* actors */
/*address creator = address(this); // the test contract itself
    address alice = address(0xAA11);
    address bob = address(0xBB22);

    /* artefacts discovered in setUp */
/*uint256 coinId;
    uint256 poolId;
    zToken facade;

    /* Transfer event signature – same as zCoins emits */
/*bytes32 constant TRANSFER_SIG = keccak256("Transfer(address,address,address,uint256,uint256)");

    /* ─────────────────────────────────────────────────────────────── */
/*function setUp() public {
        /* fork any recent mainnet block */
/*vm.createSelectFork(vm.rpcUrl("main"));
        zc = new zCoins();

        /* seed ETH balances */
/*vm.deal(creator, 100 ether);
        vm.deal(alice, 50 ether);
        vm.deal(bob, 50 ether);

        /* ── 1) create a new coin & seed pool ─────────────────────── */
/*vm.recordLogs();

        /* ignore returned tuple; we’ll fish id out of logs */
/*zc.create{value: 1 ether}(
            "TestCoin",
            "TEST",
            "ipfs://meta",
            creator, // owner
            1_000 ether, // owner allocation
            1_000 ether // pool bootstrap
        );

        /* ── 2) parse the mint Transfer event to get coinId ───────── */
/*Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == TRANSFER_SIG) {
                address from = address(uint160(uint256(logs[i].topics[1])));
                address to = address(uint160(uint256(logs[i].topics[2])));
                if (from == address(0) && to == creator) {
                    coinId = uint256(logs[i].topics[3]);
                    break;
                }
            }
        }
        require(coinId != 0, "coinId not found");
        facade = zToken(address(uint160(coinId)));

        /* canonical LP‑id (ETH ↔ coin) */
/*poolId = uint256(
            keccak256(
                abi.encode(
                    uint256(0), // id0
                    coinId, // id1
                    address(0), // token0
                    address(zc), // token1
                    (1 << 255) | coinId // feeOrHook (FLAG_BEFORE | id)
                )
            )
        );
    }

    /* ═════════════════════════ tests ══════════════════════════════ */

/*function testMetadataAndSupply() public {
        assertEq(zc.name(coinId), "TestCoin");
        assertEq(zc.symbol(coinId), "TEST");
        assertEq(zc.totalSupply(coinId), 2_000 ether); // 1k to owner + 1k in pool
        assertEq(zc.ownerOf(coinId), creator);
    }

    function testTransfer() public {
        zc.transfer(alice, coinId, 250 ether);
        assertEq(zc.balanceOf(alice, coinId), 250 ether);
        assertEq(zc.balanceOf(creator, coinId), 750 ether);
    }

    function testSwapExactIn_EthToCoin() public {
        zc.setTaxBps(coinId, 500); // 5 % creator tax
        uint256 fee = 1 ether * 5 / 100;
        uint256 balBefore = creator.balance;

        vm.prank(alice);
        uint256 coinsOut = zc.swapExactIn{value: 1 ether}(
            _key(coinId),
            1 ether,
            0,
            true, // ETH → coin
            block.timestamp + 1
        );

        assertGt(coinsOut, 0);
        assertEq(creator.balance, balBefore + fee);
        assertEq(zc.balanceOf(alice, coinId), coinsOut);
    }

    function testAddAndRemoveLiquidity() public {
        zc.transfer(alice, coinId, 500 ether);
        vm.deal(alice, 2 ether);

        vm.startPrank(alice);
        zc.approve(address(zc), coinId, type(uint256).max);

        (,, uint256 lp) = zc.addLiquidity{value: 1 ether}(coinId, 500 ether, block.timestamp + 1);
        assertGt(lp, 0);

        (uint256 ethOut, uint256 coinOut) =
            zc.removeLiquidity(coinId, lp, 0, 0, block.timestamp + 1);

        assertApproxEqRel(ethOut, 1 ether, 0.03e18);
        assertApproxEqRel(coinOut, 500 ether, 0.03e18);
        vm.stopPrank();
    }

    function testFacadeERC20Flow() public {
        /* alice approves bob via façade */
/*vm.prank(alice);
        facade.approve(bob, 200 ether);

        vm.startPrank(bob);
        facade.transferFrom(alice, bob, 150 ether);
        vm.stopPrank();

        assertEq(facade.balanceOf(bob), 150 ether);
        assertEq(facade.allowance(alice, bob), 50 ether);
    }

    /* ═══════════════════ helpers ════════════════════ */
/*function _key(uint256 id) internal view returns (PoolKey memory k) {
        k = PoolKey({
            id0: 0,
            id1: id,
            token0: address(0),
            token1: address(zc),
            feeOrHook: (1 << 255) | id
        });
    }

    receive() external payable {}
}
*/
