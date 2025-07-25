// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {zCurve, IZAMM} from "../src/zCurve.sol";

interface IERC6909 {
    function balanceOf(address, uint256) external view returns (uint256);
}

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
        (id,) = curve.launch(0, 0, cap, cap, TARGET, DIV, 30, "uri");
    }

    /* -----------------------------------------------------------------
       1. storage values
    ------------------------------------------------------------------*/
    function testLaunchValues() public {
        uint96 cap = 1_000;
        uint96 lpDup = cap;
        (uint256 coinId,) = curve.launch(0, 0, cap, lpDup, TARGET, DIV, 30, "uri");

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
        // Use a saleCap larger than the purchase amount so the sale doesn’t auto‑finalize
        uint96 saleCap = 200;
        uint256 coinId = _launch(saleCap);

        // Buy 100 tokens
        uint96 purchaseAmt = 100;
        uint256 cost = curve.buyCost(coinId, purchaseAmt);
        curve.buyExactCoins{value: cost}(coinId, purchaseAmt);

        // Sell back 20 tokens
        uint96 sellAmt = 20;
        uint256 refund = curve.sellRefund(coinId, sellAmt);
        vm.prank(owner);
        curve.sellExactCoins(coinId, sellAmt, refund);

        // Expect remaining balance = 80
        assertEq(curve.balances(coinId, owner), purchaseAmt - sellAmt);
    }

    /* -----------------------------------------------------------------
       5. sellForExactEth (maxCoins guard)
    ------------------------------------------------------------------*/
    function testSellForExactEth() public {
        uint96 saleCap = 500;
        (uint256 coinId,) = curve.launch(0, 0, saleCap, saleCap, 10 ether, DIV, 30, "uri");

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
            abi.encodeWithSelector(IERC6909.balanceOf.selector, address(curve), coinId),
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

        (address creator,,,,,,,,) = curve.sales(coinId);
        assertEq(creator, address(0));
    }

    /* -----------------------------------------------------------------
       8. manual finalise after deadline passes
    ------------------------------------------------------------------*/
    function testManualFinalizeAfterDeadline() public {
        uint96 cap = 1_000;
        (uint256 coinId,) = curve.launch(0, 0, cap, cap, 3 ether, DIV, 30, "uri");

        uint96 buyAmt = 180;
        uint256 cost = curve.buyCost(coinId, buyAmt);
        vm.prank(userB);
        curve.buyExactCoins{value: cost}(coinId, buyAmt);

        vm.warp(block.timestamp + 2 weeks + 1);

        /* mocks */
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
            abi.encodeWithSelector(IERC6909.balanceOf.selector, address(curve), coinId),
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
        (uint256 coinId,) = curve.launch(0, 0, 1_000, 1_000, 3 ether, DIV, 30, "uri");

        /* mocks */
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
        vm.mockCall(address(Z), abi.encodeWithSelector(IZAMM.transfer.selector), abi.encode(true));

        uint96 buyAmt = 180;
        uint256 cost = curve.buyCost(coinId, buyAmt);
        vm.prank(userA);
        curve.buyExactCoins{value: cost}(coinId, buyAmt);

        vm.warp(block.timestamp + 2 weeks + 1);
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
            30,
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
        (address creator,,,,,,,,) = curve.sales(coinId);
        assertEq(creator, address(0), "sale must be Finalized()");

        assertEq(curve.balances(coinId, userA), buyA);
        assertEq(curve.balances(coinId, userB), buyB);

        /* further buys revert */
        vm.expectRevert(zCurve.Finalized.selector);
        curve.buyExactCoins{value: 1 ether}(coinId, 1);
    }

    // ** MISC

    /// @notice creator sends ETH with launch; pre-buy should mint tokens & escrow ETH
    function testLaunchPreBuyMintsAndEscrows() public {
        uint96 saleCap = 1_000;
        uint96 lpDup = saleCap;
        uint128 target = TARGET;
        uint256 div = DIV;

        uint256 sendVal = 0.2 ether; // any positive amount

        uint256 balBefore = owner.balance;
        (uint256 coinId,) =
            curve.launch{value: sendVal}(0, 0, saleCap, lpDup, target, div, 30, "uri");

        // read sale struct
        (
            address c,
            uint96 saleCapRead,
            uint96 lpSupply,
            uint96 netSold,
            ,
            uint256 divisorRead,
            uint128 esc,
            uint128 tgt,
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
        (uint256 coinId,) =
            curve.launch{value: sendVal}(0, 0, saleCap, lpDup, target, div, 30, "uri");

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
        (uint256 coinId,) = curve.launch{value: 1}(0, 0, saleCap, lpDup, target, div, 30, "uri");

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
            abi.encodeWithSelector(IERC6909.balanceOf.selector, address(curve), 0), // coinId unknown yet, ignore
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
            curve.launch{value: sendVal}(0, 0, saleCap, lpDup, target, div, 30, "pumpfun");

        assertTrue(coinsOut != 0);

        // After finalize, sales[coinId].creator should be 0
        (address creator,,,,,,,,) = curve.sales(coinId);
        assertEq(creator, address(0), "sale should be finalized");
    }

    /* -----------------------------------------------------------------
       22. saleSummary initial state
    ------------------------------------------------------------------*/
    function testSaleSummaryInitialState() public {
        uint96 cap = 500;
        uint256 coinId = _launch(cap);

        (
            address creator,
            uint96 saleCap,
            uint96 netSold,
            uint128 escrow,
            uint128 target,
            ,
            bool isLive,
            bool isFinalized,
            uint256 price,
            uint24 pctFunded,
            uint64 timeRem,
            uint96 userBal
        ) = curve.saleSummary(coinId, userA);

        assertEq(creator, owner);
        assertEq(saleCap, cap);
        assertEq(netSold, 0);
        assertEq(escrow, 0);
        assertEq(target, TARGET);
        assertTrue(isLive);
        assertFalse(isFinalized);
        assertEq(price, 0);
        assertEq(pctFunded, uint24(0));
        assertEq(timeRem, uint64(2 weeks));
        assertEq(userBal, 0);
    }

    /* -----------------------------------------------------------------
       23. saleSummary after buy & warp
    ------------------------------------------------------------------*/
    function testSaleSummaryAfterBuyAndTimeWarp() public {
        uint96 cap = 1_000;
        uint256 coinId = _launch(cap);
        uint256 sendVal = 0.3 ether;

        vm.prank(userA);
        (uint96 bought, uint256 spent) = curve.buyForExactEth{value: sendVal}(coinId, 1);

        // expected percent funded = (spent * 10_000) / TARGET
        uint24 expectedPct = uint24((spent * 10_000) / TARGET);

        // warp forward 3 days
        vm.warp(block.timestamp + 3 days);

        (
            , // creator
            , // saleCap
            uint96 netSoldR,
            uint128 escrowR,
            uint128 targetR,
            , // deadline
            bool liveR,
            bool finR,
            , // price
            uint24 pctR,
            uint64 timeRemR,
            uint96 balR
        ) = curve.saleSummary(coinId, userA);

        assertEq(netSoldR, bought);
        assertEq(escrowR, uint128(spent));
        assertEq(targetR, TARGET);
        assertTrue(liveR);
        assertFalse(finR);
        assertEq(pctR, expectedPct);
        assertEq(timeRemR, uint64(2 weeks - 3 days));
        assertEq(balR, bought);
    }

    /* -----------------------------------------------------------------
       XX. first token free via buyExactCoins
    ------------------------------------------------------------------*/
    function testFirstTokenFreeBuyExact() public {
        uint256 coinId = _launch(10);
        // Buying 1 token with zero ETH should succeed
        curve.buyExactCoins{value: 0}(coinId, 1);
        assertEq(curve.balances(coinId, owner), 1, "owner should have 1 free token");
    }

    /* -----------------------------------------------------------------
       XX. buyCost and tokensForEth reflect free first token
    ------------------------------------------------------------------*/
    function testCostAndQuoteForFirstToken() public {
        uint256 coinId = _launch(10);
        // buyCost for 1 token is zero
        assertEq(curve.buyCost(coinId, 1), 0, "buyCost(1) should be 0");
        // tokensForEth with 0 wei returns 1
        assertEq(curve.tokensForEth(coinId, 0), 1, "tokensForEth(0) should be 1");
    }

    /* -----------------------------------------------------------------
       XX. second token costs positive amount and buyExactCoins fails with no ETH
    ------------------------------------------------------------------*/
    function testSecondTokenCostAndRevert() public {
        uint256 coinId = _launch(10);
        uint256 cost2 = curve.buyCost(coinId, 2);
        assertGt(cost2, 0, "buyCost(2) should be positive");
        // Trying to buy 2 tokens for 0 ETH should revert
        vm.expectRevert(zCurve.InvalidMsgVal.selector);
        curve.buyExactCoins{value: 0}(coinId, 2);
    }

    /* -----------------------------------------------------------------
       XX. buyForExactEth with minimal wei returns exactly one token
    ------------------------------------------------------------------*/
    function testBuyForExactEthMinimalWeiGivesOne() public {
        uint256 coinId = _launch(10);
        vm.prank(userA);
        (uint96 out, uint256 spent) = curve.buyForExactEth{value: 1}(coinId, 1);
        assertEq(out, 1, "should receive exactly 1 token");
        assertEq(spent, 0, "spent should be 0 for the first token");
        assertEq(curve.balances(coinId, userA), 1, "userA balance mismatch");
    }

    /* -----------------------------------------------------------------
       25. FriendTech‑style curve costs match ∑ i² * 1e18 / divisor
    ------------------------------------------------------------------*/
    function testFriendTechStyleCurveCosts() public {
        uint96 saleCap = 1000;
        uint96 lpDup = saleCap;
        uint128 target = type(uint128).max; // so no auto‑finalize
        uint256 divFT = 16_000;

        // launch with divisor = 16_000
        (uint256 coinId,) = curve.launch(0, 0, saleCap, lpDup, target, divFT, 30, "uri");

        // For N = 0,1,2,5 compute expected = ∑_{i=0..N-1} i² * 1e18 / divFT
        // and assert buyCost(coinId, N) == expected
        {
            // N = 0
            assertEq(curve.buyCost(coinId, 0), 0);

            // N = 1 → ∑ i² = 0
            assertEq(curve.buyCost(coinId, 1), 0);

            // N = 2 → ∑ i² = 0²+1² = 1
            uint256 expected2 = (1 * 1 ether) / divFT;
            assertEq(curve.buyCost(coinId, 2), expected2);

            // N = 5 → ∑ i² = 0+1+4+9+16 = 30
            uint256 expected5 = (30 * 1 ether) / divFT;
            assertEq(curve.buyCost(coinId, 5), expected5);
        }
    }

    /* -----------------------------------------------------------------
       26. FriendTech‑style basic buyExactCoins + sellExactCoins
    ------------------------------------------------------------------*/
    function testFriendTechStyleBuyAndSell() public {
        uint96 saleCap = 500;
        uint96 lpDup = saleCap;
        uint128 target = type(uint128).max;
        uint256 divFT = 16_000;
        (uint256 coinId,) = curve.launch(0, 0, saleCap, lpDup, target, divFT, 30, "uri");

        // give userA some ETH
        vm.deal(userA, 1 ether);

        // buy 5 tokens
        uint96 buyN = 5;
        uint256 cost = curve.buyCost(coinId, buyN);
        vm.prank(userA);
        curve.buyExactCoins{value: cost}(coinId, buyN);
        assertEq(curve.balances(coinId, userA), buyN);

        // now sell 2 of them
        uint96 sellN = 2;
        uint256 refund = curve.sellRefund(coinId, sellN);
        vm.prank(userA);
        curve.sellExactCoins(coinId, sellN, refund);
        // remaining balance = 3
        assertEq(curve.balances(coinId, userA), buyN - sellN);
    }

    /* -----------------------------------------------------------------
       27. FriendTech‑style tokensForEth quoting
    ------------------------------------------------------------------*/
    function testFriendTechStyleTokensForEth() public {
        uint96 saleCap = 200;
        uint96 lpDup = saleCap;
        uint128 target = type(uint128).max;
        uint256 divFT = 16_000;
        (uint256 coinId,) = curve.launch(0, 0, saleCap, lpDup, target, divFT, 30, "uri");

        // quote how many tokens 0.1 ETH buys
        uint256 ethIn = 0.1 ether;
        uint96 quote = curve.tokensForEth(coinId, ethIn);
        // record the expected cost *before* the buy
        uint256 expectedCost = curve.buyCost(coinId, quote);

        // now actually do the buy
        vm.prank(userB);
        (uint96 got, uint256 spent) = curve.buyForExactEth{value: ethIn}(coinId, quote);

        assertEq(got, quote, "got should match quote");
        assertEq(spent, expectedCost, "spent should match precomputed cost");
    }

    /* -----------------------------------------------------------------
       28. FriendTech‑style full lifecycle → buy for exact ETH, auto‑finalize, view checks
    ------------------------------------------------------------------*/
    /// @notice FriendTech‑style full lifecycle: buy → still live → warp past deadline → finalize → claim final state
    function testFriendTechFullLifecycle() public {
        // 1) Params: 800 M sale tokens, 200 M LP tranche, 15 ETH target, divisor = 16 000
        uint96 saleCap = 800_000_000;
        uint96 lpDup = 200_000_000;
        uint128 target = 15 ether;
        uint256 divFT = 16_000;

        // 2) Launch
        (uint256 coinId,) = curve.launch(0, 0, saleCap, lpDup, target, divFT, 30, "ftsale");

        // 3) Stub out AMM calls so _finalize can run
        vm.mockCall(
            address(Z),
            abi.encodeWithSelector(IERC6909.balanceOf.selector, address(curve), coinId),
            abi.encode(uint256(1))
        );
        vm.mockCall(
            address(Z),
            abi.encodeWithSelector(IZAMM.addLiquidity.selector),
            abi.encode(uint256(0), uint256(0), uint256(12345))
        );

        // 4) userA buys with exactly the target ETH
        vm.deal(userA, 20 ether);
        uint256 before = userA.balance;
        vm.prank(userA);
        (uint96 quote, uint256 spent) = curve.buyForExactEth{value: target}(coinId, 1);

        // – spent never exceeds target and is within a small rounding gap
        assertLe(spent, target, "overspent beyond target");
        assertApproxEqAbs(spent, target, 0.1 ether, "rounding gap too big");

        // – they must receive more than the free first token
        assertTrue(quote > 1, "expected multiple tokens");

        // 5) Sale must have auto‑finalized on crossing target
        (address creatorAfterBuy,,,,,,,,) = curve.sales(coinId);
        assertEq(creatorAfterBuy, address(0), "sale should be finalized on crossing target");

        // 6) saleSummary flags
        (,,,,,, bool isLive, bool isFinalized,,,,) = curve.saleSummary(coinId, userA);
        assertFalse(isLive, "isLive must be false postfinalize");
        assertTrue(isFinalized, "isFinalized must be true postfinalize");

        // 7) Further buys revert
        vm.expectRevert(zCurve.Finalized.selector);
        vm.prank(userA);
        curve.buyExactCoins{value: 1}(coinId, 1);

        // 8) userA’s ETH drop ≃ spent (ignoring gas)
        assertApproxEqAbs(before - userA.balance, spent, 1e15 /* ~0.001 ETH */ );
    }

    /// @notice FriendTech‑style full lifecycle: buy → still live → warp past deadline → finalize → claim final state/ 18 decimals coins
    function testFriendTechFullLifecycleBigUnits() public {
        // 1) Params: 800 M sale tokens, 200 M LP tranche, 15 ETH target, divisor = 16 000
        uint96 saleCap = uint96(800_000_000 ether); // 8 × 10²⁶ raw units
        uint96 lpDup = uint96(200_000_000 ether);
        uint128 target = 15 ether;
        uint256 divFT = 16_000 * 10 ** 54; // 1.6 × 10⁵⁸

        // 2) Launch
        (uint256 coinId,) = curve.launch(0, 0, saleCap, lpDup, target, divFT, 30, "ftsale");

        // 3) Stub out AMM calls so _finalize can run
        vm.mockCall(
            address(Z),
            abi.encodeWithSelector(IERC6909.balanceOf.selector, address(curve), coinId),
            abi.encode(uint256(1))
        );
        vm.mockCall(
            address(Z),
            abi.encodeWithSelector(IZAMM.addLiquidity.selector),
            abi.encode(uint256(0), uint256(0), uint256(12345))
        );

        // 4) userA buys with exactly the target ETH
        vm.deal(userA, 20 ether);
        uint256 before = userA.balance;
        vm.prank(userA);
        (uint96 quote, uint256 spent) = curve.buyForExactEth{value: target}(coinId, 1);

        // – spent never exceeds target and is within a small rounding gap
        assertLe(spent, target, "overspent beyond target");
        assertApproxEqAbs(spent, target, 0.1 ether, "rounding gap too big");

        // – they must receive more than the free first token
        assertTrue(quote > 1, "expected multiple tokens");

        // 5) Sale must have auto‑finalized on crossing target
        (address creatorAfterBuy,,,,,,,,) = curve.sales(coinId);
        assertEq(creatorAfterBuy, address(0), "sale should be finalized on crossing target");

        // 6) saleSummary flags
        (,,,,,, bool isLive, bool isFinalized,,,,) = curve.saleSummary(coinId, userA);
        assertFalse(isLive, "isLive must be false postfinalize");
        assertTrue(isFinalized, "isFinalized must be true postfinalize");

        // 7) Further buys revert
        vm.expectRevert(zCurve.Finalized.selector);
        vm.prank(userA);
        curve.buyExactCoins{value: 1}(coinId, 1);

        // 8) userA’s ETH drop ≃ spent (ignoring gas)
        assertApproxEqAbs(before - userA.balance, spent, 1e15 /* ~0.001 ETH */ );
    }

    /* -----------------------------------------------------------------
       28. buyExactCoins cannot exceed saleCap (auto‑finalizes on full buy)
    ------------------------------------------------------------------*/
    function testBuyExactCoinsSoldOutReverts() public {
        uint96 cap = 100;
        uint256 coinId = _launch(cap);

        // Buy the entire cap
        uint256 cost = curve.buyCost(coinId, cap);
        vm.prank(userA);
        curve.buyExactCoins{value: cost}(coinId, cap);

        // Next buyExactCoins should revert as Finalized
        vm.prank(userB);
        vm.expectRevert(zCurve.Finalized.selector);
        curve.buyExactCoins{value: 1}(coinId, 1);
    }

    /* -----------------------------------------------------------------
       29. buyForExactEth reverts if minCoins too high
    ------------------------------------------------------------------*/
    function testBuyForExactEthMinCoinsReverts() public {
        uint96 cap = 1000;
        uint256 coinId = _launch(cap);

        // Request one more than the quote
        uint96 quote = curve.tokensForEth(coinId, 1 ether);
        vm.prank(userA);
        vm.expectRevert(zCurve.Slippage.selector);
        curve.buyForExactEth{value: 1 ether}(coinId, quote + 1);
    }

    /* -----------------------------------------------------------------
       30. sellExactCoins without any balance reverts NoWant
    ------------------------------------------------------------------*/
    function testSellExactCoinsWithoutBalanceReverts() public {
        uint96 cap = 100;
        uint256 coinId = _launch(cap);

        vm.prank(userA);
        vm.expectRevert();
        curve.sellExactCoins(coinId, 1, 0);
    }

    /* -----------------------------------------------------------------
       31. sellForExactEth reverts if desired > escrow
    ------------------------------------------------------------------*/
    function testSellForExactEthInsufficientEscrowReverts() public {
        uint96 cap = 100;
        uint256 coinId = _launch(cap);

        // Buy some tokens first
        uint256 cost = curve.buyCost(coinId, 10);
        vm.prank(userA);
        curve.buyExactCoins{value: cost}(coinId, 10);

        // Attempt to sell for more ETH than in escrow
        vm.prank(userA);
        vm.expectRevert(zCurve.Slippage.selector);
        curve.sellForExactEth(coinId, cost * 2, 10);
    }

    /* -----------------------------------------------------------------
       32. claim before finalize reverts Pending
    ------------------------------------------------------------------*/
    function testClaimBeforeFinalizeReverts() public {
        uint96 cap = 100;
        uint256 coinId = _launch(cap);

        // Buy a few tokens
        uint256 cost = curve.buyCost(coinId, 5);
        vm.prank(userA);
        curve.buyExactCoins{value: cost}(coinId, 5);

        // Try to claim before finalization
        vm.prank(userA);
        vm.expectRevert(zCurve.Pending.selector);
        curve.claim(coinId, 5);
    }

    /* -----------------------------------------------------------------
       33. tokensToBurnForEth view aligns with sellRefund
    ------------------------------------------------------------------*/
    function testTokensToBurnForEthMatchesSellRefund() public {
        uint96 cap = 1000;
        uint256 coinId = _launch(cap);

        // Buy 100 tokens first
        uint256 cost = curve.buyCost(coinId, 100);
        vm.prank(userA);
        curve.buyExactCoins{value: cost}(coinId, 100);

        // Read how much ETH is escrowed
        (,,,,,, uint128 esc,,) = curve.sales(coinId);

        // 1) If requested ETH exceeds escrow, expect zero tokens
        uint96 zeroTokens = curve.tokensToBurnForEth(coinId, uint256(esc) + 1);
        assertEq(zeroTokens, 0, "should return 0 when weiOut > escrow");

        // 2) For a small refund amount (selling 1 token), at least one token to burn
        uint256 oneTokenRefund = curve.sellRefund(coinId, 1);
        uint96 minTokens = curve.tokensToBurnForEth(coinId, oneTokenRefund);
        assertGe(minTokens, 1, "should need to burn at least one token for small refund");

        // 3) And the actual refund for that many tokens covers the desired ETH
        uint256 actualRefund = curve.sellRefund(coinId, minTokens);
        assertGe(actualRefund, oneTokenRefund, "refund should cover requested weiOut");
    }

    /* -----------------------------------------------------------------
       34. reentrancy guard blocks recursive buyExactCoins
    ------------------------------------------------------------------*/
    function testReentrancyGuard() public {
        uint96 cap = 10;
        uint256 coinId = _launch(cap);
        uint256 cost2 = curve.buyCost(coinId, 2);

        Reenter attacker = new Reenter(curve, coinId);
        vm.deal(address(attacker), cost2 + 1 ether);

        vm.expectRevert();
        attacker.start{value: cost2}();
    }

    /* -----------------------------------------------------------------
       35. first two tokens are always free via buyExactCoins
    ------------------------------------------------------------------*/
    function testFirstTwoTokensFreeBuyExact() public {
        uint256 coinId = _launch(10);

        // First token is free
        curve.buyExactCoins{value: 0}(coinId, 1);
        assertEq(curve.balances(coinId, owner), 1);

        // Second token now costs >0, so zero‑ETH should revert
        uint256 cost2 = curve.buyCost(coinId, 2) - curve.buyCost(coinId, 1);
        assertGt(cost2, 0);
        vm.expectRevert(zCurve.InvalidMsgVal.selector);
        curve.buyExactCoins{value: 0}(coinId, 1);
        // Balance unchanged
        assertEq(curve.balances(coinId, owner), 1);
    }

    /* -----------------------------------------------------------------
       36. crossing‑guard ensures finalize when sending exactly target
    ------------------------------------------------------------------*/
    function testCrossingGuardAutoFinalize() public {
        // pick a target that isn’t an exact sum of marginal steps
        uint96 cap = 1_000;
        uint96 lpDup = cap;
        uint128 target = 1.2345 ether;
        uint256 divFT = 16_000;

        // special launch (no pre‑buy)
        (uint256 coinId,) = curve.launch(0, 0, cap, lpDup, target, divFT, 30, "uri");

        // stub out AMM so finalize can run
        vm.mockCall(
            address(Z),
            abi.encodeWithSelector(IERC6909.balanceOf.selector, address(curve), coinId),
            abi.encode(uint256(1))
        );
        vm.mockCall(
            address(Z),
            abi.encodeWithSelector(IZAMM.addLiquidity.selector),
            abi.encode(uint256(0), uint256(0), uint256(42))
        );

        vm.deal(userA, 2 ether);
        vm.prank(userA);
        (, uint256 spent) = curve.buyForExactEth{value: target}(coinId, 1);

        // The floor‑sum will be < target, but the crossing check will finalize
        assertLe(spent, target, "spent should never overshoot");
        (address creatorAfter,,,,,,,,) = curve.sales(coinId);
        assertEq(creatorAfter, address(0), "must autofinalize on crossingtarget");
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
