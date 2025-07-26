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

    /* 16. launch rejects bad feeOrHook once saleCap ≥ 5 ETH */
    function testLaunchInvalidFeeOrHookReverts() public {
        uint96 cap = uint96(5 ether);
        // Only a flag bit, no lower‐160‐bit addr → masked == 0 → fails hook check
        uint256 justFlag = uint256(1) << 255;
        vm.expectRevert(zCurve.InvalidFeeOrHook.selector);
        curve.launch(
            0, // creatorSupply
            0, // creatorUnlock
            cap, // saleCap (5 ETH)
            cap, // lpSupply  (5 ETH)
            TARGET, // ethTarget
            DIV, // divisor
            justFlag, // feeOrHook
            "bad fee"
        );
    }

    /* 17. launch accepts a valid “hook” style feeOrHook */
    function testLaunchValidHook() public {
        uint96 cap = uint96(5 ether);
        // Build a hook: FLAG_BEFORE | lower‐160‐bits nonzero address
        uint256 hook = (uint256(1) << 255) | uint256(uint160(address(0x1234)));
        (uint256 coinId,) = curve.launch(0, 0, cap, cap, TARGET, DIV, hook, "hooked");

        // Read it back via saleSummary
        (,,,,,,,,,,,, uint256 storedHook,) = curve.saleSummary(coinId, address(0));
        assertEq(storedHook, hook, "feeOrHook should roundtrip");
    }

    /* 18. saleSummary price & state transitions (free first tick) */
    function testSaleSummaryStateTransitions() public {
        // Launch with a target but no buys yet
        uint256 coinId = _launchWithTarget(20, TARGET);

        // Immediately after launch
        (,,,,,, bool isLive, bool isFinalized, uint256 price,,,,,) =
            curve.saleSummary(coinId, userA);

        assertTrue(isLive, "should be live right after launch");
        assertFalse(isFinalized, "must not be finalized yet");
        // First quantum is free, so the marginal price is zero
        assertEq(price, 0, "first tick is free => price == 0");

        // Warp past the deadline
        vm.warp(block.timestamp + 2 weeks + 1);
        (,,,,,, bool live2, bool fin2, uint256 price2,,,,,) = curve.saleSummary(coinId, userA);

        assertFalse(live2, "sale must no longer be live");
        assertFalse(fin2, "still not autofinalized until finalize()");
        assertEq(price2, 0, "price should be 0 when expired");
    }

    /* 20. buyCost floors non‑aligned coins via _quantizeDown */
    function testBuyCostQuantizationDown() public {
        uint256 coinId = _launch(1_000); // 1 000 tokens total
        // ask cost for (1 µ + 123 wei) instead of exactly 1 µ
        uint96 ask = uint96(MICRO + 123);
        uint256 costFloored = curve.buyCost(coinId, ask);
        // should equal cost of exactly 1 µ
        uint256 costExact = curve.buyCost(coinId, uint96(MICRO));
        assertEq(costFloored, costExact, "buyCost must quantizeDown input");
    }

    /* 21. sellRefund floors non‑aligned coins via _quantizeDown */
    function testSellRefundQuantizationDown() public {
        uint256 coinId = _launch(1_000);
        // mint 10 µ free tokens
        vm.prank(userA);
        curve.buyExactCoins{value: 0}(coinId, uint96(10 * MICRO), type(uint256).max);

        // ask refund for (5 µ + 321 wei)
        uint96 ask = uint96(5 * MICRO + 321);
        uint256 refFloored = curve.sellRefund(coinId, ask);
        // should equal refund for exactly 5 µ
        uint256 refExact = curve.sellRefund(coinId, uint96(5 * MICRO));
        assertEq(refFloored, refExact, "sellRefund must quantizeDown input");
    }

    /* 22. sellForExactEth rounds up burn amounts via _quantizeUp (steep curve) */
    function testSellForExactEthQuantizeUp() public {
        // ── Setup a small sale but with a steep curve so the 2nd µ‑token costs 1 wei ──
        uint96 capTokens = uint96(100 * TOKEN); // 100 full tokens
        uint96 cap = capTokens; // saleCap and lpSupply
        uint256 steepDiv = 1e18; // divisor small enough that cost(2 µ) == 1 wei

        // Launch with steep curve
        (uint256 coinId,) = curve.launch(
            0, // creatorSupply
            0, // creatorUnlock
            cap, // saleCap
            cap, // lpSupply
            100 ether, // ethTarget
            steepDiv, // divisor
            30, // feeOrHook (use a simple fee to keep it valid)
            "steep-curve"
        );

        // Buy exactly 2 µ‑tokens: first is free, second costs 1 wei
        uint96 twoMicros = uint96(2 * MICRO);
        uint256 costForTwo = curve.buyCost(coinId, twoMicros);
        assertEq(costForTwo, 1, "cost(2 u) must be exactly 1 wei under steepDiv=1e18");

        vm.prank(userA);
        curve.buyExactCoins{value: costForTwo}(coinId, twoMicros, type(uint256).max);

        // Compute the refund for 1 µ
        uint96 oneMicro = uint96(MICRO);
        uint256 oneRefund = curve.sellRefund(coinId, oneMicro);
        assertEq(oneRefund, 1, "refund(1 u) must be 1 wei");

        // tokensToBurnForEth should round up to 1 µ
        uint256 desired = oneRefund;
        uint96 quote = curve.tokensToBurnForEth(coinId, desired);
        assertEq(quote, oneMicro, "tokensToBurnForEth must quantizeUp to 1 u");

        // Finally sellForExactEth: should burn 1 µ and refund ≥ desired
        vm.prank(userA);
        (uint96 burned, uint256 refundWei) = curve.sellForExactEth(coinId, desired, oneMicro);

        assertEq(burned, oneMicro, "must burn exactly the quoted 1 u");
        assertGe(refundWei, desired, "refund must cover the desired amount");
    }

    /* 23. large‐volume 1 b token sale: launch and worst‐case cost */
    function testLargeSaleCapAndCost() public {
        // 1 billion 18‑dec tokens → saleCap = 1e9 * 1e18 = 1e27
        uint96 largeCap = uint96(1e9 * TOKEN);
        // must also be ≥ 5 ETH; here 1e9 ETH ≫ 5 ETH
        (uint256 coinId,) = curve.launch(0, 0, largeCap, largeCap, TARGET, DIV, 30, "big sale");

        // query worst‑case cost to buy the full cap
        uint256 worst = curve.buyCost(coinId, largeCap);
        assertGt(worst, 0, "cost>0 for large saleCap");
        // must fit within uint256/2 per launch’s safety check
        assertLe(worst, type(uint256).max / 2, "worst case cost must satisfy safety bound");
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
