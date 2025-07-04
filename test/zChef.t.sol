// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {zChef} from "../src/zChef.sol";

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
            LP_TOKEN, LP_ID, INCENTIVE_TOKEN, INCENTIVE_ID, 1_000 ether, 1_000, bytes32(0)
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
            LP_TOKEN, LP_ID, INCENTIVE_TOKEN, INCENTIVE_ID, 1000 ether, 1000, bytes32(0)
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
        vm.expectRevert(zChef.InvalidAmount.selector);
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
            LP_TOKEN, LP_ID, INCENTIVE_TOKEN, INCENTIVE_ID, 1_000 ether, 1_000, bytes32(0)
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
}

/* ───────── Mini token that returns NO data ───────── */
contract StubERC20 {
    function transferFrom(address, address, uint256) external {}
    function transfer(address, uint256) external {}
}
