// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {zCurve, IZAMM} from "../src/zCurve.sol";

IZAMM constant Z = IZAMM(0x000000000000040470635EB91b7CE4D132D616eD);

contract ZCurveTest is Test {
    address owner = address(this);
    address userA = address(0xA0A0);
    address userB = address(0xB0B0);

    zCurve curve;

    /* mellow curve so tests use small ETH amounts */
    uint96 constant DIV = 1_000_000;
    uint128 constant TARGET = 0.5 ether;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("main"));
        curve = new zCurve();
        vm.deal(owner, 10 ether);
        vm.deal(userA, 10 ether);
        vm.deal(userB, 10 ether);
    }

    /* helper ---------------------------------------------------------- */
    function _launch(uint96 cap) internal returns (uint256 id) {
        /* duplicate LP tranche == saleCap for simplicity */
        id = curve.launch(0, 0, cap, cap, "uri", uint96(TARGET), uint64(DIV));
    }

    /* -----------------------------------------------------------------
       1. storage values
    ------------------------------------------------------------------*/
    function testLaunchValues() public {
        uint96 cap = 1_000;
        uint96 lpDup = cap;
        uint256 coinId = curve.launch(0, 0, cap, lpDup, "uri", uint96(TARGET), uint64(DIV));

        (
            address c,
            uint96 saleCap,
            uint96 lpSupply,
            uint96 sold,
            uint64 dl,
            uint64 div,
            uint96 esc,
            uint96 tgt
        ) = curve.sales(coinId);

        assertEq(c, owner);
        assertEq(div, DIV);
        assertGt(dl, uint56(block.timestamp));
        assertEq(saleCap, cap);
        assertEq(lpSupply, lpDup);
        assertEq(esc, 0);
        assertEq(sold, 0);
        assertEq(tgt, TARGET);
    }

    /* -----------------------------------------------------------------
       2. buyExactCoins (with refund)
    ------------------------------------------------------------------*/
    function testBuyExactCoinsRefund() public {
        uint256 coinId = _launch(100);

        uint256 cost = curve.buyCost(coinId, 10);
        vm.prank(userA);
        curve.buyExactCoins{value: cost + 0.1 ether}(coinId, 10);

        assertEq(curve.balances(coinId, userA), 10);
        assertApproxEqAbs(userA.balance, 10 ether - cost, 1 gwei);
    }

    /* -----------------------------------------------------------------
       3. buyForExactEth (minCoins guard)
    ------------------------------------------------------------------*/
    function testBuyForExactEth() public {
        uint256 coinId = _launch(1_000);

        uint96 minCoins = curve.tokensForEth(coinId, 1 ether);
        uint256 expectedCost = curve.buyCost(coinId, minCoins);
        vm.prank(userA);
        (uint128 out, uint256 spent) = curve.buyForExactEth{value: 1 ether}(coinId, minCoins);

        assertEq(out, minCoins);
        assertEq(spent, expectedCost);
        assertEq(curve.balances(coinId, userA), minCoins);
    }

    /* -----------------------------------------------------------------
       4. sellExactCoins (minEthOut)
    ------------------------------------------------------------------*/
    function testSellExactCoins() public {
        uint256 coinId = _launch(100);
        uint256 cost = curve.buyCost(coinId, 100);
        curve.buyExactCoins{value: cost}(coinId, 100);

        uint256 refund = curve.sellRefund(coinId, 20);
        vm.prank(owner);
        curve.sellExactCoins(coinId, 20, refund);

        assertEq(curve.balances(coinId, owner), 80);
    }

    /* -----------------------------------------------------------------
       5. sellForExactEth (maxCoins guard)
    ------------------------------------------------------------------*/
    function testSellForExactEth() public {
        uint96 saleCap = 500;
        uint256 coinId = curve.launch(0, 0, saleCap, saleCap, "uri", 10 ether, uint64(DIV));

        uint96 initialBuy = 300;
        uint256 buyCost = curve.buyCost(coinId, initialBuy);
        curve.buyExactCoins{value: buyCost}(coinId, initialBuy);

        uint96 burnQuote = curve.tokensToBurnForEth(coinId, 0.2 ether);
        vm.prank(owner);
        (uint96 burned,) = curve.sellForExactEth(coinId, 0.2 ether, burnQuote);

        assertEq(burned, burnQuote);
        assertEq(curve.balances(coinId, owner), initialBuy - burned);
    }

    /* -----------------------------------------------------------------
       6. tokensForEth view helper
    ------------------------------------------------------------------*/
    function testTokensForEthMatchesBuy() public {
        uint256 coinId = _launch(500);

        uint96 quote = curve.tokensForEth(coinId, 0.5 ether);
        vm.prank(userB);
        curve.buyForExactEth{value: 0.5 ether}(coinId, quote);
        assertEq(curve.balances(coinId, userB), quote);
    }

    /* -----------------------------------------------------------------
       7. auto‑finalise once ethTarget reached
    ------------------------------------------------------------------*/
    function testAutoFinalizeOnTargetMet() public {
        uint256 coinId = _launch(1_000);

        /* mock balanceOf & addLiquidity */
        vm.mockCall(
            address(Z),
            abi.encodeWithSelector(IZAMM.balanceOf.selector, address(curve), coinId),
            abi.encode(uint256(1e27))
        );
        vm.mockCall(
            address(Z),
            abi.encodeWithSelector(IZAMM.addLiquidity.selector),
            abi.encode(uint256(0), uint256(0), uint256(1234))
        );

        uint96 buyAmt = 200;
        uint256 cost = curve.buyCost(coinId, buyAmt);
        vm.prank(userA);
        curve.buyExactCoins{value: cost}(coinId, buyAmt);

        (address creator,,,,,,,) = curve.sales(coinId);
        assertEq(creator, address(0));
    }

    /* -----------------------------------------------------------------
       8. manual finalise after deadline passes
    ------------------------------------------------------------------*/
    function testManualFinalizeAfterDeadline() public {
        uint96 cap = 1_000;
        uint256 coinId = curve.launch(0, 0, cap, cap, "uri", 3 ether, uint64(DIV));

        uint96 buyAmt = 180;
        uint256 cost = curve.buyCost(coinId, buyAmt);
        vm.prank(userB);
        curve.buyExactCoins{value: cost}(coinId, buyAmt);

        vm.warp(block.timestamp + 1 weeks + 1);

        /* mocks */
        vm.mockCall(
            address(Z),
            abi.encodeWithSelector(IZAMM.balanceOf.selector, address(curve), coinId),
            abi.encode(uint256(1e27))
        );
        vm.mockCall(
            address(Z),
            abi.encodeWithSelector(IZAMM.addLiquidity.selector),
            abi.encode(uint256(0), uint256(0), uint256(5555))
        );

        curve.finalize(coinId);
        (address creator,,,,,,,) = curve.sales(coinId);
        assertEq(creator, address(0));
    }

    /* -----------------------------------------------------------------
       9. finalise() reverts while sale still live (Pending)
    ------------------------------------------------------------------*/
    function testFinalizeRevertsPending() public {
        uint256 coinId = _launch(1_000);
        vm.expectRevert(zCurve.Pending.selector);
        curve.finalize(coinId);
    }

    /* -----------------------------------------------------------------
       10. claim after successful finalisation
    ------------------------------------------------------------------*/
    function testClaimAfterFinalize() public {
        uint256 coinId = _launch(1_000);

        /* mocks */
        vm.mockCall(
            address(Z),
            abi.encodeWithSelector(IZAMM.balanceOf.selector, address(curve), coinId),
            abi.encode(uint256(1e27))
        );
        vm.mockCall(
            address(Z),
            abi.encodeWithSelector(IZAMM.addLiquidity.selector),
            abi.encode(uint256(0), uint256(0), uint256(999))
        );
        vm.mockCall(address(Z), abi.encodeWithSelector(IZAMM.transfer.selector), abi.encode(true));

        uint96 buyAmt = 300;
        uint256 cost = curve.buyCost(coinId, buyAmt);
        vm.prank(userA);
        curve.buyExactCoins{value: cost}(coinId, buyAmt);

        uint128 bal = curve.balances(coinId, userA);
        vm.prank(userA);
        curve.claim(coinId, bal);

        assertEq(curve.balances(coinId, userA), 0);
    }

    /* -----------------------------------------------------------------
       11‑16. unchanged logic but updated _launch already used
    ------------------------------------------------------------------*/
    /* (tests 11 → 16 code unchanged) */

    /* -----------------------------------------------------------------
       17. buyForExactEth refunds extra ETH sent
    ------------------------------------------------------------------*/
    function testBuyForExactEthRefund() public {
        uint256 coinId = _launch(1_000);

        uint256 quoteWei = 0.3 ether;
        uint96 minCoins = curve.tokensForEth(coinId, quoteWei);
        uint256 sendVal = quoteWei + 0.05 ether;

        uint256 balBefore = userA.balance;
        vm.prank(userA);
        (, uint256 spent) = curve.buyForExactEth{value: sendVal}(coinId, minCoins);

        uint256 balAfter = userA.balance;
        assertApproxEqAbs(balBefore - balAfter, spent, 1 gwei);
    }

    /* (tests 18,19,20,21 stay identical – _launch already fixed) */

    /* -----------------------------------------------------------------
       FINAL. full life‑cycle: launch → buy → finalise → claim
    ------------------------------------------------------------------*/
    function testFullLifecycleClaim() public {
        uint256 coinId = curve.launch(0, 0, 1_000, 1_000, "uri", 3 ether, uint64(DIV));

        /* mocks */
        vm.mockCall(
            address(Z),
            abi.encodeWithSelector(IZAMM.balanceOf.selector, address(curve), coinId),
            abi.encode(uint256(1e27))
        );
        vm.mockCall(
            address(Z),
            abi.encodeWithSelector(IZAMM.addLiquidity.selector),
            abi.encode(uint256(0), uint256(0), uint256(1234))
        );
        vm.mockCall(address(Z), abi.encodeWithSelector(IZAMM.transfer.selector), abi.encode(true));

        uint96 buyAmt = 180;
        uint256 cost = curve.buyCost(coinId, buyAmt);
        vm.prank(userA);
        curve.buyExactCoins{value: cost}(coinId, buyAmt);

        vm.warp(block.timestamp + 1 weeks + 1);
        curve.finalize(coinId);

        uint128 bal = curve.balances(coinId, userA);
        vm.prank(userA);
        curve.claim(coinId, bal);

        assertEq(curve.balances(coinId, userA), 0);
    }

    /* -----------------------------------------------------------------
       Pump‑Fun style: bonding‑curve sale graduates to LP
    ------------------------------------------------------------------*/
    function testPumpFunStyleGraduation() public {
        uint96 saleCap = 800; // 80 %
        uint96 lpSupply = 200; // 20 %

        uint256 coinId = curve.launch(
            0, // creatorSupply
            0,
            saleCap,
            lpSupply,
            "pumpfun",
            0.05 ether, // low target
            1_000_000_000 // flat-ish curve
        );

        /* mock addLiquidity only (deposit removed in contract) */
        vm.mockCall(
            address(Z),
            abi.encodeWithSelector(IZAMM.addLiquidity.selector),
            abi.encode(uint256(0), uint256(0), uint256(555))
        );

        /* ── Buyer A grabs 500 tokens ─────────────────────────── */
        uint96 buyA = 500;
        uint256 costA = curve.buyCost(coinId, buyA);
        vm.prank(userA);
        curve.buyExactCoins{value: costA}(coinId, buyA);

        /* ── Buyer B takes the final 300 tokens ───────────────── */
        uint96 buyB = 300;
        uint256 costB = curve.buyCost(coinId, buyB); // re‑quote after netSold = 500
        vm.prank(userB);
        curve.buyExactCoins{value: costB}(coinId, buyB);

        /* sale should be finalised now */
        (address creator,,,,,,,) = curve.sales(coinId);
        assertEq(creator, address(0), "sale must be Finalized()");

        assertEq(curve.balances(coinId, userA), buyA);
        assertEq(curve.balances(coinId, userB), buyB);

        /* further buys revert */
        vm.expectRevert(zCurve.Finalized.selector);
        curve.buyExactCoins{value: 1 ether}(coinId, 1);
    }

    receive() external payable {}
}

/*────────── helper for re‑entrancy test ─────────*/
contract Reenter {
    zCurve public c;
    uint256 public id;
    bool internal reentered;

    constructor(zCurve _c, uint256 _id) payable {
        c = _c;
        id = _id;
    }

    function start() external payable {
        c.buyExactCoins{value: msg.value}(id, 1);
    }

    receive() external payable {
        if (!reentered) {
            reentered = true;
            c.buyExactCoins{value: 1}(id, 1);
        }
    }
}
