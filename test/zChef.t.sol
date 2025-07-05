// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {PoolKey, zChef} from "../src/zChef.sol";

error TransferFailed();
error TransferFromFailed();

/// ─────────────────────────────────────────────────────────────────────────
/// Minimal interface fragments we need from the on-chain singletons
interface IERC6909Core {
    function transfer(address to, uint256 id, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 id, uint256 amount)
        external
        returns (bool);
    function setOperator(address operator, bool approved) external returns (bool);
    function balanceOf(address owner, uint256 id) external view returns (uint256);
}

contract zChefTest is Test {
    /* ───────── supplied constants ───────── */
    uint256 constant ACC_PRECISION = 1e12;

    address constant USER = 0x1C0Aa8cCD568d90d61659F060D1bFb1e6f855A20;

    address constant INCENTIVE_TOKEN = 0x0000000000009710cd229bF635c4500029651eE8;
    uint256 constant INCENTIVE_ID = 1334160193485309697971829933264346612480800613613;

    // ZAMM singleton – holds LP shares as ERC-6909
    address constant LP_TOKEN = 0x00000000000008882D72EfA6cCE4B6a40b24C860;
    uint256 constant LP_ID =
        22979666169544372205220120853398704213623237650449182409187385558845249460832;

    /* ───────── SUT ───────── */
    zChef chef;
    uint256 chefId;

    /* ====================================================================== */
    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("main"));

        chef = new zChef();

        /* 1. approve zChef as operator so it can pull tokens */
        vm.prank(USER);
        IERC6909Core(INCENTIVE_TOKEN).setOperator(address(chef), true);
        vm.prank(USER);
        IERC6909Core(LP_TOKEN).setOperator(address(chef), true);

        /* 2. create a reward stream: 1 000 tokens over 1 000 s */
        vm.prank(USER);
        chefId = chef.createStream(
            LP_TOKEN,
            LP_ID,
            INCENTIVE_TOKEN,
            INCENTIVE_ID,
            1_000 ether,
            1_000,
            bytes32(keccak256(abi.encode(1)))
        );
    }

    /* ======================================================================
       1. Deposit → accrual → partial withdraw                              */
    function testAccrualAndWithdraw() public {
        uint256 userBalBefore = IERC6909Core(INCENTIVE_TOKEN).balanceOf(USER, INCENTIVE_ID);
        uint256 userLpBalBefore = IERC6909Core(LP_TOKEN).balanceOf(USER, LP_ID);

        /* USER stakes 100 LP */
        vm.prank(USER);
        chef.deposit(chefId, 100);

        assertEq(chef.balanceOf(USER, chefId), 100);
        assertEq(IERC6909Core(LP_TOKEN).balanceOf(address(chef), LP_ID), 100);

        /* warp 500 s ⇒ expect 500 reward units pending */
        vm.warp(block.timestamp + 500);
        uint256 pending = chef.pendingReward(chefId, USER);
        assertEq(pending, 500 ether);

        /* USER withdraws 50 LP */
        vm.prank(USER);
        chef.withdraw(chefId, 50);

        /* checks */
        assertEq(
            IERC6909Core(INCENTIVE_TOKEN).balanceOf(USER, INCENTIVE_ID), 500 ether + userBalBefore
        );
        assertEq(IERC6909Core(LP_TOKEN).balanceOf(USER, LP_ID), userLpBalBefore - 50);
        assertEq(chef.balanceOf(USER, chefId), 50);
    }

    /* ======================================================================
       2. Emergency withdraw forfeits rewards                               */
    function testEmergencyWithdrawForfeitsRewards() public {
        uint256 userBalBefore = IERC6909Core(INCENTIVE_TOKEN).balanceOf(USER, INCENTIVE_ID);
        uint256 userLpBalBefore = IERC6909Core(LP_TOKEN).balanceOf(USER, LP_ID);

        vm.prank(USER);
        chef.deposit(chefId, 200);

        vm.warp(block.timestamp + 1_200); // beyond stream end

        vm.prank(USER);
        chef.emergencyWithdraw(chefId);

        assertEq(IERC6909Core(LP_TOKEN).balanceOf(USER, LP_ID), userLpBalBefore); // all LP back
        assertEq(chef.balanceOf(USER, chefId), 0); // shares burned
        assertEq(
            IERC6909Core(INCENTIVE_TOKEN).balanceOf(USER, INCENTIVE_ID),
            userBalBefore, // reward forfeited
            "no reward on emergency"
        );
    }

    /* ───────────────────────── helpers ───────────────────────── */
    function _assertApproxEq(uint256 a, uint256 b, uint256 tol) internal pure {
        assertApproxEqAbs(a, b, tol);
    }

    /* ======================================================================
    3. Two users, staggered deposits → proportional rewards               */
    address constant USER2 = address(0xB0B2);

    function testMultiUserProportionalAccrual() public {
        /* give USER2 some LP and approve chef */
        vm.startPrank(USER);
        IERC6909Core(LP_TOKEN).transfer(USER2, LP_ID, 150);
        vm.stopPrank();
        vm.prank(USER2);
        IERC6909Core(LP_TOKEN).setOperator(address(chef), true);

        /* record starting balances */
        uint256 bal1Before = IERC6909Core(INCENTIVE_TOKEN).balanceOf(USER, INCENTIVE_ID);
        uint256 bal2Before = IERC6909Core(INCENTIVE_TOKEN).balanceOf(USER2, INCENTIVE_ID);

        /* timeline:
           t0     USER  deposits 100 shares
           t+250  USER2 deposits 100 shares
           stream ends at t+1000
        */
        vm.prank(USER);
        chef.deposit(chefId, 100);

        vm.warp(block.timestamp + 250);
        vm.prank(USER2);
        chef.deposit(chefId, 100);

        vm.warp(block.timestamp + 750); // past end (t = 1000)

        /* withdraw everything */
        vm.prank(USER);
        chef.withdraw(chefId, 100);
        vm.prank(USER2);
        chef.withdraw(chefId, 100);

        /* expected rewards */
        uint256 expect1 = 625 ether; // 250 + 375
        uint256 expect2 = 375 ether;

        /* earned = new balance − starting balance */
        uint256 earned1 = IERC6909Core(INCENTIVE_TOKEN).balanceOf(USER, INCENTIVE_ID) - bal1Before;
        uint256 earned2 = IERC6909Core(INCENTIVE_TOKEN).balanceOf(USER2, INCENTIVE_ID) - bal2Before;

        assertApproxEqAbs(earned1, expect1, 1);
        assertApproxEqAbs(earned2, expect2, 1);
    }

    /* ======================================================================
       4. Deposit after stream end earns zero reward                         */
    function testLateDepositNoRewards() public {
        vm.warp(block.timestamp + 1_100); // after end
        uint256 balBefore = IERC6909Core(INCENTIVE_TOKEN).balanceOf(USER, INCENTIVE_ID);

        vm.prank(USER);
        vm.expectRevert(zChef.StreamEnded.selector);
        chef.deposit(chefId, 10);

        uint256 balAfter = IERC6909Core(INCENTIVE_TOKEN).balanceOf(USER, INCENTIVE_ID);
        assertEq(balAfter, balBefore, "late depositor should earn nothing");
    }

    /* ======================================================================
       5. Duplicate stream creation must revert                              */
    function testDuplicateStreamReverts() public {
        vm.prank(USER);
        vm.expectRevert(zChef.Exists.selector);
        chef.createStream(
            LP_TOKEN,
            LP_ID,
            INCENTIVE_TOKEN,
            INCENTIVE_ID,
            1000 ether,
            1000,
            bytes32(keccak256(abi.encode(1)))
        );
    }

    /* ======================================================================
       6. Guard checks: zero-deposit and over-withdraw                       */
    function testZeroDepositReverts() public {
        vm.prank(USER);
        vm.expectRevert(zChef.ZeroAmount.selector);
        chef.deposit(chefId, 0);
    }

    function testOverWithdrawReverts() public {
        vm.prank(USER);
        chef.deposit(chefId, 5);

        vm.prank(USER);
        vm.expectRevert();
        chef.withdraw(chefId, 10);
    }

    /* ======================================================================
    7. Harvest only, then withdraw – pays full reward                     */
    function testHarvestThenWithdraw() public {
        uint256 balBefore = IERC6909Core(INCENTIVE_TOKEN).balanceOf(USER, INCENTIVE_ID);

        /* USER stakes 100 LP at t = 0 */
        vm.prank(USER);
        chef.deposit(chefId, 100);

        /* t = 400  → harvest 40 % of stream (400 tokens) */
        vm.warp(block.timestamp + 400);
        vm.prank(USER);
        chef.harvest(chefId);

        uint256 earned = IERC6909Core(INCENTIVE_TOKEN).balanceOf(USER, INCENTIVE_ID) - balBefore;
        assertEq(earned, 400 ether, "first harvest wrong");

        /* t = 1 000  → withdraw rest (600 tokens) */
        vm.warp(block.timestamp + 600);
        vm.prank(USER);
        chef.withdraw(chefId, 100);

        uint256 totalEarned =
            IERC6909Core(INCENTIVE_TOKEN).balanceOf(USER, INCENTIVE_ID) - balBefore;
        assertEq(totalEarned, 1_000 ether, "total reward should equal stream amount");
        assertEq(chef.balanceOf(USER, chefId), 0, "shares should be burned");
    }

    /* ───────────────────────── tuple helpers ───────────────────────── */

    function _end(uint256 id) internal view returns (uint64 e) {
        (,,,,, e,,,) = chef.pools(id);
    }

    function _lastUpdate(uint256 id) internal view returns (uint64 lu) {
        (,,,,,, lu,,) = chef.pools(id);
    }

    /* ======================================================================
    8. Idle pool: end timestamp is pushed forward by idle duration         */
    function testIdleExtension() public {
        uint64 endBefore = _end(chefId);

        /* let 300 s pass with ZERO stakers */
        vm.warp(block.timestamp + 300);

        vm.prank(USER);
        chef.deposit(chefId, 10); // triggers extension

        uint64 endAfter = _end(chefId);
        assertEq(endAfter, endBefore + 300, "stream end should extend by idle time");
    }

    /* ======================================================================
    9. sweepRemainder: happy-path (no stakers)                             */
    function testSweepRemainderNoStakers() public {
        uint256 balBefore = IERC6909Core(INCENTIVE_TOKEN).balanceOf(USER, INCENTIVE_ID);

        /* past nominal end */
        vm.warp(block.timestamp + 1_100);

        vm.prank(USER);
        chef.sweepRemainder(chefId, USER);

        uint256 balAfter = IERC6909Core(INCENTIVE_TOKEN).balanceOf(USER, INCENTIVE_ID);
        assertEq(balAfter - balBefore, 1_000 ether, "creator should recover all leftovers");
        assertEq(_lastUpdate(chefId), _end(chefId), "lastUpdate must equal end after sweep");
    }

    /* ======================================================================
    10. sweepRemainder reverts while stream still active                   */
    function testSweepActiveReverts() public {
        vm.prank(USER);
        vm.expectRevert(zChef.StreamActive.selector);
        chef.sweepRemainder(chefId, USER);
    }

    /* ======================================================================
    11. sweepRemainder reverts if stake still present                      */
    function testSweepStakeRemainingReverts() public {
        vm.prank(USER);
        chef.deposit(chefId, 5);

        vm.warp(block.timestamp + 1_100); // after end but stake > 0

        vm.prank(USER);
        vm.expectRevert(zChef.StakeRemaining.selector);
        chef.sweepRemainder(chefId, USER);
    }

    /* ======================================================================
    12. sweepRemainder reverts for non-creator after end                   */
    function testSweepUnauthorizedReverts() public {
        vm.warp(block.timestamp + 1_100); // after end, zero stake

        vm.startPrank(USER2);
        vm.expectRevert(zChef.Unauthorized.selector);
        chef.sweepRemainder(chefId, USER2);
        vm.stopPrank();
    }

    /* ======================================================================
    13. Emergency withdraw during stream (forfeits accrued rewards)        */
    function testEmergencyWithdrawMidStream() public {
        /* USER stakes 50 LP */
        vm.prank(USER);
        chef.deposit(chefId, 50);

        /* accrue some rewards */
        vm.warp(block.timestamp + 200);

        uint256 balBefore = IERC6909Core(INCENTIVE_TOKEN).balanceOf(USER, INCENTIVE_ID);

        vm.prank(USER);
        chef.emergencyWithdraw(chefId);

        uint256 balAfter = IERC6909Core(INCENTIVE_TOKEN).balanceOf(USER, INCENTIVE_ID);
        assertEq(balAfter, balBefore, "rewards must be forfeited");
        assertEq(chef.balanceOf(USER, chefId), 0, "shares burned");
    }

    /* ======================================================================
    14. Guard: harvest with zero stake reverts                             */
    function testHarvestNoStakeReverts() public {
        vm.prank(USER);
        vm.expectRevert(zChef.NoStake.selector);
        chef.harvest(chefId);
    }

    /* ======================================================================
    15. Guard: sweep PrecisionOverflow & CreateStream collision            */
    function testCreateStreamCollisionReverts() public {
        // identical parameters (incl. salt) would collide with previous stream
        vm.prank(USER);
        vm.expectRevert(zChef.Exists.selector);
        chef.createStream(
            LP_TOKEN,
            LP_ID,
            INCENTIVE_TOKEN,
            INCENTIVE_ID,
            1_000 ether,
            1_000,
            bytes32(keccak256(abi.encode(1)))
        );
    }

    /* ======================================================================
    16. Full withdraw at the exact stream end                              */
    function testFullWithdrawAtEnd() public {
        uint256 balBefore = IERC6909Core(INCENTIVE_TOKEN).balanceOf(USER, INCENTIVE_ID);

        vm.prank(USER);
        chef.deposit(chefId, 100);

        vm.warp(block.timestamp + 1_000); // t == end
        vm.prank(USER);
        chef.withdraw(chefId, 100);

        uint256 earned = IERC6909Core(INCENTIVE_TOKEN).balanceOf(USER, INCENTIVE_ID) - balBefore;
        assertEq(earned, 1_000 ether, "user should receive full reward");
        assertEq(chef.balanceOf(USER, chefId), 0, "all shares burned");
        assertEq(
            IERC6909Core(LP_TOKEN).balanceOf(address(chef), LP_ID),
            0,
            "chef must hold zero LP after last withdrawal"
        );
    }

    /* ======================================================================
    17. Double sweep: first succeeds, second reverts NothingToSweep        */
    function testDoubleSweepReverts() public {
        vm.warp(block.timestamp + 1_100); // stream finished, no stake
        vm.prank(USER);
        chef.sweepRemainder(chefId, USER); // first sweep OK

        vm.prank(USER);
        vm.expectRevert(zChef.NothingToSweep.selector); // second must fail
        chef.sweepRemainder(chefId, USER);
    }

    /* ======================================================================
    18. Withdraw zero shares must revert                                   */
    function testWithdrawZeroReverts() public {
        vm.prank(USER);
        vm.expectRevert(zChef.ZeroAmount.selector);
        chef.withdraw(chefId, 0);
    }

    /* ======================================================================
    19. Harvest after stream end pays remaining rewards                    */
    function testHarvestAfterEndPaysAll() public {
        uint256 balBefore = IERC6909Core(INCENTIVE_TOKEN).balanceOf(USER, INCENTIVE_ID);

        /* USER stakes 50 LP at t = 0 */
        vm.prank(USER);
        chef.deposit(chefId, 50);

        /* Jump exactly to stream end */
        vm.warp(block.timestamp + 1_000);

        vm.prank(USER);
        chef.harvest(chefId);

        /* Entire 1 000-token stream should be paid to the sole staker */
        uint256 earned = IERC6909Core(INCENTIVE_TOKEN).balanceOf(USER, INCENTIVE_ID) - balBefore;
        assertEq(earned, 1_000 ether, "sole staker must receive all rewards");
    }

    /* ======================================================================
    20. Withdraw right after deposit (dt = 0) returns no reward            */
    function testImmediateWithdrawNoReward() public {
        uint256 balBefore = IERC6909Core(INCENTIVE_TOKEN).balanceOf(USER, INCENTIVE_ID);

        vm.prank(USER);
        chef.deposit(chefId, 25);

        /* Withdraw the same block / timestamp */
        vm.prank(USER);
        chef.withdraw(chefId, 25);

        uint256 earned = IERC6909Core(INCENTIVE_TOKEN).balanceOf(USER, INCENTIVE_ID) - balBefore;
        assertEq(earned, 0, "no reward should accrue within the same second");
        assertEq(chef.balanceOf(USER, chefId), 0, "all shares burned");
    }

    /* ======================================================================
    22. Consecutive harvests – second pays only new accrual                */
    function testConsecutiveHarvestsPayDeltaOnly() public {
        uint256 bal0 = IERC6909Core(INCENTIVE_TOKEN).balanceOf(USER, INCENTIVE_ID);

        /* USER stakes 100 LP */
        vm.prank(USER);
        chef.deposit(chefId, 100);

        /* first harvest after 300 s  → earns 300 */
        vm.warp(block.timestamp + 300);
        vm.prank(USER);
        chef.harvest(chefId);
        uint256 bal1 = IERC6909Core(INCENTIVE_TOKEN).balanceOf(USER, INCENTIVE_ID);
        assertEq(bal1 - bal0, 300 ether, "first harvest wrong");

        /* second harvest 100 s later → earns only 100 more */
        vm.warp(block.timestamp + 100);
        vm.prank(USER);
        chef.harvest(chefId);
        uint256 bal2 = IERC6909Core(INCENTIVE_TOKEN).balanceOf(USER, INCENTIVE_ID);
        assertEq(bal2 - bal1, 100 ether, "second harvest should pay delta only");

        /* immediate third harvest (dt = 0) must pay 0 */
        vm.prank(USER);
        chef.harvest(chefId);
        uint256 bal3 = IERC6909Core(INCENTIVE_TOKEN).balanceOf(USER, INCENTIVE_ID);
        assertEq(bal3, bal2, "third harvest in same second must pay zero");
    }

    /* ======================================================================
    23. Harvest after emergencyWithdraw reverts NoStake                    */
    function testHarvestAfterEmergencyWithdrawReverts() public {
        vm.prank(USER);
        chef.deposit(chefId, 20);

        vm.warp(block.timestamp + 10);
        vm.prank(USER);
        chef.emergencyWithdraw(chefId);

        vm.prank(USER);
        vm.expectRevert(zChef.NoStake.selector);
        chef.harvest(chefId);
    }

    /* ======================================================================
    24. PrecisionOverflow guard when creating a stream                     */
    function testCreateStreamPrecisionOverflow() public {
        uint256 huge = type(uint256).max / 1e12 + 1; // > max / ACC_PRECISION
        address stub = address(new StubERC20());

        vm.prank(USER);
        vm.expectRevert(zChef.PrecisionOverflow.selector);
        chef.createStream(
            LP_TOKEN,
            LP_ID,
            stub, // ← safe: returns no data → passes assembly guard
            0, // rewardId = 0  (ERC-20 path)
            huge,
            1, // duration 1 s
            bytes32(uint256(1))
        );
    }

    /* ======================================================================
    25. Deposit(0) – zero-amount guard                                 */
    function testDepositZeroAmountReverts() public {
        vm.prank(USER);
        vm.expectRevert(zChef.ZeroAmount.selector);
        chef.deposit(chefId, 0);
    }

    /* ======================================================================
       26. Zap‐deposit 1 ETH into the chef via ZAMM_0
    ====================================================================== */

    function testZapDepositETHIntoChef() public {
        // give USER some ETH
        vm.deal(USER, 1 ether);

        // build the ETH⇄LP pool key: token0 = ETH id0 = 0; token1 = incentive token / id1 = INCENTIVE_ID; 1% fee
        PoolKey memory pk = PoolKey({
            id0: 0,
            id1: INCENTIVE_ID,
            token0: address(0),
            token1: INCENTIVE_TOKEN,
            feeOrHook: 100
        });

        // do the zap: split 1 ETH, swap half for incentive token in ZAMM, mint LP, then deposit into chef
        vm.prank(USER);
        (,, uint256 liquidity) = chef.zapDeposit{value: 1 ether}(
            LP_TOKEN, // ZAMM (nohook)
            chefId,
            pk,
            /* amountOutMin */
            0,
            /* amount0Min   */
            0,
            /* amount1Min   */
            0,
            /* deadline     */
            block.timestamp + 1
        );

        // assert we actually got some LP liquidity and chef shares
        assertGt(liquidity, 0, "no liquidity minted");
        assertEq(chef.balanceOf(USER, chefId), liquidity, "chef shares != liquidity");
        // chef should now hold exactly that many LP tokens of id LP_ID
        assertEq(
            IERC6909Core(LP_TOKEN).balanceOf(address(chef), LP_ID),
            liquidity,
            "chef LP balance mismatch"
        );
    }

    /* ======================================================================
       26. Zap‐deposit 1 ETH into the chef via ZAMM_1
    ====================================================================== */

    function testZapDepositETHIntoChefDiffZamm() public {
        address LP = 0x000000000000040470635EB91b7CE4D132D616eD;
        uint256 ID = 3866052644274159259257513057556902007700018844572780589640963787229397380392;

        vm.prank(USER);
        uint256 cId =
            chef.createStream(LP, ID, INCENTIVE_TOKEN, INCENTIVE_ID, 1_000 ether, 1_000, bytes32(0));

        // give USER some ETH
        vm.deal(USER, 1 ether);

        PoolKey memory pk =
            PoolKey({id0: 0, id1: 4, token0: address(0), token1: LP, feeOrHook: 100});

        // do the zap: split 1 ETH, swap half for incentive token in ZAMM, mint LP, then deposit into chef
        vm.prank(USER);
        (,, uint256 liquidity) = chef.zapDeposit{value: 1 ether}(
            LP, // ZAMM (hook)
            cId,
            pk,
            /* amountOutMin */
            0,
            /* amount0Min   */
            0,
            /* amount1Min   */
            0,
            /* deadline     */
            block.timestamp + 1
        );

        // assert we actually got some LP liquidity and chef shares
        assertGt(liquidity, 0, "no liquidity minted");
        assertEq(chef.balanceOf(USER, cId), liquidity, "chef shares != liquidity");
        // chef should now hold exactly that many LP tokens of id LP_ID
        assertEq(
            IERC6909Core(LP).balanceOf(address(chef), ID), liquidity, "chef LP balance mismatch"
        );
    }

    /* ======================================================================
       27. zapDeposit reverts on invalid poolKey.token0
    ====================================================================== */
    function testZapDepositInvalidPoolKeyReverts() public {
        // fund USER with 1 ETH
        vm.deal(USER, 1 ether);

        // token0 must be address(0) for ETH-zap; here we set it non-zero to trigger revert
        PoolKey memory badKey =
            PoolKey({id0: 0, id1: LP_ID, token0: address(1), token1: LP_TOKEN, feeOrHook: 0});

        vm.prank(USER);
        vm.expectRevert(zChef.InvalidPoolKey.selector);
        chef.zapDeposit{value: 1 ether}(
            LP_TOKEN,
            chefId,
            badKey,
            /* amountOutMin */
            0,
            /* amount0Min   */
            0,
            /* amount1Min   */
            0,
            /* deadline     */
            block.timestamp + 1
        );
    }

    /* ======================================================================
       27. createStream with zero amount reverts ZeroAmount
    ====================================================================== */
    function testCreateStreamZeroAmountReverts() public {
        vm.prank(USER);
        vm.expectRevert(zChef.ZeroAmount.selector);
        chef.createStream(
            LP_TOKEN,
            LP_ID,
            INCENTIVE_TOKEN,
            INCENTIVE_ID,
            0, // zero amount
            1_000, // valid duration
            bytes32(0)
        );
    }

    /* ======================================================================
       28. createStream with invalid durations reverts InvalidDuration
    ====================================================================== */
    function testCreateStreamInvalidDurationReverts() public {
        // zero duration
        vm.prank(USER);
        vm.expectRevert(zChef.InvalidDuration.selector);
        chef.createStream(
            LP_TOKEN,
            LP_ID,
            INCENTIVE_TOKEN,
            INCENTIVE_ID,
            1_000 ether,
            0, // zero duration
            bytes32(0)
        );

        // above max duration (> 730 days)
        vm.prank(USER);
        vm.expectRevert(zChef.InvalidDuration.selector);
        chef.createStream(
            LP_TOKEN,
            LP_ID,
            INCENTIVE_TOKEN,
            INCENTIVE_ID,
            1_000 ether,
            731 days, // exceeds 2-year limit
            bytes32(0)
        );
    }

    /* ======================================================================
    29. Migrate from one stream to another                               */
    function testMigrateHappyPath() public {
        // ── create a second stream with SAME LP token & id ──
        vm.prank(USER);
        uint256 chefId2 = chef.createStream(
            LP_TOKEN, LP_ID, INCENTIVE_TOKEN, INCENTIVE_ID, 500 ether, 1000, bytes32("B")
        );

        // USER deposits 80 LP into stream-1
        vm.prank(USER);
        chef.deposit(chefId, 80);
        assertEq(chef.balanceOf(USER, chefId), 80);

        // warp 200 s so some rewards accrue
        vm.warp(block.timestamp + 200);

        // migrate 50 shares from stream-1 → stream-2
        vm.prank(USER);
        chef.migrate(chefId, chefId2, 50);

        // ── assertions ──
        // stream-1 balance: 80 − 50 = 30
        assertEq(chef.balanceOf(USER, chefId), 30);
        // stream-2 balance: 50
        assertEq(chef.balanceOf(USER, chefId2), 50);

        // pending in stream-1 should be zero immediately after migrate
        assertEq(chef.pendingReward(chefId, USER), 0);

        // user debt in stream-2 must equal shares × acc
        (,,,,,, /*lastUpdate*/,, uint256 acc2) = chef.pools(chefId2);
        uint256 debt2 = chef.userDebt(chefId2, USER);
        assertEq(debt2, 50 * acc2 / ACC_PRECISION, "debt mismatch after migrate");

        // LP token balances inside chef: 30 + 50 = 80
        assertEq(IERC6909Core(LP_TOKEN).balanceOf(address(chef), LP_ID), 80);
    }

    /* ======================================================================
    30. Migrate reverts on LP mismatch                                     */
    function testMigrateLPMismatchReverts() public {
        // create stream with DIFFERENT LP-ID
        uint256 wrongId = LP_ID + 1;
        vm.prank(USER);
        uint256 badStream = chef.createStream(
            LP_TOKEN, wrongId, INCENTIVE_TOKEN, INCENTIVE_ID, 100 ether, 500, bytes32("BAD")
        );

        vm.prank(USER);
        chef.deposit(chefId, 10);

        vm.prank(USER);
        vm.expectRevert(zChef.LPMismatch.selector);
        chef.migrate(chefId, badStream, 5);
    }

    /* ======================================================================
    31. Migrate reverts if destination stream ended                        */
    function testMigrateStreamEndedReverts() public {
        vm.prank(USER);
        uint256 ended = chef.createStream(
            LP_TOKEN, LP_ID, INCENTIVE_TOKEN, INCENTIVE_ID, 10 ether, 10, bytes32("END")
        );

        // let it finish
        vm.warp(block.timestamp + 20);

        vm.prank(USER);
        chef.deposit(chefId, 10);

        vm.prank(USER);
        vm.expectRevert(zChef.StreamEnded.selector);
        chef.migrate(chefId, ended, 5);
    }

    /* ======================================================================
    32. View helpers: rewardPerSharePerYear / Remaining / perYear          */
    function testViewHelpers() public {
        // USER stakes 100 LP at t = 0
        vm.prank(USER);
        chef.deposit(chefId, 100);

        // immediate call: perSharePerYear = rate * 365d / totalShares
        // pull the Pool struct and extract rewardRate (index 4)
        (,,,, uint128 rewardRate,,,,) = chef.pools(chefId);
        uint256 rate = uint256(rewardRate); // already × 1e12

        uint256 expectAnnual = rate * 365 days / 100;
        assertEq(chef.rewardPerSharePerYear(chefId), expectAnnual);

        // after 250 s
        vm.warp(block.timestamp + 250);

        uint256 remaining = chef.rewardPerShareRemaining(chefId);
        (,,,,, uint64 endTs,,,) = chef.pools(chefId);
        uint256 secsLeft = endTs - block.timestamp;
        uint256 expectRem = rate * secsLeft / 100;
        assertEq(remaining, expectRem);

        uint256 perYearUser = chef.rewardPerYear(chefId, USER);
        assertEq(perYearUser, expectAnnual * 100 / ACC_PRECISION);

        // sanity: pendingReward ≈ rate * 250 / 100
        uint256 pending = chef.pendingReward(chefId, USER);
        uint256 expectPend = rate * 250 / ACC_PRECISION; // 250 tokens (2.5e20 wei)
        assertApproxEqAbs(pending, expectPend, 1);
    }

    /* ======================================================================
    33. migrate() revert must leave destination pool state unchanged
    ====================================================================== */
    function testMigrateRevertLeavesPoolUntouched() public {
        // ── create a destination stream that WILL mismatch on LP-ID ──
        uint256 badId = LP_ID + 42;
        vm.prank(USER);
        uint256 badStream = chef.createStream(
            LP_TOKEN,
            badId, // ← different ID ⇒ mismatch
            INCENTIVE_TOKEN,
            INCENTIVE_ID,
            100 ether,
            1_000,
            bytes32("BAD")
        );

        // capture baseline state
        uint64 endBefore = _end(badStream);
        uint64 luBefore = _lastUpdate(badStream);

        // user adds a small stake to the *source* pool
        vm.prank(USER);
        chef.deposit(chefId, 10);

        // warp so _updatePool() (if it ran) would definitely change timestamps
        vm.warp(block.timestamp + 123);

        // expect revert and call migrate
        vm.prank(USER);
        vm.expectRevert(zChef.LPMismatch.selector);
        chef.migrate(chefId, badStream, 5);

        // destination pool must be byte-for-byte identical to baseline
        assertEq(_end(badStream), endBefore, "end mutated");
        assertEq(_lastUpdate(badStream), luBefore, "lastUpdate mutated");
    }

    /* ======================================================================
    34. migrate()  ==  withdraw(…) + deposit(…)  equivalence test
    ====================================================================== */
    function testMigrateEquivalenceToWithdrawDeposit() public {
        // ── second stream with SAME LP (so migrate will succeed) ──
        vm.prank(USER);
        uint256 chefId2 = chef.createStream(
            LP_TOKEN, LP_ID, INCENTIVE_TOKEN, INCENTIVE_ID, 500 ether, 1_000, bytes32("EQ")
        );

        // user stakes 120 LP into stream-1
        vm.prank(USER);
        chef.deposit(chefId, 120);

        // accrue some rewards
        vm.warp(block.timestamp + 250);

        // take a full-chain snapshot for differential run
        uint256 snap = vm.snapshot();

        /* —— PATH A : single-call migrate() —— */
        vm.prank(USER);
        chef.migrate(chefId, chefId2, 60);

        uint256 s1A = chef.balanceOf(USER, chefId);
        uint256 s2A = chef.balanceOf(USER, chefId2);
        uint256 d1A = chef.userDebt(chefId, USER);
        uint256 d2A = chef.userDebt(chefId2, USER);
        uint256 incA = IERC6909Core(INCENTIVE_TOKEN).balanceOf(USER, INCENTIVE_ID);

        // roll chain state back
        vm.revertTo(snap);

        /* —— PATH B : withdraw(60) then deposit(60) —— */
        vm.startPrank(USER);
        chef.withdraw(chefId, 60); // pays pending & returns LP
        chef.deposit(chefId2, 60); // re-stakes into second pool
        vm.stopPrank();

        uint256 s1B = chef.balanceOf(USER, chefId);
        uint256 s2B = chef.balanceOf(USER, chefId2);
        uint256 d1B = chef.userDebt(chefId, USER);
        uint256 d2B = chef.userDebt(chefId2, USER);
        uint256 incB = IERC6909Core(INCENTIVE_TOKEN).balanceOf(USER, INCENTIVE_ID);

        /* —— assert equivalence —— */
        assertEq(s1A, s1B, "shares-1 mismatch");
        assertEq(s2A, s2B, "shares-2 mismatch");
        assertEq(d1A, d1B, "debt-1 mismatch");
        assertEq(d2A, d2B, "debt-2 mismatch");
        assertEq(incA, incB, "incentive token balance mismatch");
    }

    /* ======================================================================
    35. deposit amount > uint128.max must revert Overflow
    ====================================================================== */
    function testDepositOverflowReverts() public {
        uint256 huge = uint256(type(uint128).max) + 1; // 2^128 + 1
        vm.prank(USER);
        vm.expectRevert(zChef.Overflow.selector);
        chef.deposit(chefId, huge);
    }

    /* ======================================================================
    36. createStream: reward-rate overflow must revert Overflow
           (passes PrecisionOverflow guard but fails uint128 cast)
    ====================================================================== */
    function testCreateStreamRateOverflowReverts() public {
        // amount chosen so: amount * 1e12  >  uint128.max, but amount ≤ uint256.max / 1e12
        uint256 big = uint256(type(uint128).max) / ACC_PRECISION + 1;
        address stub = address(new StubERC20()); // returns no data, fine for _transferIn

        vm.prank(USER);
        vm.expectRevert(zChef.Overflow.selector);
        chef.createStream(
            LP_TOKEN,
            LP_ID,
            stub,
            0, // rewardId = 0  (ERC-20 path)
            big,
            1, // 1-second duration triggers max rate
            bytes32("O")
        );
    }

    /* ======================================================================
    37. migrate() with identical from/to chefId must revert SamePool
    ====================================================================== */
    function testMigrateSamePoolReverts() public {
        vm.prank(USER);
        chef.deposit(chefId, 10);

        vm.prank(USER);
        vm.expectRevert(zChef.SamePool.selector);
        chef.migrate(chefId, chefId, 5);
    }

    /* ======================================================================
    38. migrate() with shares == 0 must revert ZeroAmount
    ====================================================================== */
    function testMigrateZeroAmountReverts() public {
        // set up a valid destination stream first
        vm.prank(USER);
        uint256 chefId2 = chef.createStream(
            LP_TOKEN, LP_ID, INCENTIVE_TOKEN, INCENTIVE_ID, 100 ether, 1_000, bytes32("ZZ")
        );

        vm.prank(USER);
        vm.expectRevert(zChef.ZeroAmount.selector);
        chef.migrate(chefId, chefId2, 0);
    }

    /* ======================================================================
    39. deposit that would push totalShares > uint128.max must revert Overflow
           (uses a mock ERC-6909 so transferFrom() never fails)
    ====================================================================== */
    function testDepositTotalSharesOverflow() public {
        /* ── deploy a dummy LP token that always succeeds ── */
        DummyLP lp = new DummyLP();

        /* creator approves chef */
        vm.prank(USER);
        lp.setOperator(address(chef), true);

        /* create a new stream that points at the dummy LP                      *
         * reward token can be any ERC-20/6909; we re-use INCENTIVE_TOKEN here */
        vm.prank(USER);
        uint256 dummyChef = chef.createStream(
            address(lp),
            0, // lpId
            INCENTIVE_TOKEN,
            INCENTIVE_ID,
            1 ether, // small reward, irrelevant
            1_000,
            bytes32("OVER")
        );

        /* near-max deposit succeeds */
        uint128 nearMax = type(uint128).max - 10;
        vm.prank(USER);
        chef.deposit(dummyChef, nearMax);

        /* next deposit of 11 shares would overflow uint128 */
        vm.prank(USER);
        vm.expectRevert(zChef.Overflow.selector);
        chef.deposit(dummyChef, 11);
    }

    /* ======================================================================
    40. createStream where amount * 1e12 / duration > uint128.max reverts
    ====================================================================== */
    function testCreateStreamRateCastOverflow() public {
        // pick (amount, duration) pair that passes PrecisionOverflow but
        // overflows uint128 when multiplied by ACC_PRECISION / duration.
        uint256 amount = uint256(type(uint128).max) / ACC_PRECISION + 2;
        uint64 duration = 1; // 1-second ⇒ rewardRate = amount * 1e12

        address stub = address(new StubERC20());
        vm.prank(USER);
        vm.expectRevert(zChef.Overflow.selector);
        chef.createStream(
            LP_TOKEN,
            LP_ID,
            stub,
            0, // ERC-20 path
            amount,
            duration,
            bytes32("O-CAST")
        );
    }

    /* ======================================================================
    41. emergencyWithdraw with zero stake reverts NoStake
    ====================================================================== */
    function testEmergencyWithdrawNoStakeReverts() public {
        vm.prank(USER);
        vm.expectRevert(zChef.NoStake.selector);
        chef.emergencyWithdraw(chefId);
    }

    /* ======================================================================
    42. Re-entrancy guard: LP token tries to reenter deposit(), chef blocks it
    ====================================================================== */
    function testReentrancyGuardBlocksLPCallback() public {
        /* step 1: deploy a malicious ERC-6909 LP token */
        ReentrantLP lp = new ReentrantLP(chef);

        /* step 2: user approves chef as operator */
        vm.prank(USER);
        lp.setOperator(address(chef), true);

        /* step 3: create a stream that uses the malicious LP */
        vm.prank(USER);
        uint256 badChefId = chef.createStream(
            address(lp),
            0, // lpId
            INCENTIVE_TOKEN,
            INCENTIVE_ID,
            10 ether,
            1000,
            bytes32("REENT")
        );

        /* hand the reentrant contract its chefId so it can reenter correctly */
        lp.setChefId(badChefId);

        /* step 4: user’s deposit should revert with Reentrancy() */
        vm.prank(USER);
        vm.expectRevert(zChef.Reentrancy.selector);
        chef.deposit(badChefId, 1);
    }

    /* ======================================================================
    43. Three-user timeline stress: interleaved deposits & withdrawals
         – final version with correct U2 vs U3 differential
    ====================================================================== */
    function testThreeUserStress() public {
        address U2 = address(0x2222);
        address U3 = address(0x3333);

        /* ── give LP to U2 & U3, set approvals ───────────────────────── */
        vm.startPrank(USER);
        IERC6909Core(LP_TOKEN).transfer(U2, LP_ID, 150);
        IERC6909Core(LP_TOKEN).transfer(U3, LP_ID, 150);
        vm.stopPrank();
        vm.prank(U2);
        IERC6909Core(LP_TOKEN).setOperator(address(chef), true);
        vm.prank(U3);
        IERC6909Core(LP_TOKEN).setOperator(address(chef), true);

        /* record starting reward balances */
        uint256 b1Start = IERC6909Core(INCENTIVE_TOKEN).balanceOf(USER, INCENTIVE_ID);
        uint256 b2Start = IERC6909Core(INCENTIVE_TOKEN).balanceOf(U2, INCENTIVE_ID);
        uint256 b3Start = IERC6909Core(INCENTIVE_TOKEN).balanceOf(U3, INCENTIVE_ID);

        /* ── timeline ───────────────────────────────────────────────── */
        vm.prank(USER);
        chef.deposit(chefId, 100); // t = 0  (U1)
        vm.prank(U2);
        chef.deposit(chefId, 100); // t = 0  (U2)

        vm.warp(block.timestamp + 200); // t = 200
        vm.prank(U3);
        chef.deposit(chefId, 100); // U3 joins
        vm.prank(USER);
        chef.withdraw(chefId, 40); // U1 exits 40

        vm.warp(block.timestamp + 800); // t = 1000 (end)
        vm.prank(USER);
        chef.withdraw(chefId, 60);
        vm.prank(U2);
        chef.withdraw(chefId, 100);
        vm.prank(U3);
        chef.withdraw(chefId, 100);

        /* ── earned amounts (deltas) ───────────────────────────────── */
        uint256 e1 = IERC6909Core(INCENTIVE_TOKEN).balanceOf(USER, INCENTIVE_ID) - b1Start;
        uint256 e2 = IERC6909Core(INCENTIVE_TOKEN).balanceOf(U2, INCENTIVE_ID) - b2Start;
        uint256 e3 = IERC6909Core(INCENTIVE_TOKEN).balanceOf(U3, INCENTIVE_ID) - b3Start;

        /* residue: integer-division dust left in chef */
        uint256 residue = IERC6909Core(INCENTIVE_TOKEN).balanceOf(address(chef), INCENTIVE_ID);

        /* 1) Conservation: payouts + residue == stream total (1 000 tokens) */
        assertEq(e1 + e2 + e3 + residue, 1_000 * 1 ether, "total reward mismatch");

        /* 2) Residue should be < number of stakers (≤3 wei) */
        assertLt(residue, 3, "unexpected large residue");

        /* 3) U2 earned exactly 100 tokens more than U3 (200-sec head-start) */
        uint256 diff = e2 > e3 ? e2 - e3 : e3 - e2;
        assertApproxEqAbs(diff, 100 * 1 ether, 1e12); // 1 µtoken tolerance

        /* 4) U1 earned less than both U2 and U3 */
        assertLt(e1, e3, "U1 should earn less than U3");

        /* 5) Chef now holds zero LP */
        assertEq(
            IERC6909Core(LP_TOKEN).balanceOf(address(chef), LP_ID), 0, "chef LP balance not empty"
        );
    }

    /* ======================================================================
    44. Withdraw after stream end still works and pays final rewards
    ====================================================================== */
    function testWithdrawAfterEnd() public {
        vm.prank(USER);
        chef.deposit(chefId, 42);

        vm.warp(block.timestamp + 1_050); // 50 s after end
        uint256 pending = chef.pendingReward(chefId, USER);
        assertGt(pending, 0, "should have final rewards");

        uint256 balBefore = IERC6909Core(INCENTIVE_TOKEN).balanceOf(USER, INCENTIVE_ID);
        vm.prank(USER);
        chef.withdraw(chefId, 42);
        uint256 balAfter = IERC6909Core(INCENTIVE_TOKEN).balanceOf(USER, INCENTIVE_ID);

        assertEq(balAfter - balBefore, pending, "paid exact pending");
        assertEq(chef.balanceOf(USER, chefId), 0);
    }

    /* ======================================================================
    45. Dust-rounding sweep (delta-based, no “chef == 0” assumption)
    ====================================================================== */
    function testSweepRoundingDust() public {
        /* tiny stream: 3 units over 2 s */
        vm.prank(USER);
        uint256 id = chef.createStream(
            LP_TOKEN,
            LP_ID,
            INCENTIVE_TOKEN,
            INCENTIVE_ID,
            3, // raw units (wei-denominated token)
            2, // duration
            bytes32("DUST")
        );

        /* let it finish */
        vm.warp(block.timestamp + 4);

        /* record balances before sweep */
        uint256 userBefore = IERC6909Core(INCENTIVE_TOKEN).balanceOf(USER, INCENTIVE_ID);
        uint256 chefBefore = IERC6909Core(INCENTIVE_TOKEN).balanceOf(address(chef), INCENTIVE_ID);

        /* sweep */
        vm.prank(USER);
        chef.sweepRemainder(id, USER);

        /* balances after sweep */
        uint256 userAfter = IERC6909Core(INCENTIVE_TOKEN).balanceOf(USER, INCENTIVE_ID);
        uint256 chefAfter = IERC6909Core(INCENTIVE_TOKEN).balanceOf(address(chef), INCENTIVE_ID);

        /* user gained exactly 3 units */
        assertEq(userAfter - userBefore, 3, "sweep amount incorrect");

        /* chef lost exactly 3 units */
        assertEq(chefBefore - chefAfter, 3, "chef balance delta incorrect");
    }

    /* ======================================================================
    46. Same-block harvest + migrate behaves correctly
    ====================================================================== */
    function testHarvestThenMigrateSameBlock() public {
        vm.prank(USER);
        chef.deposit(chefId, 70);
        vm.warp(block.timestamp + 400);
        // create second stream
        vm.prank(USER);
        uint256 cid2 = chef.createStream(
            LP_TOKEN, LP_ID, INCENTIVE_TOKEN, INCENTIVE_ID, 200 ether, 600, bytes32("HM")
        );

        // single transaction block: harvest then migrate
        vm.startPrank(USER);
        chef.harvest(chefId);
        chef.migrate(chefId, cid2, 30); // move part
        vm.stopPrank();

        // Accounting invariants
        assertEq(chef.balanceOf(USER, chefId), 40);
        assertEq(chef.balanceOf(USER, cid2), 30);
        // debts must equal shares*acc
        uint256 d1 = chef.userDebt(chefId, USER);
        uint256 d2 = chef.userDebt(cid2, USER);
        (,,,,,,,, uint256 acc1) = chef.pools(chefId);
        (,,,,,,,, uint256 acc2) = chef.pools(cid2);
        assertEq(d1, 40 * acc1 / ACC_PRECISION);
        assertEq(d2, 30 * acc2 / ACC_PRECISION);
    }

    /* ======================================================================
    47. Invariant fuzz: totalShares and userDebt invariant
         (quick, 100 random actions, no external oracle)
    ====================================================================== */
    function testInvariantQuickFuzz() public {
        uint256 actions = 100;
        for (uint256 i; i < actions; ++i) {
            uint8 choice = uint8(uint256(keccak256(abi.encodePacked(i, block.number))) % 4);
            if (choice == 0) {
                // deposit
                uint256 amt = 1 + (i % 5);
                vm.prank(USER);
                chef.deposit(chefId, amt);
            } else if (choice == 1) {
                // withdraw
                uint256 bal = chef.balanceOf(USER, chefId);
                if (bal > 0) {
                    uint256 amt = 1 + (i % bal);
                    vm.prank(USER);
                    chef.withdraw(chefId, amt);
                }
            } else if (choice == 2) {
                // harvest
                if (chef.balanceOf(USER, chefId) > 0) {
                    vm.prank(USER);
                    chef.harvest(chefId);
                }
            } else {
                // time warp
                vm.warp(block.timestamp + 5 + (i % 20));
            }
        }

        // Invariant: pool.totalShares == user's balanceOf after fuzz run
        (,,,,,,, uint128 totalShares,) = chef.pools(chefId);
        assertEq(totalShares, uint128(chef.balanceOf(USER, chefId)), "totalShares mismatch");
    }

    /* ======================================================================
    48. Migrate 100 % of user’s stake – source pool ends at zero
    ====================================================================== */
    function testMigrateFullStake() public {
        // destination stream with same LP
        vm.prank(USER);
        uint256 dst = chef.createStream(
            LP_TOKEN, LP_ID, INCENTIVE_TOKEN, INCENTIVE_ID, 200 ether, 1_000, bytes32("FULL")
        );

        vm.prank(USER);
        chef.deposit(chefId, 30);

        // migrate ALL shares
        vm.prank(USER);
        chef.migrate(chefId, dst, 30);

        assertEq(chef.balanceOf(USER, chefId), 0, "source balance not zero");
        assertEq(chef.balanceOf(USER, dst), 30, "dest balance wrong");
    }

    /* ======================================================================
    49. Migrate near destination end:
      – succeed at end-1, revert after end (StreamEnded)
    ====================================================================== */
    function testMigrateNearEnd() public {
        /* 1.  destination stream (10-second duration) */
        vm.prank(USER);
        uint256 dst = chef.createStream(
            LP_TOKEN,
            LP_ID,
            INCENTIVE_TOKEN,
            INCENTIVE_ID,
            20 ether, // reward
            10, // duration 10 s
            bytes32("NEAR")
        );

        /* seed the destination with 1 share so totalShares>0
       (prevents idle-extension during later migrate) */
        vm.prank(USER);
        chef.deposit(dst, 1);

        /* 2.  source stake */
        vm.prank(USER);
        chef.deposit(chefId, 5);

        /* 3.  warp to just BEFORE dst.end */
        vm.warp(_end(dst) - 1);

        /* first migrate should SUCCEED */
        vm.prank(USER);
        chef.migrate(chefId, dst, 2);

        /* 4.  warp 2 s → now PAST end */
        vm.warp(_end(dst) + 1);

        /* second migrate should REVERT with StreamEnded */
        vm.prank(USER);
        vm.expectRevert(zChef.StreamEnded.selector);
        chef.migrate(chefId, dst, 1);
    }

    /* ======================================================================
    50. harvest → migrate → harvest again in same block (second harvest zero)
    ====================================================================== */
    function testHarvestMigrateHarvestZero() public {
        vm.prank(USER);
        uint256 dst = chef.createStream(
            LP_TOKEN, LP_ID, INCENTIVE_TOKEN, INCENTIVE_ID, 300 ether, 600, bytes32("HMH")
        );

        vm.prank(USER);
        chef.deposit(chefId, 50);

        vm.warp(block.timestamp + 200);

        vm.startPrank(USER);
        chef.harvest(chefId); // first harvest pays rewards
        chef.migrate(chefId, dst, 20); // move part of stake
        chef.harvest(chefId); // should be zero
        vm.stopPrank();

        assertEq(chef.pendingReward(chefId, USER), 0, "pending should be zero");
    }

    /* ======================================================================
    51. Two users migrate concurrently – totalShares stays consistent
    ====================================================================== */
    function testConcurrentMigrateTotals() public {
        address U2 = address(0xBEEF);
        vm.prank(U2);
        IERC6909Core(LP_TOKEN).setOperator(address(chef), true);
        vm.startPrank(USER);
        IERC6909Core(LP_TOKEN).transfer(U2, LP_ID, 50);
        vm.stopPrank();

        vm.prank(USER);
        chef.deposit(chefId, 40);
        vm.prank(U2);
        chef.deposit(chefId, 50);

        vm.warp(block.timestamp + 100);

        // destination stream
        vm.prank(USER);
        uint256 dst = chef.createStream(
            LP_TOKEN, LP_ID, INCENTIVE_TOKEN, INCENTIVE_ID, 400 ether, 1_000, bytes32("TOT")
        );

        // both migrate
        vm.prank(USER);
        chef.migrate(chefId, dst, 40);
        vm.prank(U2);
        chef.migrate(chefId, dst, 50);

        // invariant: pool.totalShares == sum(balanceOf)
        (,,,,,,, uint128 totalShares,) = chef.pools(dst);
        uint256 sum = chef.balanceOf(USER, dst) + chef.balanceOf(U2, dst);
        assertEq(totalShares, sum, "totalShares invariant broken");
    }

    /* ======================================================================
    52. Migrate AFTER source stream ended into new active stream
    ====================================================================== */
    function testMigrateFromEndedStream() public {
        /* USER stakes 30 into the original stream */
        vm.prank(USER);
        chef.deposit(chefId, 30);

        /* warp past source end */
        vm.warp(_end(chefId) + 5);

        uint256 pending = chef.pendingReward(chefId, USER);
        assertGt(pending, 0);

        /* ── create DESTINATION stream first ──
       (this transferFrom reduces user's balance, so balance snapshot
        must be taken *after* creation)                                   */
        vm.prank(USER);
        uint256 dst = chef.createStream(
            LP_TOKEN, LP_ID, INCENTIVE_TOKEN, INCENTIVE_ID, 200 ether, 1_000, bytes32("POST-END")
        );

        /* record balance AFTER paying for new stream */
        uint256 balBefore = IERC6909Core(INCENTIVE_TOKEN).balanceOf(USER, INCENTIVE_ID);

        /* migrate all 30 shares */
        vm.prank(USER);
        chef.migrate(chefId, dst, 30);

        /* ── assertions ───────────────────────────────────── */

        /* 1) source zero, dst 30 */
        assertEq(chef.balanceOf(USER, chefId), 0);
        assertEq(chef.balanceOf(USER, dst), 30);

        /* 2) user received exactly the pending amount */
        uint256 balAfter = IERC6909Core(INCENTIVE_TOKEN).balanceOf(USER, INCENTIVE_ID);
        assertEq(balAfter - balBefore, pending, "migrate did not pay pending");

        /* 3) debt formula in destination */
        (,,,,,,,, uint256 accDst) = chef.pools(dst);
        uint256 debt = chef.userDebt(dst, USER);
        assertEq(debt, 30 * accDst / ACC_PRECISION);

        /* 4) totalShares invariant */
        (,,,,,,, uint128 total,) = chef.pools(dst);
        assertEq(total, 30);
    }

    /* ======================================================================
    53. ERC-20 reward: transferFrom returns false ⇒ TransferFromFailed (createStream)
    ====================================================================== */
    function testERC20RewardTransferFail() public {
        BadERC20 bad = new BadERC20();

        vm.prank(USER);
        vm.expectRevert(TransferFromFailed.selector); // creation should revert
        chef.createStream(
            LP_TOKEN,
            LP_ID,
            address(bad),
            0, // ERC-20 path
            1_000, // small amount
            100,
            bytes32("BAD20")
        );
    }

    /* ======================================================================
    54. Re-entrancy via LP.transfer() during withdraw ⇒ Reentrancy guard
    ====================================================================== */
    function testWithdrawReentrancyGuard() public {
        ReentrantTransferLP lp = new ReentrantTransferLP(chef);
        vm.prank(USER);
        lp.setOperator(address(chef), true);

        vm.prank(USER);
        uint256 cid = chef.createStream(
            address(lp), 0, INCENTIVE_TOKEN, INCENTIVE_ID, 10 ether, 1000, bytes32("RET")
        );

        vm.prank(USER);
        chef.deposit(cid, 10);
        lp.set(cid); // arm re-entrant id

        vm.prank(USER);
        vm.expectRevert(zChef.Reentrancy.selector);
        chef.withdraw(cid, 5); // re-entrancy triggers, guard reverts
    }

    /* ======================================================================
    55. Operator revoked after deposit – withdraw should still succeed
    ====================================================================== */
    function testWithdrawAfterOperatorRevoked() public {
        vm.prank(USER);
        chef.deposit(chefId, 7);

        // USER revokes chef as operator for LP_TOKEN
        vm.prank(USER);
        IERC6909Core(LP_TOKEN).setOperator(address(chef), false);

        uint256 balBefore = IERC6909Core(LP_TOKEN).balanceOf(USER, LP_ID);

        vm.prank(USER);
        chef.withdraw(chefId, 7);

        uint256 balAfter = IERC6909Core(LP_TOKEN).balanceOf(USER, LP_ID);

        assertEq(balAfter - balBefore, 7, "LP not returned");
    }

    /* ======================================================================
    56. Migrate into totally idle destination ⇒ end timestamp extended
    ====================================================================== */
    function testMigrateIntoIdlePoolExtendsEnd() public {
        // create idle destination (never staked)
        vm.prank(USER);
        uint256 dst = chef.createStream(
            LP_TOKEN, LP_ID, INCENTIVE_TOKEN, INCENTIVE_ID, 50 ether, 1000, bytes32("IDLE")
        );
        uint64 endBefore = _end(dst);

        // stake in source and warp 300 s (idle for dst)
        vm.prank(USER);
        chef.deposit(chefId, 5);
        vm.warp(block.timestamp + 300);

        vm.prank(USER);
        chef.migrate(chefId, dst, 5); // first ever stake into dst

        uint64 endAfter = _end(dst);
        assertEq(endAfter, endBefore + 300, "idle extension incorrect");
    }

    /* ======================================================================
    57. Long idle (≈ 600 days) – end extends without Overflow
       Uses duration = 700 days (≤ 730-day cap)
    ====================================================================== */
    function testVeryLongIdleNoOverflow() public {
        uint64 durDays = 700;
        uint64 idleDays = 600; // big idle, still < durDays
        uint64 durSecs = durDays * 1 days; // 700 d  ≈ 60 480 000 s
        uint64 idleSecs = idleDays * 1 days; // 600 d  ≈ 51 840 000 s

        /* create long stream */
        vm.prank(USER);
        uint256 cid = chef.createStream(
            LP_TOKEN, LP_ID, INCENTIVE_TOKEN, INCENTIVE_ID, 10 ether, durSecs, bytes32("LONGIDLE")
        );

        uint64 endBefore = _end(cid);

        /* warp by 600 days (no stakers ⇒ idle)  */
        vm.warp(block.timestamp + idleSecs);

        /* first deposit triggers idle-extension */
        vm.prank(USER);
        chef.deposit(cid, 1);

        uint64 endAfter = _end(cid);
        assertEq(endAfter, endBefore + idleSecs, "idle extension incorrect");
    }

    /* ======================================================================
    58. LP that returns no data – withdraw reverts (any reason accepted)
    ====================================================================== */
    function testVoidReturnLPReverts() public {
        VoidReturnLP lp = new VoidReturnLP();
        vm.prank(USER);
        lp.setOperator(address(chef), true);

        vm.prank(USER);
        uint256 cid = chef.createStream(
            address(lp), 0, INCENTIVE_TOKEN, INCENTIVE_ID, 5 ether, 1_000, bytes32("VOID")
        );

        vm.prank(USER);
        chef.deposit(cid, 3);

        vm.prank(USER);
        vm.expectRevert(); // accept any revert data
        chef.withdraw(cid, 3);
    }

    /* ======================================================================
    59. Dust ≤ #stakers for 20-user fuzz (conservation bound)
    ====================================================================== */
    function testDustUpperBoundManyStakers() public {
        uint256 N = 20;
        address[] memory users = new address[](N);

        // distribute 1 LP to each new user and approve chef
        for (uint256 i; i < N; ++i) {
            address u = address(uint160(i + 0xAAA0));
            users[i] = u;
            vm.startPrank(USER);
            IERC6909Core(LP_TOKEN).transfer(u, LP_ID, 1);
            vm.stopPrank();
            vm.prank(u);
            IERC6909Core(LP_TOKEN).setOperator(address(chef), true);
            vm.prank(u);
            chef.deposit(chefId, 1);
        }

        // warp to end, all withdraw
        vm.warp(_end(chefId));
        for (uint256 i; i < N; ++i) {
            vm.prank(users[i]);
            chef.withdraw(chefId, 1);
        }

        // dust left in chef must be < N
        uint256 dust = IERC6909Core(INCENTIVE_TOKEN).balanceOf(address(chef), INCENTIVE_ID);
        assertLt(dust, N, "dust exceeds #stakers");
    }

    /* ======================================================================
    60. Operator revoked then re-granted – second deposit succeeds
    ====================================================================== */
    function testOperatorRevokedThenGrantedAgain() public {
        // first approval & deposit
        vm.prank(USER);
        IERC6909Core(LP_TOKEN).setOperator(address(chef), true);
        vm.prank(USER);
        chef.deposit(chefId, 2);

        // revoke operator
        vm.prank(USER);
        IERC6909Core(LP_TOKEN).setOperator(address(chef), false);

        // expect revert when trying to deposit
        vm.prank(USER);
        vm.expectRevert(); // raw revert from LP.transferFrom
        chef.deposit(chefId, 1);

        // grant again – deposit succeeds
        vm.prank(USER);
        IERC6909Core(LP_TOKEN).setOperator(address(chef), true);
        vm.prank(USER);
        chef.deposit(chefId, 1);

        assertEq(chef.balanceOf(USER, chefId), 3);
    }

    /* ======================================================================
    61. ERC-20 happy-path stream (rewardId == 0) exercises _transferOut
    ====================================================================== */
    function testERC20RewardHappyPath() public {
        // Use StubERC20 that always returns true
        StubERC20 stub = new StubERC20();

        // Give USER huge balance so transferFrom passes
        (bool ok,) = address(stub).call(
            abi.encodeWithSignature("transfer(address,uint256)", USER, 1_000 ether)
        );
        assert(ok);

        vm.prank(USER);
        stub.transfer(address(this), 0); // silence linter (no-op)

        // approve chef via fake operator pattern: safeTransferFrom handles ERC-20
        vm.prank(USER);
        stub.transfer(address(chef), 0); // any call ok (no revert / no return)

        // create stream
        vm.prank(USER);
        uint256 cid = chef.createStream(
            LP_TOKEN,
            LP_ID,
            address(stub),
            0, // rewardId == 0 (ERC-20 path)
            100 ether,
            100,
            bytes32("20OK")
        );

        vm.prank(USER);
        chef.deposit(cid, 10);
        vm.warp(block.timestamp + 50);
        vm.prank(USER);
        chef.harvest(cid); // should not revert
    }

    /* ======================================================================
    62. rewardPerSharePerYear() == 0 before any deposits
    ====================================================================== */
    function testRewardPerSharePerYearZeroNoStake() public view {
        // freshly created stream has 0 shares
        uint256 rpy = chef.rewardPerSharePerYear(chefId);
        assertEq(rpy, 0, "per-share APR should be zero when no shares");
    }

    /* ======================================================================
    63. pendingReward() immediately after deposit is zero
    ====================================================================== */
    function testPendingImmediatelyAfterDeposit() public {
        vm.prank(USER);
        chef.deposit(chefId, 42);

        uint256 pend = chef.pendingReward(chefId, USER);
        assertEq(pend, 0, "pending should be zero in same second");
    }

    /* ======================================================================
    64. sweepRemainder amount exact after 50 % streamed
     – warp **past** end by 1 s
    ====================================================================== */
    function testSweepAmountExact() public {
        // stake so that rewards stream starts accruing
        vm.prank(USER);
        chef.deposit(chefId, 10);

        // warp 500 s (half of 1 000 s stream)
        vm.warp(block.timestamp + 500);

        // withdraw all shares; pool now has totalShares = 0
        vm.prank(USER);
        chef.withdraw(chefId, 10);

        // warp **one second past** nominal end
        uint64 endTs = _end(chefId);
        vm.warp(uint256(endTs) + 1);

        // sweep
        uint256 balBefore = IERC6909Core(INCENTIVE_TOKEN).balanceOf(USER, INCENTIVE_ID);

        vm.prank(USER);
        chef.sweepRemainder(chefId, USER);

        uint256 balAfter = IERC6909Core(INCENTIVE_TOKEN).balanceOf(USER, INCENTIVE_ID);

        // exactly half (500 ether) should be swept
        assertEq(balAfter - balBefore, 500 ether, "sweep amount wrong");
    }

    /* ======================================================================
    65. rewardPerShareRemaining == 0 once stream ended
    ====================================================================== */
    function testRemainingZeroAfterEnd() public {
        vm.warp(block.timestamp + 1_001); // 1 s past end (duration = 1 000)
        uint256 rem = chef.rewardPerShareRemaining(chefId);
        assertEq(rem, 0, "remaining should be zero after end");
    }

    /* ======================================================================
    66. createStream with different salt yields a *new* chefId (no Exists)
    ====================================================================== */
    function testCreateStreamDifferentSaltSucceeds() public {
        vm.prank(USER);
        uint256 newId = chef.createStream(
            LP_TOKEN, LP_ID, INCENTIVE_TOKEN, INCENTIVE_ID, 10 ether, 500, bytes32("DIFFERENT_SALT")
        );

        // ensure it's distinct from the original one produced in setUp()
        assertTrue(newId != chefId, "chefId collision with different salt");
    }

    /* ======================================================================
    67. ERC-6909 reward: transferFrom returns false ⇒ TransferFromFailed
    ====================================================================== */
    function testERC6909RewardTransferFail() public {
        Bad6909 bad = new Bad6909();
        vm.prank(USER);
        bad.setOperator(address(chef), true);

        vm.prank(USER);
        vm.expectRevert(TransferFromFailed.selector);
        chef.createStream(
            LP_TOKEN,
            LP_ID,
            address(bad), // rewardToken (ERC-6909)
            42, // rewardId ≠ 0  → 6909 path
            5, // amount
            100, // duration
            bytes32("BAD6909")
        );
    }

    /* ======================================================================
    68. withdraw(): reward 6909.transfer returns false ⇒ TransferFailed
    ====================================================================== */
    function testWithdrawRewardTransferFail() public {
        BadPay6909 bad = new BadPay6909();
        vm.prank(USER);
        bad.setOperator(address(chef), true);

        // create stream that pays BadPay6909 rewards
        vm.prank(USER);
        uint256 cid = chef.createStream(
            LP_TOKEN,
            LP_ID,
            address(bad), // rewardToken
            7, // rewardId
            10, // amount
            1_000, // duration
            bytes32("BADPAY")
        );

        // stake a share
        vm.prank(USER);
        chef.deposit(cid, 1);

        // let some reward accrue so pending > 0
        vm.warp(block.timestamp + 100);

        // make reward transfer fail
        bad.setFail();

        vm.prank(USER);
        vm.expectRevert(TransferFailed.selector);
        chef.withdraw(cid, 1);
    }

    /* ======================================================================
    69. migrate() with shares > user balance must revert (over-migrate)
    ====================================================================== */
    function testMigrateOverBalanceReverts() public {
        /* create a second, compatible stream (same LP / ID) */
        vm.prank(USER);
        uint256 chefId2 = chef.createStream(
            LP_TOKEN, LP_ID, INCENTIVE_TOKEN, INCENTIVE_ID, 50 ether, 1_000, bytes32("OVERMIG")
        );

        /* user deposits 10 shares into the first stream */
        vm.prank(USER);
        chef.deposit(chefId, 10);

        /* attempt to migrate 20 (more than the user owns) – should revert */
        vm.prank(USER);
        vm.expectRevert(); // arithmetic under-flow inside _burn()
        chef.migrate(chefId, chefId2, 20);
    }

    /* ======================================================================
    70. withdraw(uint256).full   – withdrawing exactly current balance
    ====================================================================== */
    function testWithdrawFullBalance() public {
        vm.prank(USER);
        chef.deposit(chefId, 7);

        // warp a little so some reward accrues
        vm.warp(block.timestamp + 42);

        uint256 shares = chef.balanceOf(USER, chefId);

        uint256 beforeLP = IERC6909Core(LP_TOKEN).balanceOf(USER, LP_ID);
        uint256 beforeRw = IERC6909Core(INCENTIVE_TOKEN).balanceOf(USER, INCENTIVE_ID);

        vm.prank(USER);
        chef.withdraw(chefId, shares);

        assertEq(chef.balanceOf(USER, chefId), 0);
        assertEq(
            IERC6909Core(LP_TOKEN).balanceOf(USER, LP_ID), beforeLP + shares, "LP not returned 1:1"
        );
        assertGt(
            IERC6909Core(INCENTIVE_TOKEN).balanceOf(USER, INCENTIVE_ID),
            beforeRw,
            "reward was not paid"
        );
    }

    /* ======================================================================
    71. Idle-after-withdraw then re-enter – end timestamp slides forward
    ====================================================================== */
    function testIdleAfterWithdrawThenReturn() public {
        // USER stakes 50 at t0
        vm.prank(USER);
        chef.deposit(chefId, 50);

        uint64 end0 = _end(chefId);

        // warp 100 s → some rewards accrue
        vm.warp(block.timestamp + 100);

        // USER fully withdraws → supply becomes 0
        vm.prank(USER);
        chef.withdraw(chefId, 50);
        assertEq(chef.balanceOf(USER, chefId), 0);

        // pool now idle for 250 s
        vm.warp(block.timestamp + 250);

        // USER (or anyone) stakes again – triggers _updatePool idle branch
        vm.prank(USER);
        chef.deposit(chefId, 10);

        uint64 end1 = _end(chefId);
        assertEq(end1, end0 + 250, "end did not slide by idle duration");

        // sanity: pending for new stake is 0 right after deposit
        assertEq(chef.pendingReward(chefId, USER), 0);
    }

    // WIP

    function testSameBlockDoubleDeposit() public {
        // Give USER2 LP and approvals.
        vm.prank(USER);
        IERC6909Core(LP_TOKEN).transfer(USER2, LP_ID, 100);
        vm.prank(USER2);
        IERC6909Core(LP_TOKEN).setOperator(address(chef), true);

        // Snapshot balances before.
        uint256 bal1Before = IERC6909Core(INCENTIVE_TOKEN).balanceOf(USER, INCENTIVE_ID);
        uint256 bal2Before = IERC6909Core(INCENTIVE_TOKEN).balanceOf(USER2, INCENTIVE_ID);

        /* ――― SAME BLOCK ――― */
        vm.startPrank(USER);
        chef.deposit(chefId, 100);
        vm.stopPrank();

        vm.prank(USER2);
        chef.deposit(chefId, 100);
        /* ―――            ――― */

        // Warp 100 s → total drip = 100 tokens.
        vm.warp(block.timestamp + 100);

        vm.prank(USER);
        chef.withdraw(chefId, 100);
        vm.prank(USER2);
        chef.withdraw(chefId, 100);

        uint256 earned1 = IERC6909Core(INCENTIVE_TOKEN).balanceOf(USER, INCENTIVE_ID) - bal1Before;
        uint256 earned2 = IERC6909Core(INCENTIVE_TOKEN).balanceOf(USER2, INCENTIVE_ID) - bal2Before;

        // Each should have earned exactly 50 tokens.
        assertEq(earned1, 50 ether);
        assertEq(earned2, 50 ether);
    }

    function testCrossMigrationInvariant() public {
        address ALICE = USER;
        address BOB = address(0xB0B3);

        // ── second stream (chefB) ──
        vm.prank(ALICE); // ✅ ALICE owns the tokens
        uint256 chefB = chef.createStream(
            LP_TOKEN, LP_ID, INCENTIVE_TOKEN, INCENTIVE_ID, 500 ether, 1_000, bytes32(uint256(0x42))
        );

        // give BOB LP and approve
        vm.startPrank(ALICE);
        IERC6909Core(LP_TOKEN).transfer(BOB, LP_ID, 120);
        vm.stopPrank();
        vm.prank(BOB);
        IERC6909Core(LP_TOKEN).setOperator(address(chef), true);

        // initial deposits
        vm.prank(ALICE);
        chef.deposit(chefId, 80);
        vm.prank(BOB);
        chef.deposit(chefB, 120);

        vm.warp(block.timestamp + 200);

        uint128 totBefore = _shares(chefId) + _shares(chefB);

        // cross-migrations
        vm.prank(ALICE);
        chef.migrate(chefId, chefB, 50); // ALICE: 50 → chefB

        vm.prank(BOB);
        chef.migrate(chefB, chefId, 60); // BOB:   60 → chefId

        uint128 totAfter = _shares(chefId) + _shares(chefB);
        assertEq(totAfter, totBefore, "share conservation failed");

        // debt sanity
        assertEq(chef.userDebt(chefB, ALICE), 50 * _acc(chefB) / ACC_PRECISION, "Alice debt");
        assertEq(chef.userDebt(chefId, BOB), 60 * _acc(chefId) / ACC_PRECISION, "Bob debt");

        // balances
        assertEq(chef.balanceOf(ALICE, chefId), 30);
        assertEq(chef.balanceOf(ALICE, chefB), 50);
        assertEq(chef.balanceOf(BOB, chefId), 60);
        assertEq(chef.balanceOf(BOB, chefB), 60);
    }

    /* ─── tiny field helpers ─── */
    function _shares(uint256 id) internal view returns (uint128 ts) {
        (,,,,,,, ts,) = chef.pools(id);
    }

    function _acc(uint256 id) internal view returns (uint256 acc) {
        (,,,,,,,, acc) = chef.pools(id);
    }
}

/* ───────── Mini token that returns NO data ───────── */
contract StubERC20 {
    function transfer(address, uint256) external {}
    function transferFrom(address, address, uint256) external {}
}

/* Bad reward ERC-20 that always returns false */
contract BadERC20 {
    mapping(address => uint256) public balanceOf;

    constructor() {
        balanceOf[msg.sender] = type(uint256).max;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return false;
    }
}

/* LP whose `transfer` reenters */
contract ReentrantTransferLP is IERC6909Core {
    zChef private immutable chef;
    uint256 private id;

    constructor(zChef c) {
        chef = c;
    }

    function set(uint256 _id) external {
        id = _id;
    }

    function setOperator(address, bool) external pure returns (bool) {
        return true;
    }

    function balanceOf(address, uint256) external pure returns (uint256) {
        return 1e18;
    }

    function transfer(address, uint256, uint256) external returns (bool) {
        if (id != 0) {
            uint256 t = id;
            id = 0;
            chef.withdraw(t, 1);
        }
        return true;
    }

    function transferFrom(address, address, uint256, uint256) external pure returns (bool) {
        return true;
    }
}

/* LP that returns no data at all */
contract VoidReturnLP {
    mapping(address => bool) public op;

    function setOperator(address o, bool a) external returns (bool) {
        op[o] = a;
        return true;
    }

    function transfer(address, uint256, uint256) external pure {}

    function transferFrom(address, address, uint256, uint256) external view returns (bool) {
        require(op[msg.sender], "not op");
        return true;
    }

    function balanceOf(address, uint256) external pure returns (uint256) {
        return type(uint256).max;
    }
}

/* ────────────────────────────────────────────────────────────────────────── */
/* Helper: a minimal ERC-6909 token that reenters chef.deposit() in transferFrom */
contract ReentrantLP is IERC6909Core {
    zChef public immutable chef;
    uint256 public chefId;

    constructor(zChef _chef) {
        chef = _chef;
    }

    /* allow test to inject the correct chefId after the stream is created */
    function setChefId(uint256 id) external {
        chefId = id;
    }

    /* IERC6909Core -- only the four functions actually called in tests */
    function setOperator(address, bool) external pure returns (bool) {
        return true;
    }

    function balanceOf(address, uint256) external pure returns (uint256) {
        return type(uint256).max;
    }

    function transfer(address, uint256, uint256) external pure returns (bool) {
        return true;
    }

    function transferFrom(address, address, uint256, uint256) external returns (bool) {
        // first call reenters chef.deposit(); the reentrancy guard will revert
        if (chefId != 0) {
            uint256 id = chefId;
            chefId = 0; // ensure one-shot to avoid infinite loop
            chef.deposit(id, 1);
        }
        return true;
    }
}

/* ────────────────────────────────────────────────────────────────────────── */
/* Simple ERC-6909 stub: all transfers succeed, no balance bookkeeping       */
contract DummyLP is IERC6909Core {
    mapping(address => bool) public isOperator;

    /* IERC6909Core stubs */
    function setOperator(address operator, bool approved) external returns (bool) {
        isOperator[operator] = approved;
        return true;
    }

    function transfer(address, uint256, uint256) external pure returns (bool) {
        return true;
    }

    function transferFrom(address, address, uint256, uint256) external view returns (bool) {
        require(isOperator[msg.sender], "not operator");
        return true;
    }

    function balanceOf(address, uint256) external pure returns (uint256) {
        return type(uint256).max;
    }
}

contract Bad6909 is IERC6909Core {
    function transfer(address, uint256, uint256) external pure returns (bool) {
        return true;
    }

    function transferFrom(address, address, uint256, uint256) external pure returns (bool) {
        return false; // force failure on createStream
    }

    function setOperator(address, bool) external pure returns (bool) {
        return true;
    }

    function balanceOf(address, uint256) external pure returns (uint256) {
        return 0;
    }
}

contract BadPay6909 is IERC6909Core {
    bool public ok = true;

    function setFail() external {
        ok = false;
    } // flip to false before withdraw

    function transfer(address, uint256, uint256) external view returns (bool) {
        return ok;
    }

    function transferFrom(address, address, uint256, uint256) external pure returns (bool) {
        return true; // succeed on deposit
    }

    function setOperator(address, bool) external pure returns (bool) {
        return true;
    }

    function balanceOf(address, uint256) external pure returns (uint256) {
        return type(uint256).max; // unlimited balance
    }
}
