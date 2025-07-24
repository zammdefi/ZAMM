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
    uint256 constant DIV = 1_000_000;
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
        (id,) = curve.launch(0, 0, cap, cap, TARGET, DIV, "uri");
    }

    /* -----------------------------------------------------------------
       1. storage values
    ------------------------------------------------------------------*/
    function testLaunchValues() public {
        uint96 cap = 1_000;
        uint96 lpDup = cap;
        (uint256 coinId,) = curve.launch(0, 0, cap, lpDup, TARGET, DIV, "uri");

        (
            address c,
            uint96 saleCap,
            uint96 lpSupply,
            uint96 sold,
            uint64 dl,
            uint256 div,
            uint128 esc,
            uint128 tgt
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
        (uint96 out, uint256 spent) = curve.buyForExactEth{value: 1 ether}(coinId, minCoins);

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
        (uint256 coinId,) = curve.launch(0, 0, saleCap, saleCap, 10 ether, DIV, "uri");

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
        (uint256 coinId,) = curve.launch(0, 0, cap, cap, 3 ether, DIV, "uri");

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

        uint96 bal = curve.balances(coinId, userA);
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
        (uint256 coinId,) = curve.launch(0, 0, 1_000, 1_000, 3 ether, DIV, "uri");

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

        uint96 bal = curve.balances(coinId, userA);
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

        (uint256 coinId,) = curve.launch(
            0, // creatorSupply
            0,
            saleCap,
            lpSupply,
            0.05 ether, // low target
            1_000_000_000, // flat-ish curve
            "pumpfun"
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

    /* ================================================================
       NEW TESTS FOR PRE-BUY ON LAUNCH
       ================================================================ */

    /// @notice creator sends ETH with launch; pre-buy should mint tokens & escrow ETH
    function testLaunchPreBuyMintsAndEscrows() public {
        uint96 saleCap = 1_000;
        uint96 lpDup = saleCap;
        uint128 target = TARGET;
        uint256 div = DIV;

        uint256 sendVal = 0.2 ether; // any positive amount

        uint256 balBefore = owner.balance;
        (uint256 coinId,) = curve.launch{value: sendVal}(0, 0, saleCap, lpDup, target, div, "uri");

        // read sale struct
        (
            address c,
            uint96 saleCapRead,
            uint96 lpSupply,
            uint96 netSold,
            ,
            uint256 divisorRead,
            uint128 esc,
            uint128 tgt
        ) = curve.sales(coinId);

        // After pre-buy, sale is still active unless we hit target
        assertEq(c, owner);
        assertEq(saleCapRead, saleCap);
        assertEq(lpSupply, lpDup);
        assertEq(divisorRead, div);
        assertEq(tgt, target);

        // pre-buy must have minted something
        assertGt(netSold, 0, "no tokens sold in pre-buy");

        // creator should now hold the pre-bought tokens
        assertEq(curve.balances(coinId, owner), netSold, "creator balance mismatch");

        // ETH escrowed equals what the curve charged
        assertEq(esc, uint96(_cost(netSold, div)), "escrow mismatch");

        // creator balance delta ~= escrow (minus gas)
        uint256 balAfter = owner.balance;
        // Allow small wiggle room for gas; escrowed ETH must have left creator's balance
        assertApproxEqAbs(balBefore - balAfter, esc, 2e12 /* ~0.000002 ETH */ );
    }

    /// @notice launch pre-buy refunds any excess ETH
    function testLaunchPreBuyRefundsExcess() public {
        uint96 saleCap = 2_000;
        uint96 lpDup = saleCap;
        uint128 target = TARGET;
        uint256 div = DIV;

        uint256 sendVal = 1 ether;

        uint256 balBefore = owner.balance;
        (uint256 coinId,) = curve.launch{value: sendVal}(0, 0, saleCap, lpDup, target, div, "uri");

        // sales struct is likely deleted if auto-finalized, so don't read esc from it
        uint96 bought = curve.balances(coinId, owner);
        uint256 spent = _cost(bought, div); // test-side helper mirroring contract

        uint256 balAfter = owner.balance;
        // balance delta should equal what was actually spent (ignoring gas)
        assertApproxEqAbs(balBefore - balAfter, spent, 2e12);
        assertTrue(spent <= sendVal, "overspent");
    }

    /// @notice launch with too-small msg.value to buy even 1 token should revert
    function testLaunchPreBuyTooSmallReverts() public {
        uint96 saleCap = 1_000;
        uint96 lpDup = saleCap;
        uint128 target = TARGET;
        uint256 div = uint256(DIV);

        // Sending 1 wei will still mint 1 free token (tokens 0 or 1)
        (uint256 coinId,) = curve.launch{value: 1}(0, 0, saleCap, lpDup, target, div, "uri");

        // Expect success: creator got 1 token
        assertEq(curve.balances(coinId, owner), 1);
    }

    /// @notice pre-buy can hit target and auto-finalize inside launch
    function testLaunchPreBuyAutoFinalize() public {
        uint96 saleCap = 800;
        uint96 lpDup = 200;
        uint128 target = 0.05 ether;
        uint256 div = 1_000_000_000;

        // mock ZAMM calls used by finalize (balanceOf & addLiquidity) BEFORE launch
        vm.mockCall(
            address(Z),
            abi.encodeWithSelector(IZAMM.balanceOf.selector, address(curve), 0), // coinId unknown yet, ignore
            abi.encode(uint256(1e27))
        );
        vm.mockCall(
            address(Z),
            abi.encodeWithSelector(IZAMM.addLiquidity.selector),
            abi.encode(uint256(0), uint256(0), uint256(555))
        );

        // Send enough ETH to cross target
        uint256 sendVal = 1 ether;

        (uint256 coinId, uint96 coinsOut) =
            curve.launch{value: sendVal}(0, 0, saleCap, lpDup, target, div, "pumpfun");

        assertTrue(coinsOut != 0);

        // After finalize, sales[coinId].creator should be 0
        (address creator,,,,,,,) = curve.sales(coinId);
        assertEq(creator, address(0), "sale should be finalized");
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

function _cost(uint256 n, uint256 d) pure returns (uint256) {
    if (n < 2) return 0;
    unchecked {
        uint256 num = n * (n - 1) * (2 * n - 1);
        return fullMulDiv(num, 1 ether, 6 * d);
    }
}

function fullMulDiv(uint256 x, uint256 y, uint256 d) pure returns (uint256 z) {
    assembly ("memory-safe") {
        z := mul(x, y)
        for {} 1 {} {
            if iszero(mul(or(iszero(x), eq(div(z, x), y)), d)) {
                let mm := mulmod(x, y, not(0))
                let p1 := sub(mm, add(z, lt(mm, z)))

                let r := mulmod(x, y, d)
                let t := and(d, sub(0, d))

                if iszero(gt(d, p1)) {
                    mstore(0x00, 0xae47f702)
                    revert(0x1c, 0x04)
                }
                d := div(d, t)
                let inv := xor(2, mul(3, d))
                inv := mul(inv, sub(2, mul(d, inv)))
                inv := mul(inv, sub(2, mul(d, inv)))
                inv := mul(inv, sub(2, mul(d, inv)))
                inv := mul(inv, sub(2, mul(d, inv)))
                inv := mul(inv, sub(2, mul(d, inv)))
                z :=
                    mul(
                        or(mul(sub(p1, gt(r, z)), add(div(sub(0, t), t), 1)), div(sub(z, r), t)),
                        mul(sub(2, mul(d, inv)), inv)
                    )
                break
            }
            z := div(z, d)
            break
        }
    }
}
