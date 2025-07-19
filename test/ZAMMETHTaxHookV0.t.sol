// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";

// alias the two PoolKey structs so they don’t collide:
import {ZAMM} from "../src/ZAMM.sol";
import {ZAMMETHTaxHookV0, PoolKey as HookKey} from "../hooks/ZAMMETHTaxHookV0.sol";

/// @notice Minimal ERC‑20 for tests
contract MockERC20 {
    string public name = "Mock";
    string public symbol = "MCK";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        require(allowance[from][msg.sender] >= amt, "ERC20: allowance");
        allowance[from][msg.sender] -= amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "ERC20: balance");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @notice Unit tests for ZAMMETHTaxHookV0
contract ZAMMETHTaxHookV0Test is Test {
    ZAMM constant zamm = ZAMM(payable(0x000000000000040470635EB91b7CE4D132D616eD));

    MockERC20 public token1;
    ZAMMETHTaxHookV0 public hook;

    /// @dev Arbitrary receiver for ETH taxes
    address public constant RECEIVER = address(0x1234);
    /// @dev 5% tax
    uint96 public constant TAX_RATE = 500;
    /// @dev Flag for "before" hook in ZAMM
    uint256 constant FLAG_BEFORE = 1 << 255;

    function setUp() public {
        // 1) fork mainnet and point at the real ZAMM singleton
        vm.createSelectFork(vm.rpcUrl("main"));

        // 2) deploy & seed a mock ERC20
        token1 = new MockERC20();
        token1.mint(address(this), 1_000 ether);

        // 3) deploy your hook
        hook = new ZAMMETHTaxHookV0(address(token1), RECEIVER, TAX_RATE);

        // 4) approve both hook and ZAMM to pull tokens
        token1.approve(address(hook), type(uint256).max);
        token1.approve(address(zamm), type(uint256).max);

        // 5) fund your hook so it can refund ETH
        vm.deal(address(hook), 10 ether);

        // 6) compute feeOrHook
        uint256 feeOrHook = FLAG_BEFORE | uint256(uint160(address(hook)));

        // 7) fund your test contract and add liquidity under the hook
        vm.deal(address(this), 10 ether);
        token1.mint(address(this), 10 ether);

        zamm.addLiquidity{value: 10 ether}(
            ZAMM.PoolKey({
                id0: 0,
                id1: 0,
                token0: address(0),
                token1: address(token1),
                feeOrHook: feeOrHook
            }),
            10 ether, // amount0Desired
            10 ether, // amount1Desired
            0, // amount0Min
            0, // amount1Min
            address(this),
            block.timestamp
        );
    }

    /// ETH → token exact‑in (msg.value taxed, net→pool)
    function testSwapExactInEthToToken() public {
        uint256 gross = 1 ether;
        uint256 beforeR = RECEIVER.balance;
        vm.deal(address(this), gross);

        uint256 out = hook.swapExactIn{value: gross}(
            HookKey({
                id0: 0,
                id1: 0,
                token0: address(0),
                token1: address(token1),
                feeOrHook: FLAG_BEFORE | uint256(uint160(address(hook)))
            }),
            0, // ignored for ETH→token
            0, // amountOutMin
            true, // ETH→token
            address(this),
            block.timestamp + 1
        );

        uint256 expectTax = (gross * TAX_RATE) / 10_000;
        assertEq(RECEIVER.balance - beforeR, expectTax, "tax paid");
        assertGt(out, 0, "got tokens");
    }

    /// token → ETH exact‑in (pull tokens, tax on ETH output)
    function testSwapExactInTokenToEth() public {
        uint256 amountIn = 1 ether;
        token1.mint(address(this), amountIn);
        token1.approve(address(hook), amountIn);

        uint256 beforeR = RECEIVER.balance;
        uint256 beforeU = address(this).balance;

        uint256 got = hook.swapExactIn(
            HookKey({
                id0: 0,
                id1: 0,
                token0: address(0),
                token1: address(token1),
                feeOrHook: FLAG_BEFORE | uint256(uint160(address(hook)))
            }),
            amountIn,
            0,
            false,
            address(this),
            block.timestamp + 1
        );

        uint256 expectTax = (got * TAX_RATE) / 10_000;
        assertEq(RECEIVER.balance - beforeR, expectTax, "tax on ETH out");
        assertEq(address(this).balance - beforeU, got - expectTax, "net ETH");
    }

    /// ETH → token exact‑out (pay ≤ msg.value, refund remainder)
    function testSwapExactOutEthToToken() public {
        uint256 desiredTokens = 1 ether;
        uint256 grossMax = 2 ether;
        vm.deal(address(this), grossMax);
        uint256 beforeR = RECEIVER.balance;

        uint256 netIn = hook.swapExactOut{value: grossMax}(
            HookKey({
                id0: 0,
                id1: 0,
                token0: address(0),
                token1: address(token1),
                feeOrHook: FLAG_BEFORE | uint256(uint160(address(hook)))
            }),
            desiredTokens,
            grossMax,
            true,
            address(this),
            block.timestamp + 1
        );

        uint256 actualTax = (netIn * TAX_RATE) / 10_000;
        assertGe(grossMax, netIn + actualTax, "within budget");
        assertEq(RECEIVER.balance - beforeR, actualTax, "tax sent");
    }

    function testSwapExactOutTokenToEth() public {
        uint256 desiredEth = 1 ether; // net ETH the user wants
        uint256 maxTokens = 2 ether; // max tokens willing to spend
        token1.mint(address(this), maxTokens);
        token1.approve(address(hook), maxTokens);

        uint256 beforeR = RECEIVER.balance;
        uint256 beforeU = address(this).balance;

        uint256 used = hook.swapExactOut(
            HookKey({
                id0: 0,
                id1: 0,
                token0: address(0),
                token1: address(token1),
                feeOrHook: FLAG_BEFORE | uint256(uint160(address(hook)))
            }),
            desiredEth,
            maxTokens,
            false,
            address(this),
            block.timestamp + 1
        );

        // tax is now computed on the *gross* ETH pulled from the pool
        uint256 grossOut = (desiredEth * 10_000 + (10_000 - TAX_RATE) - 1) / (10_000 - TAX_RATE); // ceil‑div
        uint256 expectTax = grossOut - desiredEth; // exact tax

        assertEq(RECEIVER.balance - beforeR, expectTax, "tax ETH");
        assertEq(address(this).balance - beforeU, desiredEth, "net ETH");
        assertTrue(used <= maxTokens, "token <= max");
    }

    function testZeroTax_NoFee() public {
        // Temporarily set the hook’s taxRate to 0
        vm.prank(RECEIVER);
        hook.setTaxRate(0);

        uint256 feeOrHook = FLAG_BEFORE | uint256(uint160(address(hook)));
        uint256 gross = 1 ether;
        vm.deal(address(this), gross);

        uint256 out = hook.swapExactIn{value: gross}(
            HookKey({
                id0: 0,
                id1: 0,
                token0: address(0),
                token1: address(token1),
                feeOrHook: feeOrHook
            }),
            0,
            0,
            true,
            address(this),
            block.timestamp + 1
        );

        // No ETH tax should be collected
        assertEq(RECEIVER.balance, 0, "no tax collected");
        assertGt(out, 0, "swap succeeded");
    }

    function testHighTax_AlmostFull() public {
        // Temporarily set the hook’s taxRate to 9999
        vm.prank(RECEIVER);
        hook.setTaxRate(9999);

        uint256 feeOrHook = FLAG_BEFORE | uint256(uint160(address(hook)));
        uint256 gross = 1 ether;
        vm.deal(address(this), gross);

        uint256 out = hook.swapExactIn{value: gross}(
            HookKey({
                id0: 0,
                id1: 0,
                token0: address(0),
                token1: address(token1),
                feeOrHook: feeOrHook
            }),
            0,
            0,
            true,
            address(this),
            block.timestamp + 1
        );

        uint256 paid = RECEIVER.balance;
        assertEq(paid, gross * 9999 / 10000, "almost full tax paid");
        assertGt(out, 0, "net > 0");
    }

    function testSwapExactIn_InvalidPoolKeyRevert() public {
        vm.deal(address(this), 1 ether); // ← fund so we can send 1 ETH
        uint256 feeOrHook = FLAG_BEFORE | uint256(uint160(address(hook)));

        vm.expectRevert(ZAMMETHTaxHookV0.InvalidPoolKey.selector);
        hook.swapExactIn{value: 1 ether}(
            HookKey({
                id0: 1, // invalid id0
                id1: 0,
                token0: address(1),
                token1: address(token1),
                feeOrHook: feeOrHook
            }),
            0,
            0,
            true,
            address(this),
            block.timestamp + 1
        );
    }

    function testSwapExactIn_TokenToEth_InvalidMsgVal() public {
        token1.mint(address(this), 1 ether);
        token1.approve(address(hook), 1 ether);
        vm.deal(address(this), 1 ether);

        vm.expectRevert(ZAMMETHTaxHookV0.InvalidMsgVal.selector);
        hook.swapExactIn{value: 1 ether}(
            HookKey({
                id0: 0,
                id1: 0,
                token0: address(0),
                token1: address(token1),
                feeOrHook: FLAG_BEFORE | uint256(uint160(address(hook)))
            }),
            1 ether,
            0,
            false,
            address(this),
            block.timestamp + 1
        );
    }

    function testSwapExactOut_EthToToken_Expired() public {
        vm.deal(address(this), 1 ether);
        vm.warp(block.timestamp + 100);

        vm.expectRevert(ZAMM.Expired.selector);
        hook.swapExactOut{value: 1 ether}(
            HookKey({
                id0: 0,
                id1: 0,
                token0: address(0),
                token1: address(token1),
                feeOrHook: FLAG_BEFORE | uint256(uint160(address(hook)))
            }),
            1,
            1,
            true,
            address(this),
            block.timestamp - 1
        );
    }

    function testSetReceiver_Unauthorized() public {
        vm.expectRevert(ZAMMETHTaxHookV0.Unauthorized.selector);
        hook.setReceiver(address(0xdead));
    }

    function testSetTaxRate_RevertOutOfBounds() public {
        vm.prank(RECEIVER);
        vm.expectRevert(ZAMMETHTaxHookV0.InvalidTaxRate.selector);
        hook.setTaxRate(10_000);
    }

    // 8) Tiny swap (< dust) always reverts InsufficientOutputAmount()
    // 8) Tiny swap (< dust) should revert InsufficientOutputAmount
    function testTinySwap_RevertForDustInput() public {
        uint256 tiny = 1 wei;
        uint256 feeOrHook = FLAG_BEFORE | uint256(uint160(address(hook)));

        // fund the test
        vm.deal(address(this), tiny);

        // calling with 1 wei into a 10 ETH/10 token pool (1% swap fee) yields zero output,
        // so the pool reverts InsufficientOutputAmount
        vm.expectRevert(ZAMM.InsufficientOutputAmount.selector);
        hook.swapExactIn{value: tiny}(
            HookKey({
                id0: 0,
                id1: 0,
                token0: address(0),
                token1: address(token1),
                feeOrHook: feeOrHook
            }),
            0, // ignored for ETH→token
            0, // amountOutMin
            true, // ETH→token
            address(this),
            block.timestamp + 1
        );
    }

    receive() external payable {}
}
