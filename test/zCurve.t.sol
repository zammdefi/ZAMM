// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {zCurve, IZAMM} from "../src/zCurve.sol";

interface IERC6909 {
    function balanceOf(address, uint256) external view returns (uint256);
}

IZAMM constant Z = IZAMM(0x000000000000040470635EB91b7CE4D132D616eD);

/* ──────────────────────────────────────────────────────────────────── */
contract ZCurveTest is Test {
    /* --- shared units ------------------------------------------------ */
    uint256 constant TOKEN = 1 ether; // one full 18‑dec token
    uint256 constant MICRO = 1e12; // one curve “tick” (UNIT_SCALE)
    uint256 constant DIV = 10 ** 26; // super‑flat quadratic curve

    uint128 constant TARGET = 5 ether; // default sale target
    uint128 constant SMALL = 0.05 ether; // tiny target (used in two tests)

    /* --- actors ------------------------------------------------------ */
    address owner = address(this);
    address userA = address(0xA0A0);
    address userB = address(0xB0B0);

    zCurve curve;

    /* allow ETH refunds from the contract ‑‑ needed by sellExactCoins */
    receive() external payable {}

    /* --- test‑set‑up -------------------------------------------------- */
    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("main"));
        curve = new zCurve();

        vm.deal(owner, 10 ether);
        vm.deal(userA, 10 ether);
        vm.deal(userB, 10 ether);
    }

    /* --- helpers ----------------------------------------------------- */

    /// launch with plain “token” cap; cap + lp both token‑scaled (× 1 ether)
    function _launch(uint96 plainCap) internal returns (uint256 id) {
        uint96 cap = uint96(plainCap * TOKEN);
        (id,) = curve.launch(0, 0, cap, cap, TARGET, DIV, 30, "uri");
    }

    /// launch with custom ETH target
    function _launchWithTarget(uint96 plainCap, uint128 targetWei) internal returns (uint256 id) {
        uint96 cap = uint96(plainCap * TOKEN);
        (id,) = curve.launch(0, 0, cap, cap, targetWei, DIV, 30, "uri");
    }

    /* =================================================================
                               INDIVIDUAL TESTS
       ================================================================= */

    /* 1. storage values ------------------------------------------------ */
    function testLaunchValues() public {
        uint96 capTk = 1_000;
        uint96 cap = uint96(capTk * TOKEN);

        (uint256 coinId,) = curve.launch(0, 0, cap, cap, TARGET, DIV, 30, "uri");

        (
            address c,
            uint96 saleCap,
            uint96 lpSupply,
            uint96 sold,
            uint64 dl,
            uint256 div,
            uint128 esc,
            uint128 tgt,
        ) = curve.sales(coinId);

        assertEq(c, owner);
        assertEq(saleCap, cap);
        assertEq(lpSupply, cap);
        assertEq(sold, 0);
        assertGt(dl, uint64(block.timestamp));
        assertEq(div, DIV);
        assertEq(esc, 0);
        assertEq(tgt, TARGET);
    }

    /* 2. buyExactCoins (with refund) ---------------------------------- */
    function testBuyExactCoinsRefund() public {
        uint256 coinId = _launch(100);

        uint96 buyN = uint96(10 * TOKEN);
        uint256 cost = curve.buyCost(coinId, buyN);

        vm.prank(userA);
        curve.buyExactCoins{value: cost + 0.05 ether}(coinId, buyN, 1e20);

        assertEq(curve.balances(coinId, userA), buyN);
        assertApproxEqAbs(userA.balance, 10 ether - cost, 1 gwei);
    }

    /* 3. buyForExactEth (minCoins guard) ------------------------------ */
    function testBuyForExactEth() public {
        uint256 coinId = _launch(1_000);

        uint96 minCoins = curve.tokensForEth(coinId, 1 ether);
        uint256 expected = curve.buyCost(coinId, minCoins);

        vm.prank(userA);
        (uint96 out, uint256 spent) = curve.buyForExactEth{value: 1 ether}(coinId, minCoins);

        assertEq(out, minCoins);
        assertEq(spent, expected);
        assertEq(curve.balances(coinId, userA), minCoins);
    }

    /* 4. sellExactCoins (minEthOut) ----------------------------------- */
    function testSellExactCoins() public {
        uint256 coinId = _launch(200);

        vm.prank(userA);
        curve.buyExactCoins{value: 0}(coinId, uint96(100 * MICRO), 1e20); // first ticks are free

        uint96 sellAmt = uint96(20 * MICRO);
        uint256 refund = curve.sellRefund(coinId, sellAmt);

        vm.prank(userA);
        curve.sellExactCoins(coinId, sellAmt, refund);

        assertEq(curve.balances(coinId, userA), uint96(80 * MICRO));
    }

    /* 5. sellForExactEth (maxCoins guard) ----------------------------- */
    function testSellForExactEth() public {
        // Curve wide enough to make tokens > 0 wei within cap
        uint96 cap = 1_000; // µ‑tokens
        uint256 coinId = _launch(cap);

        /* ------------------ BUY ------------------ */
        uint96 step = uint96(MICRO);
        uint96 buyAmt = step;
        uint256 cost = 0;

        // keep increasing until marginal cost ≥ 2 wei (so cost/2 > 0)
        while (cost < 2) {
            buyAmt += step;
            cost = curve.buyCost(coinId, buyAmt);
        }

        // purchase those tokens
        curve.buyExactCoins{value: cost}(coinId, buyAmt, type(uint256).max);

        /* ------------------ SELL ----------------- */
        uint256 desired = cost / 2; // strictly > 0 by construction
        assertGt(desired, 0, "desired must be positive");

        // quote how many tokens to burn for that refund
        uint96 quote = curve.tokensToBurnForEth(coinId, desired);
        assertGt(quote, 0, "quote must be positive");

        // execute the sell – should succeed and burn exactly `quote`
        vm.prank(owner);
        (uint96 burned, uint256 refund) = curve.sellForExactEth(coinId, desired, quote);

        assertEq(burned, quote, "burned token amount mismatch");
        assertGe(refund, desired, "refund must cover desired amount");
    }

    /* 6. tokensForEth view helper ------------------------------------- */
    function testTokensForEthMatchesBuy() public {
        uint256 coinId = _launch(500);

        uint96 quote = curve.tokensForEth(coinId, 0.5 ether);

        vm.prank(userB);
        curve.buyForExactEth{value: 0.5 ether}(coinId, quote);

        assertEq(curve.balances(coinId, userB), quote);
    }

    /* 7. auto‑finalise once target reached ---------------------------- */
    function testAutoFinalizeOnTargetMet() public {
        // tiny 0.05 ETH target so we can cross it with one paid purchase
        uint256 coinId = _launchWithTarget(1_000, SMALL);

        /* mocks so `_finalize` can run */
        vm.mockCall(
            address(Z),
            abi.encodeWithSelector(IERC6909.balanceOf.selector, address(curve), coinId),
            abi.encode(uint256(1e27))
        );
        vm.mockCall(
            address(Z),
            abi.encodeWithSelector(IZAMM.addLiquidity.selector),
            abi.encode(uint256(0), uint256(0), uint256(1234))
        );

        /* quote how many µ‑tokens cost very close to the target */
        uint96 want = curve.tokensForEth(coinId, SMALL);
        uint256 cost = curve.buyCost(coinId, want);

        // top‑up a hair to guarantee we cross the target
        vm.prank(userA);
        curve.buyExactCoins{value: cost + 1 wei}(coinId, want, type(uint256).max);

        (address creator,,,,,,,,) = curve.sales(coinId);
        assertEq(creator, address(0), "sale should be finalized");
    }

    /* 8. manual finalise after deadline ------------------------------- */
    function testManualFinalizeAfterDeadline() public {
        uint96 cap = 1_000;
        uint256 coinId = _launchWithTarget(cap, SMALL);

        vm.prank(userB);
        curve.buyExactCoins{value: 0}(coinId, uint96(180 * MICRO), 1e20);

        vm.warp(block.timestamp + 2 weeks + 1);

        vm.mockCall(
            address(Z),
            abi.encodeWithSelector(IERC6909.balanceOf.selector, address(curve), coinId),
            abi.encode(uint256(1e27))
        );
        vm.mockCall(
            address(Z),
            abi.encodeWithSelector(IZAMM.addLiquidity.selector),
            abi.encode(uint256(0), uint256(0), uint256(5555))
        );

        curve.finalize(coinId);
        (address creator,,,,,,,,) = curve.sales(coinId);
        assertEq(creator, address(0));
    }

    /* 9. finalise() reverts when live --------------------------------- */
    function testFinalizeRevertsPending() public {
        uint256 coinId = _launch(1_000);
        vm.expectRevert(zCurve.Pending.selector);
        curve.finalize(coinId);
    }

    /* 10. claim after finalize ---------------------------------------- */
    function testClaimAfterFinalize() public {
        uint256 coinId = _launchWithTarget(1_000, SMALL);

        /* mocks */
        vm.mockCall(
            address(Z),
            abi.encodeWithSelector(IERC6909.balanceOf.selector, address(curve), coinId),
            abi.encode(uint256(1))
        );
        vm.mockCall(
            address(Z),
            abi.encodeWithSelector(IZAMM.addLiquidity.selector),
            abi.encode(uint256(0), uint256(0), uint256(999))
        );
        vm.mockCall(address(Z), abi.encodeWithSelector(IZAMM.transfer.selector), abi.encode(true));

        /* cross the tiny target with a paid buy */
        uint96 want = curve.tokensForEth(coinId, SMALL);
        uint256 cost = curve.buyCost(coinId, want);
        vm.prank(userA);
        curve.buyExactCoins{value: cost + 1 wei}(coinId, want, type(uint256).max);

        /* sale is now finalized – user can claim */
        uint96 bal = curve.balances(coinId, userA);
        vm.prank(userA);
        curve.claim(coinId, bal);

        assertEq(curve.balances(coinId, userA), 0);
    }

    /* 11. first‑tick free via buyExactCoins --------------------------- */
    function testFirstTickFreeBuyExact() public {
        uint256 coinId = _launch(10);

        curve.buyExactCoins{value: 0}(coinId, uint96(MICRO), 1e20);
        assertEq(curve.balances(coinId, owner), MICRO);
    }

    /* 12. cost & quote for free tick ---------------------------------- */
    function testCostAndQuoteForFirstTick() public {
        uint256 coinId = _launch(10);

        uint96 free = curve.tokensForEth(coinId, 0);
        assertGt(free, 0);
        assertEq(curve.buyCost(coinId, free), 0);
    }

    /* 13. second tick costs something --------------------------------- */
    function testSecondTickCostAndRevert() public {
        uint256 coinId = _launch(10);

        /* first µ‑token is free */
        curve.buyExactCoins{value: 0}(coinId, uint96(MICRO), type(uint256).max);

        /* find the *smallest* extra µ‑token amount whose cost > 0 */
        uint96 step = uint96(MICRO);
        uint96 toBuy = step;
        uint256 cost;
        while (true) {
            cost = curve.buyCost(coinId, toBuy);
            if (cost > 0) break;
            toBuy += step;
        }

        assertGt(cost, 0, "second paid tick must cost >0");

        /* zero‑ETH purchase for that paid amount must revert */
        vm.expectRevert(zCurve.InvalidMsgVal.selector);
        curve.buyExactCoins{value: 0}(coinId, toBuy, type(uint256).max);
    }

    /* 14. buyForExactEth refund path ---------------------------------- */
    function testBuyForExactEthRefund() public {
        uint256 coinId = _launch(1_000);

        uint256 quoteWei = 0.3 ether;
        uint96 minCoins = curve.tokensForEth(coinId, quoteWei);
        uint256 sendVal = quoteWei + 0.05 ether;

        uint256 before = userA.balance;
        vm.prank(userA);
        (, uint256 spent) = curve.buyForExactEth{value: sendVal}(coinId, minCoins);
        uint256 afterB = userA.balance;

        assertApproxEqAbs(before - afterB, spent, 1 gwei);
    }

    /* 15. reentrancy guard ------------------------------------------- */
    function testReentrancyGuard() public {
        uint256 coinId = _launch(10);

        uint256 baseCost = 1 wei; // send surplus ⇒ refund ⇒ re‑enter
        Reenter attacker = new Reenter(curve, coinId);
        vm.deal(address(attacker), baseCost + 1 ether);

        vm.expectRevert(); // Reentrancy()
        attacker.start{value: baseCost}();
    }

    // - EXTENDED TESTS

    uint96 constant MIN_CAP = uint96(5 ether); // launch‑pad hard‑minimum
    uint256 constant DIV_FLAT = 1e26; // very flat curve → tiny prices

    function testFinalizeBurnsLpWhenFewSold() public {
        // cap = 5 ETH worth of base‑units, lpSupply = 2.5 ETH
        uint96 saleCap = uint96(MIN_CAP); // 5 × 10¹⁸
        uint96 lpDup = uint96(MIN_CAP / 2); // 2.5 × 10¹⁸

        (uint256 coinId,) = curve.launch(0, 0, saleCap, lpDup, TARGET, DIV_FLAT, 30, "few sold");

        // Buy exactly one MICRO‑unit (free first tick)
        curve.buyExactCoins{value: 0}(coinId, uint96(MICRO), type(uint256).max);

        // Warp past the deadline and finalise
        vm.warp(block.timestamp + 2 weeks + 1);
        curve.finalize(coinId);

        // Sale record must be cleared (creator == 0)
        (address creator,,,,,,,,) = curve.sales(coinId);
        assertEq(creator, address(0), "sale struct not cleared");

        // User can still claim the lone token
        vm.mockCall(address(Z), abi.encodeWithSelector(IZAMM.transfer.selector), abi.encode(true));
        curve.claim(coinId, uint96(MICRO));
        assertEq(curve.balances(coinId, owner), 0, "claim balance wrong");
    }

    function testBuyForExactEthSellsOut() public {
        uint96 saleCap = uint96(MIN_CAP); // 5 ETH base‑units
        uint96 lpDup = saleCap;

        (uint256 coinId,) = curve.launch(0, 0, saleCap, lpDup, 1 ether, DIV_FLAT, 30, "sell out");

        /* stub AMM calls – finalise path will add liquidity */
        vm.mockCall(
            address(Z),
            abi.encodeWithSelector(IERC6909.balanceOf.selector, address(curve), coinId),
            abi.encode(uint256(1))
        );
        vm.mockCall(
            address(Z),
            abi.encodeWithSelector(IZAMM.addLiquidity.selector),
            abi.encode(uint256(0), uint256(0), uint256(777))
        );

        uint256 fullCost = curve.buyCost(coinId, saleCap); // tiny – <0.01 ETH
        vm.prank(userA);
        curve.buyForExactEth{value: fullCost + 1 ether}(coinId, saleCap); // buys all, gets refund

        // Sale must be finalised (struct deleted)
        (address creator,,,,,,,,) = curve.sales(coinId);
        assertEq(creator, address(0), "sale should be closed");

        // Buyer owns the entire cap
        assertEq(curve.balances(coinId, userA), saleCap, "buyer balance mismatch");
    }

    function testLaunchBadDivisorReverts() public {
        uint96 cap = uint96(MICRO);
        uint256 badDiv = type(uint256).max; // definitely > MAX_DIV
        vm.expectRevert(zCurve.InvalidParams.selector);
        curve.launch(0, 0, cap, cap, TARGET, badDiv, 30, "bad divisor");
    }

    function testTokensToBurnForEthZeroEscrow() public {
        uint96 cap = MIN_CAP;
        // Launch with flat curve so cost(5 ETH) ≪ TARGET and no pre‑buy
        (uint256 coinId,) = curve.launch(0, 0, cap, cap, TARGET, DIV_FLAT, 30, "no escrow");

        uint96 quote = curve.tokensToBurnForEth(coinId, 1 wei);
        assertEq(quote, 0, "quote should be 0 with empty escrow");
    }

    /*═══════════════════════════════════════════════════════════════════════*\
    │  FRIEND‑TECH STYLE — 18‑decimal end‑to‑end & price matching            │
    \*═══════════════════════════════════════════════════════════════════════*/

    uint256 constant DIV_FT_SCALED = 16_000 * 1e18; // 16 k  *  10¹⁸

    /* -----------------------------------------------------------------
    41. FT full life‑cycle: 800 M / 200 M, target 10 ETH, auto‑finalise
    ------------------------------------------------------------------*/
    function testFriendTechFullLifecycle18Dec() public {
        uint96 saleCap = uint96(800_000_000 ether); // 8 × 10²⁶ base‑units
        uint96 lpSupply = uint96(200_000_000 ether);
        uint128 target = 10 ether;

        /* ----------------  launch  ---------------- */
        (uint256 coinId,) =
            curve.launch(0, 0, saleCap, lpSupply, target, DIV_FT_SCALED, 30, "ft big");

        /* stub AMM calls so `_finalize` can run */
        vm.mockCall(
            address(Z),
            abi.encodeWithSelector(IERC6909.balanceOf.selector, address(curve), coinId),
            abi.encode(uint256(1))
        );
        vm.mockCall(
            address(Z),
            abi.encodeWithSelector(IZAMM.addLiquidity.selector),
            abi.encode(uint256(0), uint256(0), uint256(4242))
        );

        /* ----------------  buy & auto‑finalise  ---------------- */
        vm.deal(userA, 20 ether);
        vm.prank(userA);
        (uint96 out, uint256 spent) = curve.buyForExactEth{value: target}(coinId, 0.001 ether);

        assertTrue(out > 1 ether, "must receive >0.001 token");
        assertLe(spent, target, "must not overspend");

        /* sale struct should now be deleted */
        (address creator,,,,,,,,) = curve.sales(coinId);
        assertEq(creator, address(0), "sale should be finalised");

        /* ----------------  claim  ---------------- */
        vm.mockCall(address(Z), abi.encodeWithSelector(IZAMM.transfer.selector), abi.encode(true));
        vm.prank(userA);
        curve.claim(coinId, out);
        assertEq(curve.balances(coinId, userA), 0, "claim should burn IOU");
    }

    /* -----------------------------------------------------------------
     FriendTech reference cost matches zCurve.buyCost
    ------------------------------------------------------------------*/
    function testFtCostMatchesReference() public {
        /* ── launch a large‑supply FT‑style sale ─────────────────────── */
        uint96 saleCap = uint96(2_000_000 * 1 ether); // 2 M tokens (18‑dec)
        uint96 lpDup = saleCap; // equal LP tranche
        uint128 target = 5 ether; // any target ≥ _cost(5)
        uint256 divFT = 16_000 * 1e18; // FT divisor scaled to 18‑dec

        (uint256 coinId,) = curve.launch(0, 0, saleCap, lpDup, target, divFT, 30, "ft cost");

        /* ── quote the cost for buying 123 FT “ticks” ────────────────── */
        uint96 coinsRaw = uint96(123 * 1 ether); // 123 tokens in 18‑dec
        uint256 costViaContract = curve.buyCost(coinId, coinsRaw);

        /* ── compute reference cost with the analytic formula ────────── */
        uint256 m = uint256(coinsRaw) / 1e12; // # ticks (123 M)
        uint256 sum = _friendTechSum(m); // ∑ i²  (0‑based)
        uint256 expected = (sum * 1 ether) / divFT; // scale to wei

        assertEq(costViaContract, expected, "FT cost mismatch");
    }

    /* helper: ∑_{i=0}^{n‑1} i² = n(n‑1)(2n‑1)/6  — safe for n ≤ 1e18 */
    function _friendTechSum(uint256 n) internal pure returns (uint256) {
        if (n < 2) return 0;
        unchecked {
            return n * (n - 1) * (2 * n - 1) / 6;
        }
    }

    /* ---------- local helper using the pure FT formula ---------- */
    function ftReferenceCost(uint256 supplyTokens, uint256 amountTokens)
        internal
        pure
        returns (uint256)
    {
        uint256 sum1 = supplyTokens == 0
            ? 0
            : (supplyTokens - 1) * supplyTokens * (2 * (supplyTokens - 1) + 1) / 6;

        uint256 sum2 = (supplyTokens == 0 && amountTokens == 1)
            ? 0
            : (supplyTokens - 1 + amountTokens) * (supplyTokens + amountTokens)
                * (2 * (supplyTokens - 1 + amountTokens) + 1) / 6;

        uint256 summation = sum2 - sum1;
        return summation * 1 ether / 16_000;
    }
}

/* helper used by testReentrancyGuard ---------------------------------- */
contract Reenter {
    zCurve public immutable c;
    uint256 public immutable id;
    bool private reentered;

    constructor(zCurve _c, uint256 _id) payable {
        c = _c;
        id = _id;
    }

    function start() external payable {
        // first buy 1 µ‑token; will refund >0 wei → trigger receive()
        c.buyExactCoins{value: msg.value}(id, 1e12, type(uint256).max);
    }

    receive() external payable {
        if (!reentered) {
            reentered = true;
            // re‑enter during first call ‑‑ should revert via guard
            c.buyExactCoins{value: 1}(id, 1e12, type(uint256).max);
        }
    }
}
