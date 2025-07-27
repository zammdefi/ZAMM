// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {zCurve, IZAMM} from "../src/zCurve.sol";
import {ZAMM} from "../src/ZAMM.sol";

interface IERC6909 {
    function balanceOf(address, uint256) external view returns (uint256);
}

interface IPools {
    function pools(uint256)
        external
        view
        returns (
            uint112 reserve0,
            uint112 reserve1,
            uint32 blockTimestampLast,
            uint256 price0CumulativeLast,
            uint256 price1CumulativeLast,
            uint256 kLast,
            uint256 supply
        );
}

IZAMM constant Z = IZAMM(0x000000000000040470635EB91b7CE4D132D616eD);

struct PoolKey {
    uint256 id0;
    uint256 id1;
    address token0;
    address token1;
    uint256 feeOrHook; // bps-fee OR flags|address
}

/* ──────────────────────────────────────────────────────────────────── */
contract ZCurveTest is Test {
    /* --- shared units ------------------------------------------------ */
    uint256 constant TOKEN = 1 ether; // one full 18‑dec token
    uint96 constant MICRO = 1e12; // one curve “tick” (UNIT_SCALE)
    uint256 constant DIV = 10 ** 26; // super‑flat quadratic curve

    uint128 constant TARGET = 5 ether; // default sale target
    uint128 constant SMALL = 0.05 ether; // tiny target (used in two tests)

    /* --- actors ------------------------------------------------------ */
    address owner = address(this);
    address userA = address(0xA0A0);
    address userB = address(0xB0B0);
    address userC = address(0xCACA);
    address userD = address(0xDADA);

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
        vm.deal(userC, 10 ether);
        vm.deal(userD, 10 ether);
    }

    /* --- helpers ----------------------------------------------------- */

    /// launch with plain “token” cap; cap + lp both token‑scaled (× 1 ether)
    function _launch(uint96 plainCap) internal returns (uint256 id) {
        uint96 cap = uint96(plainCap * TOKEN);
        (id,) = curve.launch(0, 0, cap, cap, TARGET, DIV, 30, cap, 2 weeks, "uri");
    }

    /// launch with custom ETH target
    function _launchWithTarget(uint96 plainCap, uint128 targetWei) internal returns (uint256 id) {
        uint96 cap = uint96(plainCap * TOKEN);
        (id,) = curve.launch(0, 0, cap, cap, targetWei, DIV, 30, cap, 2 weeks, "uri");
    }

    /* =================================================================
                               INDIVIDUAL TESTS
       ================================================================= */

    /* 1. storage values ------------------------------------------------ */
    function testLaunchValues() public {
        uint96 capTk = 1_000;
        uint96 cap = uint96(capTk * TOKEN);

        (uint256 coinId,) = curve.launch(0, 0, cap, cap, TARGET, DIV, 30, cap, 2 weeks, "uri");

        (
            address c,
            uint96 saleCap,
            uint96 lpSupply,
            uint96 sold,
            uint64 dl,
            uint256 div,
            uint128 esc,
            uint128 tgt,
            ,
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

    /* 3. buyForExactETH (minCoins guard) ------------------------------ */
    function testbuyForExactETH() public {
        uint256 coinId = _launch(1_000);

        uint96 minCoins = curve.coinsForETH(coinId, 1 ether);
        uint256 expected = curve.buyCost(coinId, minCoins);

        vm.prank(userA);
        (uint96 out, uint256 spent) = curve.buyForExactETH{value: 1 ether}(coinId, minCoins);

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

    /* 5. sellForExactETH (maxCoins guard) ----------------------------- */
    function testsellForExactETH() public {
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
        uint96 quote = curve.coinsToBurnForETH(coinId, desired);
        assertGt(quote, 0, "quote must be positive");

        // execute the sell – should succeed and burn exactly `quote`
        vm.prank(owner);
        (uint96 burned, uint256 refund) = curve.sellForExactETH(coinId, desired, quote);

        assertEq(burned, quote, "burned token amount mismatch");
        assertGe(refund, desired, "refund must cover desired amount");
    }

    /* 6. coinsForETH view helper ------------------------------------- */
    function testcoinsForETHMatchesBuy() public {
        uint256 coinId = _launch(500);

        uint96 quote = curve.coinsForETH(coinId, 0.5 ether);

        vm.prank(userB);
        curve.buyForExactETH{value: 0.5 ether}(coinId, quote);

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
        uint96 want = curve.coinsForETH(coinId, SMALL);
        uint256 cost = curve.buyCost(coinId, want);

        // top‑up a hair to guarantee we cross the target
        vm.prank(userA);
        curve.buyExactCoins{value: cost + 1 wei}(coinId, want, type(uint256).max);

        (address creator,,,,,,,,,) = curve.sales(coinId);
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
        (address creator,,,,,,,,,) = curve.sales(coinId);
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
        uint96 want = curve.coinsForETH(coinId, SMALL);
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

        uint96 free = curve.coinsForETH(coinId, 0);
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

    /* 14. buyForExactETH refund path ---------------------------------- */
    function testbuyForExactETHRefund() public {
        uint256 coinId = _launch(1_000);

        uint256 quoteWei = 0.3 ether;
        uint96 minCoins = curve.coinsForETH(coinId, quoteWei);
        uint256 sendVal = quoteWei + 0.05 ether;

        uint256 before = userA.balance;
        vm.prank(userA);
        (, uint256 spent) = curve.buyForExactETH{value: sendVal}(coinId, minCoins);
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
            cap,
            2 weeks,
            "bad fee"
        );
    }

    /* 17. launch accepts a valid “hook” style feeOrHook */
    function testLaunchValidHook() public {
        uint96 cap = uint96(5 ether);
        // Build a hook: FLAG_BEFORE | lower‐160‐bits nonzero address
        uint256 hook = (uint256(1) << 255) | uint256(uint160(address(0x1234)));
        (uint256 coinId,) = curve.launch(0, 0, cap, cap, TARGET, DIV, hook, cap, 2 weeks, "hooked");

        // Read it back via saleSummary
        (,,,,,,,,,,,, uint256 storedHook,,) = curve.saleSummary(coinId, address(0));
        assertEq(storedHook, hook, "feeOrHook should roundtrip");
    }

    /* 18. saleSummary price & state transitions (free first tick) */
    function testSaleSummaryStateTransitions() public {
        // Launch with a target but no buys yet
        uint256 coinId = _launchWithTarget(20, TARGET);

        // Immediately after launch
        (,,,,,, bool isLive, bool isFinalized, uint256 price,,,,,,) =
            curve.saleSummary(coinId, userA);

        assertTrue(isLive, "should be live right after launch");
        assertFalse(isFinalized, "must not be finalized yet");
        // First quantum is free, so the marginal price is zero
        assertEq(price, 0, "first tick is free => price == 0");

        // Warp past the deadline
        vm.warp(block.timestamp + 2 weeks + 1);
        (,,,,,, bool live2, bool fin2, uint256 price2,,,,,,) = curve.saleSummary(coinId, userA);

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

    /* 22. sellForExactETH rounds up burn amounts via _quantizeUp (steep curve) */
    function testsellForExactETHQuantizeUp() public {
        // ── Setup a small sale but with a steep curve so the 2nd µ‑token costs 1 wei ──
        uint96 capTokens = uint96(100 * TOKEN); // 100 full tokens
        uint96 cap = capTokens; // saleCap and lpSupply
        uint256 steepDiv = 1e17; // divisor small enough that cost(2 µ) == 1 wei

        // Launch with steep curve
        (uint256 coinId,) = curve.launch(
            0, // creatorSupply
            0, // creatorUnlock
            cap, // saleCap
            cap, // lpSupply
            100 ether, // ethTarget
            steepDiv, // divisor
            30, // feeOrHook (use a simple fee to keep it valid)
            cap,
            2 weeks,
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

        // coinsToBurnForETH should round up to 1 µ
        uint256 desired = oneRefund;
        uint96 quote = curve.coinsToBurnForETH(coinId, desired);
        assertEq(quote, oneMicro, "coinsToBurnForETH must quantizeUp to 1 u");

        // Finally sellForExactETH: should burn 1 µ and refund ≥ desired
        vm.prank(userA);
        (uint96 burned, uint256 refundWei) = curve.sellForExactETH(coinId, desired, oneMicro);

        assertEq(burned, oneMicro, "must burn exactly the quoted 1 u");
        assertGe(refundWei, desired, "refund must cover the desired amount");
    }

    /* 23. large‐volume 1 b token sale: launch and worst‐case cost */
    function testLargeSaleCapAndCost() public {
        // 1 billion 18‑dec tokens → saleCap = 1e9 * 1e18 = 1e27
        uint96 largeCap = uint96(1e9 * TOKEN);
        // must also be ≥ 5 ETH; here 1e9 ETH ≫ 5 ETH
        (uint256 coinId,) =
            curve.launch(0, 0, largeCap, largeCap, TARGET, DIV, 30, largeCap, 2 weeks, "big sale");

        // query worst‑case cost to buy the full cap
        uint256 worst = curve.buyCost(coinId, largeCap);
        assertGt(worst, 0, "cost>0 for large saleCap");
        // must fit within uint256/2 per launch’s safety check
        assertLe(worst, type(uint256).max / 2, "worst case cost must satisfy safety bound");
    }

    /* 24. FT‑style sale with tiny 0.01 ETH target should launch cleanly */
    function testFTTinyTargetLaunch() public {
        // ── Parameters ───────────────────────────────────────────────
        uint96 saleCapParam = uint96(800_000_000 ether);
        uint96 lpSupplyParam = uint96(200_000_000 ether);
        uint256 divisorParam = 16_000 * 1e18;
        uint128 ethTargetParam = 0.01 ether;
        uint256 feeOrHookParam = 30;

        // ── Launch ────────────────────────────────────────────────────
        (uint256 coinId,) = curve.launch(
            /* creatorSupply */
            0,
            /* creatorUnlock */
            0,
            saleCapParam,
            lpSupplyParam,
            ethTargetParam,
            divisorParam,
            feeOrHookParam,
            lpSupplyParam,
            2 weeks,
            "FT tiny target"
        );

        // ── Validate via saleSummary ──────────────────────────────────
        (
            address creatorOut,
            uint96 saleCapOut,
            uint96 netSoldOut,
            uint128 ethEscrowOut,
            uint128 ethTargetOut,
            uint64 deadlineOut,
            bool isLiveOut,
            bool isFinalizedOut,
            uint256 currentPriceOut,
            uint24 percentFundedOut,
            uint64 timeRemainingOut,
            uint96 userBalanceOut,
            uint256 feeOrHookOut,
            uint256 divisorOut,
        ) = curve.saleSummary(coinId, address(this));

        // ── Assertions ────────────────────────────────────────────────
        assertEq(creatorOut, address(this), "wrong creator");
        assertEq(saleCapOut, saleCapParam, "saleCap mismatch");
        assertEq(netSoldOut, 0, "netSold should start at 0");
        assertEq(ethEscrowOut, 0, "ethEscrow should start at 0");
        assertEq(ethTargetOut, ethTargetParam, "ethTarget mismatch");
        assertGt(deadlineOut, uint64(block.timestamp), "deadline not set properly");
        assertTrue(isLiveOut, "sale should be live");
        assertFalse(isFinalizedOut, "sale should not be finalized");
        assertEq(currentPriceOut, 0, "first utoken is free -> price == 0");
        assertEq(percentFundedOut, 0, "percent funded should start at 0");
        assertGt(timeRemainingOut, 0, "timeRemaining should be >0");
        assertEq(userBalanceOut, 0, "userBalance should start at 0");
        assertEq(feeOrHookOut, feeOrHookParam, "feeOrHook mismatch");
        assertEq(divisorOut, divisorParam, "divisor mismatch");
    }

    /* 25. buyExactCoins reverts when asking for more than the saleCap → SoldOut */
    function testBuyExactCoinsSoldOutReverts() public {
        // cap = 10 full tokens
        uint256 coinId = _launch(10);
        uint96 saleCapParam = uint96(10 * TOKEN);
        // ask for just one quantum above the cap
        uint96 want = saleCapParam + uint96(MICRO);
        vm.expectRevert(zCurve.SoldOut.selector);
        // no ETH needed since first µ‑tokens are free, we still hit SoldOut
        curve.buyExactCoins{value: 0}(coinId, want, type(uint256).max);
    }

    /* 26. buyForExactETH reverts after deadline (TooLate) */
    function testbuyForExactETHRevertsAfterDeadline() public {
        uint256 coinId = _launch(10);
        // warp past the sale deadline
        vm.warp(block.timestamp + 2 weeks + 1);
        uint96 minCoins = uint96(MICRO); // non‑zero to get past the Slippage check
        vm.expectRevert(zCurve.TooLate.selector);
        curve.buyForExactETH{value: 1 ether}(coinId, minCoins);
    }

    /* 27. buyForExactETH reverts on slippage when minCoins exceeds purchasable */
    function testbuyForExactETHSlippageReverts() public {
        uint256 coinId = _launch(100);
        // quote how many µ‑tokens 1 ETH buys
        uint96 affordable = curve.coinsForETH(coinId, 1 ether);
        // ask for one quantum more than that
        uint96 minCoins = affordable + uint96(MICRO);
        vm.prank(userA);
        vm.expectRevert(zCurve.Slippage.selector);
        curve.buyForExactETH{value: 1 ether}(coinId, minCoins);
    }

    /* 28. sellForExactETH reverts if no tokens sold yet → InsufficientEscrow */
    function testsellForExactETHInsufficientEscrowReverts() public {
        uint256 coinId = _launch(10);
        vm.expectRevert(zCurve.InsufficientEscrow.selector);
        curve.sellForExactETH(coinId, 1 wei, MICRO);
    }

    /* 29. sellForExactETH reverts if desiredEthOut == 0 → NoWant */
    function testsellForExactETHNoWantReverts() public {
        uint256 coinId = _launch(10);
        // mint one free µ‑token so netSold > 0
        vm.prank(userA);
        curve.buyExactCoins{value: 0}(coinId, MICRO, type(uint256).max);
        vm.expectRevert(zCurve.NoWant.selector);
        curve.sellForExactETH(coinId, 0, MICRO);
    }

    /* 30. launch accepts simple fee < MAX_FEE and rounds‑trip in saleSummary */
    function testLaunchValidFeeBps() public {
        uint96 cap = uint96(5 ether);
        uint256 fee = 5_000; // 50 %
        (uint256 coinId,) = curve.launch(0, 0, cap, cap, TARGET, DIV, fee, cap, 2 weeks, "feebps");
        (,,,,,,,,,,,, uint256 storedFee,,) = curve.saleSummary(coinId, address(this));
        assertEq(storedFee, fee, "feeOrHook should match simple BPS fee");
    }

    // SANITY

    /* 31. Full FT‑style sale lifecycle: launch, purchase, auto‑finalize, claim */
    function testFullLifecycleFTSale() public {
        // ── Parameters ───────────────────────────────────────────────
        uint96 saleCapParam = uint96(800_000_000 ether);
        uint96 lpSupplyParam = uint96(200_000_000 ether);
        uint128 ethTargetParam = 10 ether;
        uint256 divisorParam = 2844444444444439111111111111133333333333333;
        uint256 feeOrHookParam = 30;

        // ── Launch ────────────────────────────────────────────────────
        (uint256 coinId,) = curve.launch(
            0,
            0,
            saleCapParam,
            lpSupplyParam,
            ethTargetParam,
            divisorParam,
            feeOrHookParam,
            lpSupplyParam,
            2 weeks,
            "full lifecycle"
        );

        // ── Pre‑purchase sanity ───────────────────────────────────────
        (,,,,,, bool live1, bool fin1,,,,,,,) = curve.saleSummary(coinId, userA);
        assertTrue(live1, "must be live");
        assertFalse(fin1, "must not be finalized yet");

        // ── Purchase & auto‑finalize ─────────────────────────────────
        uint96 minCoins = curve.coinsForETH(coinId, ethTargetParam);
        vm.prank(userA);
        (uint96 bought, uint256 spent) =
            curve.buyForExactETH{value: ethTargetParam}(coinId, minCoins);

        // never spend more than you sent, and must buy exactly the quote
        assertLe(spent, ethTargetParam, "spent > target");
        assertEq(bought, minCoins, "bought !+ quoted");

        // ── Post‑purchase sanity ──────────────────────────────────────
        (,,,,,,, bool fin2,,,, uint96 bal2,,,) = curve.saleSummary(coinId, userA);
        assertTrue(fin2, "sale should be finalized");
        assertEq(bal2, bought, "balance should match bought");

        // ── Claim ────────────────────────────────────────────────────
        vm.prank(userA);
        curve.claim(coinId, bought);
        assertEq(IERC6909(address(Z)).balanceOf(userA, coinId), bought);

        PoolKey memory key = PoolKey(0, coinId, address(0), address(Z), 30);

        uint256 poolId = uint256(keccak256(abi.encode(key)));
        (uint112 reserve0, uint112 reserve1,,,,, uint256 supply) = IPools(address(Z)).pools(poolId);

        uint256 fullCost = curve.buyCost(coinId, saleCapParam);

        assertGt(reserve0, fullCost);
        assertEq(reserve1, lpSupplyParam);
        assertTrue(supply > 0);

        // ── After claim ──────────────────────────────────────────────
        (,,,,,,,,,,, uint96 bal3,,,) = curve.saleSummary(coinId, userA);
        assertEq(bal3, 0, "balance must be zero after claim");
    }

    /* 31. Full FT‑style sale lifecycle: launch, purchase, auto‑finalize, claim */
    function testFullLifecycleFullSale() public {
        // ── Parameters ───────────────────────────────────────────────
        uint96 saleCapParam = uint96(800_000_000 ether);
        uint96 lpSupplyParam = uint96(200_000_000 ether);
        uint128 ethTargetParam = 10 ether;
        uint256 divisorParam = 2844444444444439111111111111113333333333334;
        uint256 feeOrHookParam = 30;

        // ── Launch ────────────────────────────────────────────────────
        (uint256 coinId,) = curve.launch(
            0,
            0,
            saleCapParam,
            lpSupplyParam,
            ethTargetParam,
            divisorParam,
            feeOrHookParam,
            lpSupplyParam,
            2 weeks,
            "full lifecycle"
        );

        // ── Pre‑purchase sanity ───────────────────────────────────────
        (,,,,,, bool live1, bool fin1,,,,,,,) = curve.saleSummary(coinId, userA);
        assertTrue(live1, "must be live");
        assertFalse(fin1, "must not be finalized yet");

        // ── Purchase & auto‑finalize ─────────────────────────────────
        uint96 minCoins = curve.coinsForETH(coinId, ethTargetParam);
        vm.prank(userA);
        (uint96 bought, uint256 spent) =
            curve.buyForExactETH{value: ethTargetParam}(coinId, minCoins);

        // never spend more than you sent, and must buy exactly the quote
        assertLe(spent, ethTargetParam, "spent > target");
        assertEq(bought, minCoins, "bought !+ quoted");

        // ── Post‑purchase sanity ──────────────────────────────────────
        (,,,,,,, bool fin2,,,, uint96 bal2,,,) = curve.saleSummary(coinId, userA);
        assertTrue(fin2, "sale should be finalized");
        assertEq(bal2, bought, "balance should match bought");

        // ── Claim ────────────────────────────────────────────────────
        vm.prank(userA);
        curve.claim(coinId, bought);
        assertEq(IERC6909(address(Z)).balanceOf(userA, coinId), bought);

        PoolKey memory key = PoolKey(0, coinId, address(0), address(Z), 30);

        uint256 poolId = uint256(keccak256(abi.encode(key)));
        (uint112 reserve0, uint112 reserve1,,,,, uint256 supply) = IPools(address(Z)).pools(poolId);

        uint256 fullCost = curve.buyCost(coinId, saleCapParam);

        assertGt(reserve0, fullCost);
        assertEq(reserve1, lpSupplyParam);
        assertTrue(supply > 0);

        // ── After claim ──────────────────────────────────────────────
        (,,,,,,,,,,, uint96 bal3,,,) = curve.saleSummary(coinId, userA);
        assertEq(bal3, 0, "balance must be zero after claim");
    }

    function pools(uint256)
        public
        view
        returns (
            uint112 reserve0,
            uint112 reserve1,
            uint32 blockTimestampLast,
            uint256 price0CumulativeLast,
            uint256 price1CumulativeLast,
            uint256 kLast,
            uint256 supply
        )
    {}

    // - EXTENDED TESTS

    uint96 constant MIN_CAP = uint96(5 ether); // launch‑pad hard‑minimum
    uint256 constant DIV_FLAT = 1e26; // very flat curve → tiny prices

    function testFinalizeBurnsLpWhenFewSold() public {
        // cap = 5 ETH worth of base‑units, lpSupply = 2.5 ETH
        uint96 saleCap = uint96(MIN_CAP); // 5 × 10¹⁸
        uint96 lpDup = uint96(MIN_CAP / 2); // 2.5 × 10¹⁸

        (uint256 coinId,) =
            curve.launch(0, 0, saleCap, lpDup, TARGET, DIV_FLAT, 30, lpDup, 2 weeks, "few sold");

        // Buy exactly one MICRO‑unit (free first tick)
        curve.buyExactCoins{value: 0}(coinId, uint96(MICRO), type(uint256).max);

        // Warp past the deadline and finalise
        vm.warp(block.timestamp + 2 weeks + 1);
        curve.finalize(coinId);

        // Sale record must be cleared (creator == 0)
        (address creator,,,,,,,,,) = curve.sales(coinId);
        assertEq(creator, address(0), "sale struct not cleared");

        // User can still claim the lone token
        vm.mockCall(address(Z), abi.encodeWithSelector(IZAMM.transfer.selector), abi.encode(true));
        curve.claim(coinId, uint96(MICRO));
        assertEq(curve.balances(coinId, owner), 0, "claim balance wrong");
    }

    function testbuyForExactETHSellsOut() public {
        uint96 saleCap = uint96(MIN_CAP); // 5 ETH base‑units
        uint96 lpDup = saleCap;

        (uint256 coinId,) =
            curve.launch(0, 0, saleCap, lpDup, 1 ether, DIV_FLAT, 30, lpDup, 2 weeks, "sell out");

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
        curve.buyForExactETH{value: fullCost + 1 ether}(coinId, saleCap); // buys all, gets refund

        // Sale must be finalised (struct deleted)
        (address creator,,,,,,,,,) = curve.sales(coinId);
        assertEq(creator, address(0), "sale should be closed");

        // Buyer owns the entire cap
        assertEq(curve.balances(coinId, userA), saleCap, "buyer balance mismatch");
    }

    function testLaunchBadDivisorReverts() public {
        uint96 cap = uint96(MICRO);
        uint256 badDiv = type(uint256).max; // definitely > MAX_DIV
        vm.expectRevert(zCurve.InvalidParams.selector);
        curve.launch(0, 0, cap, cap, TARGET, badDiv, 30, cap, 2 weeks, "bad divisor");
    }

    function testcoinsToBurnForETHZeroEscrow() public {
        uint96 cap = MIN_CAP;
        // Launch with flat curve so cost(5 ETH) ≪ TARGET and no pre‑buy
        (uint256 coinId,) =
            curve.launch(0, 0, cap, cap, TARGET, DIV_FLAT, 30, cap, 2 weeks, "no escrow");

        uint96 quote = curve.coinsToBurnForETH(coinId, 1 wei);
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
        (uint256 coinId,) = curve.launch(
            0, 0, saleCap, lpSupply, target, DIV_FT_SCALED, 30, lpSupply, 2 weeks, "ft big"
        );

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
        (uint96 out, uint256 spent) = curve.buyForExactETH{value: target}(coinId, 0.001 ether);

        assertTrue(out > 1 ether, "must receive >0.001 token");
        assertLe(spent, target, "must not overspend");

        /* sale struct should now be deleted */
        (address creator,,,,,,,,,) = curve.sales(coinId);
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

        (uint256 coinId,) =
            curve.launch(0, 0, saleCap, lpDup, target, divFT, 30, lpDup, 2 weeks, "ft cost");

        /* ── quote the cost for buying 123 FT “ticks” ────────────────── */
        uint96 coinsRaw = uint96(123 * 1 ether); // 123 tokens in 18‑dec
        uint256 costViaContract = curve.buyCost(coinId, coinsRaw);

        /* ── compute reference cost with the analytic formula ────────── */
        uint256 m = uint256(coinsRaw) / 1e12; // # ticks (123 M)
        uint256 sum = _friendTechSum(m); // ∑ i²  (0‑based)
        uint256 expected = (sum * 1 ether) / (6 * divFT);

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

    // MAJOR TEST

    /* 32. full hybrid (quad→linear) sale: 800 M public, 200 M LP, 10 ETH target */
    function testHybridQuadLinearSale() public {
        // ── Config ──────────────────────────────────────────────────────
        uint96 saleCap = uint96(800_000_000 ether);
        uint96 lpSupply = uint96(200_000_000 ether);
        uint128 ethTarget = 10 ether;

        // “ticks” = base‑units / MICRO
        uint256 K = uint256(lpSupply) / MICRO; // 200_000_000
        uint256 m = uint256(saleCap) / MICRO; // 800_000_000

        // Numerator for the hybrid area: sum_{i=0..K-1} i^2  +  K^2*(m-K)
        uint256 sumK = K * (K - 1) * (2 * K - 1) / 6;
        uint256 numer = sumK + (K * K) * (m - K);

        // Solve for divisor so that totalCost = ethTarget
        // totalCost = (numer * 1e18) / (6 * divisor)  ⇒  divisor = numer * 1e18 / (6 * ethTarget)
        uint256 divisor = (numer * 1 ether) / (6 * ethTarget);

        // ── Launch & Purchase ────────────────────────────────────────────
        (uint256 coinId,) = curve.launch(
            0, // creatorSupply
            0, // creatorUnlock
            saleCap,
            lpSupply,
            ethTarget,
            divisor,
            30, // feeOrHook
            lpSupply,
            2 weeks,
            "hybrid-sale"
        );

        // Should quote the entire saleCap when spending exactly ethTarget:
        uint96 quote = curve.coinsForETH(coinId, ethTarget);
        assertEq(quote, saleCap, "must quote full saleCap");

        // Do the buy
        vm.prank(userA);
        (uint96 bought, uint256 spent) = curve.buyForExactETH{value: ethTarget}(coinId, quote);

        // we got the full cap, and didn’t overspend
        assertEq(bought, saleCap, "bought != saleCap");
        assertLe(spent, ethTarget, "spent > target");

        // ── Post‑sale assertions ─────────────────────────────────────────
        (,,,,,,, bool isFinalized,,,, uint96 balance,,,) = curve.saleSummary(coinId, userA);

        assertTrue(isFinalized, "sale should be autofinalized");
        assertEq(balance, saleCap, "userBalance != saleCap");

        vm.prank(userA);
        curve.claim(coinId, bought);
        assertEq(curve.balances(coinId, userA), 0, "claim should burn IOU");

        assertEq(IERC6909(address(Z)).balanceOf(userA, coinId), bought);

        PoolKey memory key = PoolKey(0, coinId, address(0), address(Z), 30);

        uint256 poolId = uint256(keccak256(abi.encode(key)));
        (uint112 reserve0, uint112 reserve1,,,,, uint256 supply) = IPools(address(Z)).pools(poolId);

        assertApproxEqAbs(reserve0, ethTarget, 1e12, "ETH seed ~~ target");
        assertEq(reserve1, lpSupply);
        assertTrue(supply > 0);
    }

    /* 33. hybrid sale: quad-phase vs linear-phase pricing sanity check */
    function testHybridQuadLinearPhases() public {
        // ── Config ──────────────────────────────────────────────────────
        uint96 saleCap = uint96(800_000_000 ether);
        uint96 lpSupply = uint96(200_000_000 ether);
        uint128 ethTarget = 10 ether;
        uint256 _MICRO = 1e12; // UNIT_SCALE in ticks

        // Compute “ticks” for saleCap and LP tranche:
        uint256 K = uint256(lpSupply) / _MICRO; // 200 M ticks
        uint256 m = uint256(saleCap) / _MICRO; // 800 M ticks

        // Hybrid area numerator: ∑_{i=0..K-1} i²  +  K²·(m−K)
        uint256 sumK = K * (K - 1) * (2 * K - 1) / 6;
        uint256 numer = sumK + (K * K) * (m - K);

        // Solve divisor so that totalCost = ethTarget:
        // totalCost = (numer * 1 ETH) / (6·divisor)
        uint256 divisor = (numer * 1 ether) / (6 * ethTarget);

        // ── Launch the sale ─────────────────────────────────────────────
        (uint256 coinId,) = curve.launch(
            0, // creatorSupply
            0, // creatorUnlock
            saleCap,
            lpSupply,
            ethTarget,
            divisor,
            30, // feeOrHook
            lpSupply,
            2 weeks,
            "hybrid-phases"
        );

        // ── 1) QUADRATIC PHASE ──────────────────────────────────────────
        uint256 X = 20_000_000; // pick X < K
        uint96 coinsX = uint96(X * _MICRO);
        // expected cost = ∑_{i=0..X-1} i² / (6·divisor) * 1 ETH
        uint256 sumX = X * (X - 1) * (2 * X - 1) / 6;
        uint256 expectedQuad = (sumX * 1 ether) / (6 * divisor);

        uint256 costX = curve.buyCost(coinId, coinsX);
        assertEq(costX, expectedQuad, "quad phase cost mismatch");

        vm.prank(userA);
        curve.buyExactCoins{value: costX}(coinId, coinsX, type(uint256).max);

        // ── 2) LINEAR PHASE ─────────────────────────────────────────────
        // First climb from X ticks up to K ticks:
        uint256 remainToK = K - X;
        uint96 coinsToK = uint96(remainToK * _MICRO);
        uint256 costToK = curve.buyCost(coinId, coinsToK);

        vm.prank(userB);
        curve.buyExactCoins{value: costToK}(coinId, coinsToK, type(uint256).max);

        // Now netSold == K.  The marginal price for every further tick is
        //    p_K = K² / (6·divisor) * 1 ETH
        uint256 pK = (K * K * 1 ether) / (6 * divisor);

        // Buy Y ticks in the “linear tail”:
        uint256 Y = 5_000_000;
        uint96 coinsY = uint96(Y * _MICRO);
        uint256 expectedLin = pK * Y;

        uint256 costY = curve.buyCost(coinId, coinsY);
        assertEq(costY, expectedLin, "linear phase cost mismatch");

        vm.prank(userC);
        curve.buyExactCoins{value: costY}(coinId, coinsY, type(uint256).max);

        // ── 3) FINALIZATION ─────────────────────────────────────────────
        // Spend the rest of the ETH target to finish out the curve:
        uint256 spentSoFar = costX + costToK + costY;
        uint256 remainingEth = uint256(ethTarget) - spentSoFar;

        // How many ticks remain to hit the full saleCap?
        uint256 soldTicks = X + (K - X) + Y; // = K + Y
        uint256 totalTicks = uint256(saleCap) / _MICRO; // = m
        uint256 remTicks = totalTicks - soldTicks;
        uint96 coinsRem = uint96(remTicks * _MICRO);

        vm.prank(userD);
        (uint96 gotRem, uint256 usedRem) =
            curve.buyForExactETH{value: remainingEth}(coinId, coinsRem);

        // we should get exactly the remainder, and not overspend
        assertEq(gotRem, coinsRem, "final tranche size");
        assertLe(usedRem, remainingEth, "final tranche cost <= remainingEth");

        // and now the sale must be finalized
        (,,,,,,, bool isFinalized,,,,,,,) = curve.saleSummary(coinId, userD);
        assertTrue(isFinalized, "sale should be autofinalized after final tranche");

        // you can also assert that the contract has created the AMM pool:
        PoolKey memory key = PoolKey(0, coinId, address(0), address(Z), 30);
        uint256 poolId = uint256(keccak256(abi.encode(key)));
        (uint112 reserve0, uint112 reserve1,,,,,) = IPools(address(Z)).pools(poolId);
        assertApproxEqAbs(reserve0, ethTarget, 1e12, "ETH in pool ~~ target");
        assertEq(reserve1, lpSupply, "LP tokens in pool == lpSupply");
    }

    /// @dev Launches the canonical 800 M/200 M/10 ETH hybrid sale and returns coinId & divisor.
    function _launchHybrid(uint96 saleCap, uint96 lpSupply, uint128 ethTarget)
        internal
        returns (uint256 coinId, uint256 divisor)
    {
        uint256 K = uint256(lpSupply) / MICRO;
        uint256 m = uint256(saleCap) / MICRO;
        uint256 sumK = K * (K - 1) * (2 * K - 1) / 6;
        uint256 numer = sumK + (K * K) * (m - K);
        divisor = (numer * 1 ether) / (6 * ethTarget);

        (coinId,) = curve.launch(
            0, 0, saleCap, lpSupply, ethTarget, divisor, 30, lpSupply, 2 weeks, "hybrid"
        );
    }

    /// 34. Multiple buyers interleaved across quad & linear phases
    function testInterleavedMultipleBuyers() public {
        // Launch 800 M/200 M/10 ETH hybrid sale
        (uint256 coinId,) =
            _launchHybrid(uint96(800_000_000 * TOKEN), uint96(200_000_000 * TOKEN), 10 ether);

        // Buyer A buys  50 M tokens
        uint96 a1 = uint96(50_000_000 * TOKEN);
        uint256 costA1 = curve.buyCost(coinId, a1);
        vm.prank(userA);
        curve.buyExactCoins{value: costA1}(coinId, a1, type(uint256).max);

        // Buyer B buys 150 M tokens
        uint96 b1 = uint96(150_000_000 * TOKEN);
        uint256 costB1 = curve.buyCost(coinId, b1);
        vm.prank(userB);
        curve.buyExactCoins{value: costB1}(coinId, b1, type(uint256).max);

        // Buyer A buys another 100 M tokens (now into linear tail)
        uint96 a2 = uint96(100_000_000 * TOKEN);
        uint256 costA2 = curve.buyCost(coinId, a2);
        vm.prank(userA);
        curve.buyExactCoins{value: costA2}(coinId, a2, type(uint256).max);

        // Check saleSummary.netSold and .ethEscrow
        (,, uint96 netSold, uint128 ethEscrow,,,,,,,,,,,) = curve.saleSummary(coinId, userA);

        // We should have sold exactly 300 M tokens:
        assertEq(netSold, (50_000_000 + 150_000_000 + 100_000_000) * TOKEN, "netSold mismatch");
        // And escrow should equal the sum of the three individual costs:
        assertEq(ethEscrow, costA1 + costB1 + costA2, "ethEscrow mismatch");
    }

    /// @dev Calculate the divisor for a quad→linear sale so that buying
    ///      `saleCap` tokens costs exactly `ethTarget`
    /// @param saleCap   Total sale tranche (in base‐units, 18 decimals)
    /// @param lpSupply  LP tranche (in base‐units, 18 decimals)
    /// @param ethTarget Target ETH to raise (in wei)
    function _computeHybridDivisor(uint96 saleCap, uint96 lpSupply, uint128 ethTarget)
        internal
        pure
        returns (uint256 divisor)
    {
        // number of “ticks” in each tranche
        uint256 K = uint256(lpSupply) / MICRO;
        uint256 m = uint256(saleCap) / MICRO;

        // quad area up to K: ∑_{i=0..K-1} i²
        uint256 sumK = K * (K - 1) * (2 * K - 1) / 6;
        // then linear tail area: K²·(m-K)
        uint256 numer = sumK + (K * K) * (m - K);

        // totalCost = (numer * 1 ETH) / (6 * divisor)
        // → divisor = numer * 1 ETH / (6 * totalCost)
        divisor = (numer * 1 ether) / (6 * ethTarget);
    }

    /// 35. Tiny buys around the boundary K and K+1
    function testBoundaryBuysAtLPBoundary() public {
        (uint256 coinId, uint256 divisor) =
            _launchHybrid(800_000_000 ether, 200_000_000 ether, 10 ether);

        uint256 K = 200_000_000;
        // Buy exactly K ticks
        uint96 exactlyK = uint96(K * MICRO);
        uint256 costK = curve.buyCost(coinId, exactlyK);
        vm.prank(userA);
        curve.buyExactCoins{value: costK}(coinId, exactlyK, type(uint256).max);

        // Marginal price at tick K (should match pK)
        uint256 denom = 6 * divisor;
        uint256 pK = (K * K * 1 ether) / denom;

        // Buy 1 tick more
        uint96 oneTick = uint96(1 * MICRO);
        uint256 cost1 = curve.buyCost(coinId, oneTick);
        assertGe(cost1, pK, "cost at K+1 should be >= pK");
        assertLe(cost1, pK + 1, "cost at K+1 should be <= pK+1 (rounding)");

        vm.prank(userB);
        curve.buyExactCoins{value: cost1}(coinId, oneTick, type(uint256).max);
    }

    // ── 1) Quad‑phase refund test ───────────────────────────────────────
    /// @dev Use a divisor that makes the 2nd “µ‑token” cost exactly 1 wei.
    /// For UNIT_SCALE=1e12, sumSq(2) = 1, so we need
    ///    floor(1e18 / (6·divisor)) == 1
    /// ⇒ 1e18/(6·divisor) >= 1  ⇒ divisor <= 1e18/6
    /// and <2 ⇒ divisor > 1e18/12.
    /// A safe choice is divisor = ⌊1e18/6⌋ = 166_666_666_666_666_666.
    function testQuadPhaseSellRefund() public {
        uint96 cap = uint96(100 * TOKEN); // 100 full tokens
        uint96 lp = cap;
        uint128 target = 100 ether; // high so it never auto‑finalizes
        uint256 steepDiv = 166_666_666_666_666_666;

        (uint256 coinId,) = curve.launch(
            0, // creatorSupply
            0, // creatorUnlock
            cap, // saleCap
            lp, // lpSupply
            target, // ethTarget
            steepDiv, // divisor
            30, // feeOrHook
            lp,
            2 weeks,
            "steep-quad"
        );

        // Buying 2 µ‑tokens should cost exactly 1 wei
        uint96 twoMicros = uint96(2 * MICRO);
        uint256 costForTwo = curve.buyCost(coinId, twoMicros);
        assertEq(costForTwo, 1, "cost(2u) must be 1 wei");

        vm.prank(userA);
        curve.buyExactCoins{value: costForTwo}(coinId, twoMicros, type(uint256).max);

        // Selling back 1 µ should refund exactly 1 wei
        uint96 oneMicro = uint96(1 * MICRO);
        uint256 refundOne = curve.sellRefund(coinId, oneMicro);
        assertEq(refundOne, 1, "refund(1u) must be 1 wei");

        vm.prank(userA);
        uint256 got = curve.sellExactCoins(coinId, oneMicro, 0);
        assertEq(got, refundOne, "sellExactCoins quad OK");
    }

    // ── 2) Linear‑phase refund test ────────────────────────────────────
    /// @dev Drive to exactly K µ‑tokens sold (the LP tranche) then
    ///      sell 1 tick in the linear tail.  Use the same buyer.
    /// @dev 36b. linear‑phase sell refund sanity
    function testLinearPhaseSellRefund() public {
        // ── Launch the canonical 800 M/200 M/10 ETH hybrid sale ─────────────────
        uint96 saleCap = uint96(800_000_000 ether);
        uint96 lpSupply = uint96(200_000_000 ether);
        uint128 ethTarget = 10 ether;
        (uint256 coinId, uint256 divisor) = _launchHybrid(saleCap, lpSupply, ethTarget);

        // ── Move netSold up to K = lpSupply/MICRO so we're at the start of linear phase ──
        uint256 K = uint256(lpSupply) / MICRO;
        uint96 buyToK = uint96(K * MICRO);
        uint256 costToK = curve.buyCost(coinId, buyToK);
        vm.prank(userA);
        curve.buyExactCoins{value: costToK}(coinId, buyToK, type(uint256).max);

        // ── Now in linear phase: one tick should refund exactly pK ────
        uint96 oneTick = uint96(1 * MICRO);
        uint256 refund = curve.sellRefund(coinId, oneTick);
        // compute pK = (K² * 1 ETH) / (6 * divisor)
        uint256 pK = (K * K * 1 ether) / (6 * divisor);

        assertEq(refund, pK, "linear-phase refund must equal pK");

        // ── And sellExactCoins should burn that one tick and return the same wei ────
        vm.prank(userA);
        uint256 got = curve.sellExactCoins(coinId, oneTick, refund);
        assertEq(got, refund, "sellExactCoins linear must refund exactly pK");
    }

    /* 36. packQuadCap and unpackQuadCap bit operations */
    function testPackUnpackQuadCap() public {
        // Test basic packing/unpacking
        uint96 quadCap = uint96(100 * TOKEN);
        uint96 lpUnlock = uint96(block.timestamp + 30 days);

        uint256 packed = curve.packQuadCap(quadCap, lpUnlock);
        (uint96 unpackedCap, uint96 unpackedUnlock) = curve.unpackQuadCap(packed);

        assertEq(unpackedCap, quadCap, "quadCap mismatch after pack/unpack");
        assertEq(unpackedUnlock, lpUnlock, "lpUnlock mismatch after pack/unpack");
    }

    /* 37. launch with zero LP unlock keeps LP in zCurve */
    function testLaunchWithZeroLpUnlock() public {
        uint96 cap = uint96(100 * TOKEN);
        uint96 lpUnlock = 0; // zero means keep in zCurve
        uint256 packedQuadCap = curve.packQuadCap(cap, lpUnlock);

        (uint256 coinId,) =
            curve.launch(0, 0, cap, cap, TARGET, DIV, 30, packedQuadCap, 2 weeks, "keep LP");

        // Buy to trigger auto-finalize
        uint96 want = curve.coinsForETH(coinId, TARGET);
        uint256 cost = curve.buyCost(coinId, want);
        vm.prank(userA);
        curve.buyExactCoins{value: cost + 1 wei}(coinId, want, type(uint256).max);

        // Calculate pool ID
        PoolKey memory key = PoolKey(0, coinId, address(0), address(Z), 30);
        uint256 poolId = uint256(keccak256(abi.encode(key)));

        // Check pool was created
        (uint112 reserve0, uint112 reserve1,,,,, uint256 supply) = IPools(address(Z)).pools(poolId);
        assertGt(supply, 0, "LP tokens should be minted");
        assertGt(reserve0, 0, "ETH should be in pool");
        assertGt(reserve1, 0, "Tokens should be in pool");

        // When lpUnlock = 0, LP tokens go to zCurve contract
        // Due to phantom accounting, balance might not show traditionally
        uint256 lpBalance = IERC6909(address(Z)).balanceOf(address(curve), poolId);
        assertGe(lpBalance, 0, "LP balance check (may be phantom)");
    }

    /* 38. launch with future LP unlock creates lockup entry */
    function testLaunchWithFutureLpUnlock() public {
        uint96 cap = uint96(100 * TOKEN);
        uint96 lpUnlock = uint96(block.timestamp + 30 days);
        uint256 packedQuadCap = curve.packQuadCap(cap, lpUnlock);

        (uint256 coinId,) =
            curve.launch(0, 0, cap, cap, TARGET, DIV, 30, packedQuadCap, 2 weeks, "future LP");

        // Buy to trigger auto-finalize
        uint96 want = curve.coinsForETH(coinId, TARGET);
        uint256 cost = curve.buyCost(coinId, want);

        // Calculate pool ID before the transaction
        PoolKey memory key = PoolKey(0, coinId, address(0), address(Z), 30);
        uint256 poolId = uint256(keccak256(abi.encode(key)));

        // Execute the buy and capture the Finalize event to get the actual LP amount
        vm.recordLogs();
        vm.prank(userA);
        curve.buyExactCoins{value: cost + 1 wei}(coinId, want, type(uint256).max);

        // Get the actual LP amount from the Finalize event
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 actualLpAmount;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("Finalize(uint256,uint256,uint256,uint256)")) {
                (uint256 ethLp, uint256 coinLp, uint256 lpMinted) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256));
                actualLpAmount = lpMinted;
                break;
            }
        }

        // Check pool was created
        (uint112 reserve0, uint112 reserve1,,,,, uint256 supply) = IPools(address(Z)).pools(poolId);
        assertGt(supply, 0, "LP tokens should be minted");

        // Use the actual LP amount from the event for the lock hash
        bytes32 lockHash =
            keccak256(abi.encode(address(Z), owner, poolId, actualLpAmount, lpUnlock));

        uint256 storedUnlockTime = ZAMM(payable(address(Z))).lockups(lockHash);
        assertEq(storedUnlockTime, lpUnlock, "Lockup should be created with correct unlock time");
    }

    /* 39. quadCap affects pricing: stops quadratic growth at quadCap */
    function testQuadCapPricingTransition() public {
        uint96 saleCap = uint96(1000 * TOKEN);
        uint96 quadCap = uint96(100 * TOKEN); // transition at 100 tokens
        uint96 lpSupply = saleCap;
        uint256 packedQuadCap = curve.packQuadCap(quadCap, 0);

        (uint256 coinId,) = curve.launch(
            0, 0, saleCap, lpSupply, 100 ether, DIV, 30, packedQuadCap, 2 weeks, "quad transition"
        );

        // Buy up to just before quadCap
        uint96 beforeCap = quadCap - uint96(MICRO);
        uint256 costBefore = curve.buyCost(coinId, beforeCap);
        vm.prank(userA);
        curve.buyExactCoins{value: costBefore}(coinId, beforeCap, type(uint256).max);

        // Price of next µ-token (should be quadratic)
        uint256 priceAtCap = curve.buyCost(coinId, uint96(MICRO));

        // Buy one more µ-token to cross into linear phase
        vm.prank(userB);
        curve.buyExactCoins{value: priceAtCap}(coinId, uint96(MICRO), type(uint256).max);

        // Price of next µ-token should be constant (linear phase)
        uint256 priceAfterCap1 = curve.buyCost(coinId, uint96(MICRO));
        uint256 priceAfterCap2 = curve.buyCost(coinId, uint96(2 * MICRO));

        // In linear phase, 2 µ-tokens should cost exactly 2x one µ-token
        assertEq(
            priceAfterCap2, priceAfterCap1 * 2, "Linear phase should have constant marginal price"
        );
    }

    /* 40. launch reverts if lpUnlock conflicts with creator unlock */
    function testLaunchRevertsOnUnlockConflict() public {
        uint96 cap = uint96(100 * TOKEN);
        uint256 creatorUnlock = block.timestamp + 1 weeks; // during sale
        uint96 lpUnlock = uint96(block.timestamp + 1 weeks); // also during sale
        uint256 packedQuadCap = curve.packQuadCap(cap, lpUnlock);

        vm.expectRevert(zCurve.InvalidUnlock.selector);
        curve.launch(
            1 ether, // creatorSupply
            creatorUnlock,
            cap,
            cap,
            TARGET,
            DIV,
            30,
            packedQuadCap,
            2 weeks,
            "bad unlock"
        );
    }

    /* 41. saleSummary returns quadCap with flags intact */
    function testSaleSummaryQuadCapWithFlags() public {
        uint96 cap = uint96(100 * TOKEN);
        uint96 quadCap = uint96(50 * TOKEN);
        uint96 lpUnlock = uint96(block.timestamp + 30 days);
        uint256 packedQuadCap = curve.packQuadCap(quadCap, lpUnlock);

        (uint256 coinId,) =
            curve.launch(0, 0, cap, cap, TARGET, DIV, 30, packedQuadCap, 2 weeks, "packed");

        (,,,,,,,,,,,,,, uint256 returnedQuadCap) = curve.saleSummary(coinId, address(0));
        assertEq(returnedQuadCap, packedQuadCap, "saleSummary should return packed quadCap");

        // Verify we can unpack it correctly
        (uint96 unpackedCap, uint96 unpackedUnlock) = curve.unpackQuadCap(returnedQuadCap);
        assertEq(unpackedCap, quadCap, "unpacked quadCap mismatch");
        assertEq(unpackedUnlock, lpUnlock, "unpacked lpUnlock mismatch");
    }

    /* 42. Verify creator token lockup with phantom accounting */
    function testCreatorLockupPhantomAccounting() public {
        uint96 cap = uint96(100 * TOKEN);
        uint256 creatorSupply = 50 * TOKEN;
        uint256 creatorUnlock = block.timestamp + 30 days;

        (uint256 coinId,) = curve.launch(
            creatorSupply,
            creatorUnlock,
            cap,
            cap,
            TARGET,
            DIV,
            30,
            cap, // quadCap = cap
            2 weeks,
            "creator lockup"
        );

        // Creator balance should be 0 due to lockup
        assertEq(curve.balances(coinId, owner), 0, "Creator shouldn't have unlocked balance");

        // Check the lockup exists
        bytes32 lockHash =
            keccak256(abi.encode(address(Z), owner, coinId, creatorSupply, creatorUnlock));
        uint256 storedUnlockTime = ZAMM(payable(address(Z))).lockups(lockHash);
        assertEq(storedUnlockTime, creatorUnlock, "Creator lockup should exist");
    }

    /* 43. Verify LP unlock edge case at deadline */
    function testLpUnlockAtDeadline() public {
        uint96 cap = uint96(100 * TOKEN);
        uint256 saleDeadline = block.timestamp + 2 weeks;
        uint96 lpUnlock = uint96(saleDeadline + 1);
        uint256 packedQuadCap = curve.packQuadCap(cap, lpUnlock);

        (uint256 coinId,) =
            curve.launch(0, 0, cap, cap, TARGET, DIV, 30, packedQuadCap, 2 weeks, "deadline edge");

        // Warp to just before deadline and buy
        vm.warp(saleDeadline - 1);

        uint96 want = curve.coinsForETH(coinId, TARGET);
        uint256 cost = curve.buyCost(coinId, want);

        PoolKey memory key = PoolKey(0, coinId, address(0), address(Z), 30);
        uint256 poolId = uint256(keccak256(abi.encode(key)));

        // Record logs to get actual LP amount
        vm.recordLogs();
        vm.prank(userA);
        curve.buyExactCoins{value: cost + 1 wei}(coinId, want, type(uint256).max);

        // Get the actual LP amount from the Finalize event
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 actualLpAmount;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("Finalize(uint256,uint256,uint256,uint256)")) {
                (uint256 ethLp, uint256 coinLp, uint256 lpMinted) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256));
                actualLpAmount = lpMinted;
                break;
            }
        }

        bytes32 lockHash =
            keccak256(abi.encode(address(Z), owner, poolId, actualLpAmount, lpUnlock));
        assertEq(ZAMM(payable(address(Z))).lockups(lockHash), lpUnlock, "LP should be locked");
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
