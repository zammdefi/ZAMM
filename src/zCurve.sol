// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

contract zCurve {
    IZAMM constant Z = IZAMM(0x000000000000040470635EB91b7CE4D132D616eD);

    /* ───────── launchpad constants ──────── */
    uint256 constant SALE_DURATION = 2 weeks;
    uint256 constant MAX_DIV = type(uint256).max / 6;

    // - hook flags
    uint256 constant FLAG_BEFORE = 1 << 255;
    uint256 constant FLAG_AFTER = 1 << 254;
    uint256 constant ADDR_MASK = (1 << 160) - 1;
    uint256 constant MAX_FEE = 10000; // 100%

    /* ───────── storage (5 packed slots) ───────── */

    struct Sale {
        address creator;
        uint96 saleCap;
        uint96 lpSupply;
        uint96 netSold;
        uint64 deadline;
        uint256 divisor;
        uint128 ethEscrow;
        uint128 ethTarget;
        uint256 feeOrHook;
    }

    mapping(uint256 => Sale) public sales;
    mapping(uint256 => mapping(address => uint96)) public balances;

    /* ───────── guard ───────── */
    // Soledge (https://github.com/Vectorized/soledge/blob/main/src/utils/ReentrancyGuard.sol)
    error Reentrancy();

    modifier lock() {
        assembly ("memory-safe") {
            if tload(0x929eee149b4bd21268) {
                mstore(0x00, 0xab143c06) // `Reentrancy()`
                revert(0x1c, 0x04)
            }
            tstore(0x929eee149b4bd21268, address())
        }
        _;
        assembly ("memory-safe") {
            tstore(0x929eee149b4bd21268, 0)
        }
    }

    /* ───────── events ───────── */

    event Launch(
        address indexed creator,
        uint256 indexed coinId,
        uint96 saleCap,
        uint96 lpSupply,
        uint128 target,
        uint256 divisor
    );
    event Buy(address indexed buyer, uint256 indexed coinId, uint256 ethIn, uint96 coinsOut);
    event Sell(address indexed seller, uint256 indexed coinId, uint96 coinsIn, uint256 ethOut);
    event Finalize(uint256 indexed coinId, uint256 ethLp, uint256 coinLp, uint256 lpMinted);
    event Claim(address indexed user, uint256 indexed coinId, uint96 amount);

    /* =================================================================== *
                                   LAUNCH
    * =================================================================== */

    error InvalidParams();
    error CurveTooCheap();
    error InvalidFeeOrHook();
    error OverflowTotalSupply();

    function launch(
        uint256 creatorSupply,
        uint256 creatorUnlock,
        uint96 saleCap,
        uint96 lpSupply,
        uint128 ethTargetWei,
        uint256 divisor,
        uint256 feeOrHook,
        string calldata uri
    ) public payable lock returns (uint256 coinId, uint96 coinsOut) {
        require(saleCap >= 5 && lpSupply != 0 && feeOrHook != 0, InvalidParams());
        require(divisor != 0 && divisor <= MAX_DIV, InvalidParams());
        require(ethTargetWei >= _cost(5, divisor), InvalidParams());

        /* allow 0 < fee < 10000 bps or a well‑formed hook */
        uint256 masked = feeOrHook & ~(FLAG_BEFORE | FLAG_AFTER);
        require(
            feeOrHook < MAX_FEE || ((masked & ~ADDR_MASK) == 0 && masked != 0), InvalidFeeOrHook()
        );

        /* total minted = creator + sale tranche + LP tranche */
        uint256 totalMint = creatorSupply + saleCap + lpSupply;
        require(totalMint <= type(uint96).max, OverflowTotalSupply());

        coinId = Z.coin(address(this), totalMint, uri);

        /* handle creator tranche */
        if (creatorSupply != 0) {
            if (creatorUnlock > block.timestamp) {
                // lock to creator
                Z.lockup(address(Z), msg.sender, coinId, creatorSupply, creatorUnlock);
            } else {
                // immediate transfer
                Z.transfer(msg.sender, coinId, creatorSupply);
            }
        }

        Sale storage S = sales[coinId];

        /* record sale */
        unchecked {
            S.creator = msg.sender;
            S.saleCap = saleCap;
            S.lpSupply = lpSupply;
            S.deadline = uint64(block.timestamp + SALE_DURATION);
            S.divisor = divisor;
            S.ethTarget = ethTargetWei;
            S.feeOrHook = feeOrHook;
        }

        emit Launch(msg.sender, coinId, saleCap, lpSupply, ethTargetWei, divisor);

        // Make sure even the FINAL token price fits into uint256:
        {
            uint256 worst = _cost(uint256(saleCap), divisor); // cost to buy *all* tokens
            // `worst` itself overflows ⇒ revert; otherwise compare to a sane upper bound.
            require(worst <= type(uint256).max / 2, CurveTooCheap()); // or change the cap
        }

        // netSold is guaranteed 0 at launch, so _cost(0, d) == 0, and
        // we can skip the subtraction and call _cost(mid, d) directly
        if (msg.value != 0) {
            uint96 lo;
            uint96 mid;
            uint96 hi = saleCap;
            uint256 cost;

            while (lo < hi) {
                mid = uint96((uint256(lo) + uint256(hi + 1)) >> 1);
                cost = _cost(mid, divisor);
                if (cost <= msg.value) lo = mid;
                else hi = mid - 1;
            }

            coinsOut = lo;
            require(coinsOut != 0, InvalidMsgVal());

            uint256 ethCost = _cost(coinsOut, divisor);
            _mintToBuyer(S, coinId, coinsOut, ethCost);

            if (msg.value > ethCost) {
                safeTransferETH(msg.sender, msg.value - ethCost);
            }
        }
    }

    /* =================================================================== *
                                    BUY
    * =================================================================== */

    error NoWant();
    error SoldOut();
    error TooLate();
    error Slippage();
    error Finalized();
    error InvalidMsgVal();

    function buyForExactEth(uint256 coinId, uint96 minCoins)
        public
        payable
        lock
        returns (uint96 coinsOut, uint256 ethCost)
    {
        require(msg.value != 0, InvalidMsgVal());
        Sale storage S = sales[coinId];
        _preLiveCheck(S);

        uint256 div = S.divisor;
        uint96 netSold = S.netSold;
        uint96 remaining = S.saleCap - netSold;

        // Shortcut: if they can afford every remaining token, skip the binary search:
        {
            uint256 fullCost = _cost(netSold + remaining, div) - _cost(netSold, div);
            if (msg.value >= fullCost) {
                require(remaining >= minCoins, Slippage());
                coinsOut = remaining;
                ethCost = fullCost;
                _mintToBuyer(S, coinId, coinsOut, ethCost);
                if (msg.value > ethCost) {
                    safeTransferETH(msg.sender, msg.value - ethCost);
                }
                return (coinsOut, ethCost);
            }
        }

        // Otherwise do a binary search over [0..remaining]
        uint96 lo;
        uint96 mid;
        uint96 hi = remaining;
        uint256 cost;

        while (lo < hi) {
            mid = uint96((uint256(lo) + uint256(hi + 1)) >> 1);
            cost = _cost(netSold + mid, div) - _cost(netSold, div);
            if (cost <= msg.value) {
                lo = mid;
            } else {
                hi = mid - 1;
            }
        }

        coinsOut = lo;
        require(coinsOut != 0 && coinsOut >= minCoins, Slippage());

        ethCost = _cost(netSold + coinsOut, div) - _cost(netSold, div);
        _mintToBuyer(S, coinId, coinsOut, ethCost);

        if (msg.value > ethCost) {
            safeTransferETH(msg.sender, msg.value - ethCost);
        }
    }

    function buyExactCoins(uint256 coinId, uint96 coinsWanted)
        public
        payable
        lock
        returns (uint256 cost)
    {
        require(coinsWanted != 0, NoWant());

        Sale storage S = sales[coinId];
        _preLiveCheck(S);

        uint96 netSold = S.netSold;

        require(S.saleCap >= netSold + coinsWanted, SoldOut());

        cost = _cost(netSold + coinsWanted, S.divisor) - _cost(netSold, S.divisor);
        require(msg.value >= cost, InvalidMsgVal());

        _mintToBuyer(S, coinId, coinsWanted, cost);
        if (msg.value > cost) safeTransferETH(msg.sender, msg.value - cost);
    }

    /* ---------- shared buy helpers ---------- */

    function _preLiveCheck(Sale storage S) internal view {
        require(S.creator != address(0), Finalized());
        require(block.timestamp <= S.deadline, TooLate());
    }

    function _mintToBuyer(Sale storage S, uint256 coinId, uint96 coins, uint256 cost) internal {
        unchecked {
            S.netSold += coins;
            S.ethEscrow += uint128(cost);
            balances[coinId][msg.sender] += coins;

            emit Buy(msg.sender, coinId, cost, coins);

            /* Compute the marginal price of the *next* token */
            uint256 nextMarginal = _cost(S.netSold + 1, S.divisor) - _cost(S.netSold, S.divisor);

            // Auto‑finalize on hitting/exceeding target, selling out, or crossing the target:
            if (
                S.ethEscrow >= S.ethTarget || S.netSold == S.saleCap
                    || S.ethEscrow + nextMarginal > S.ethTarget
            ) {
                _finalize(S, coinId);
            }
        }
    }

    /* =================================================================== *
                                    SELL
    * =================================================================== */

    error InsufficientEscrow();

    function sellExactCoins(uint256 coinId, uint96 coins, uint256 minEthOut)
        public
        lock
        returns (uint256 refundWei)
    {
        require(coins != 0, NoWant());
        Sale storage S = sales[coinId];
        require(S.creator != address(0), Finalized());

        refundWei = _executeSell(S, coinId, coins);
        require(refundWei >= minEthOut, Slippage());
    }

    function sellForExactEth(uint256 coinId, uint256 desiredEthOut, uint96 maxCoins)
        public
        lock
        returns (uint96 tokensBurned, uint256 refundWei)
    {
        require(desiredEthOut != 0, NoWant());

        Sale storage S = sales[coinId];

        uint256 div = S.divisor;
        uint96 netSold = S.netSold;

        require(S.creator != address(0), Finalized());
        require(netSold != 0, InsufficientEscrow());

        uint96 lo = 1;
        uint96 mid;
        uint96 hi = netSold;
        uint256 rf;
        while (lo < hi) {
            mid = uint96((uint256(lo) + uint256(hi)) >> 1);
            rf = _cost(netSold, div) - _cost(netSold - mid, div);
            if (rf >= desiredEthOut) hi = mid;
            else lo = mid + 1;
        }
        tokensBurned = lo;
        require(tokensBurned <= maxCoins, Slippage());

        refundWei = _executeSell(S, coinId, tokensBurned);
        require(refundWei >= desiredEthOut, Slippage());
    }

    /* ---------- core sell executor ---------- */
    function _executeSell(Sale storage S, uint256 coinId, uint96 coins)
        internal
        returns (uint256 refund)
    {
        refund = _cost(S.netSold, S.divisor) - _cost(S.netSold - coins, S.divisor);
        require(refund <= S.ethEscrow, InsufficientEscrow());

        balances[coinId][msg.sender] -= coins;
        unchecked {
            S.netSold -= coins;
            S.ethEscrow -= uint128(refund);
        }
        emit Sell(msg.sender, coinId, coins, refund);
        safeTransferETH(msg.sender, refund);
    }

    /* =================================================================== *
                                 FINALIZE
    * =================================================================== */

    error Pending();

    function finalize(uint256 coinId) public lock {
        Sale storage S = sales[coinId];
        require(S.creator != address(0), Finalized());

        require(block.timestamp > S.deadline, Pending());

        _finalize(S, coinId);
    }

    function claim(uint256 coinId, uint96 coins) public {
        require(sales[coinId].creator == address(0), Pending());

        balances[coinId][msg.sender] -= coins;
        Z.transfer(msg.sender, coinId, coins);

        emit Claim(msg.sender, coinId, coins);
    }

    /* ---------- internal finalize ---------- */
    function _finalize(Sale storage S, uint256 coinId) internal {
        uint256 ethAmt = S.ethEscrow;
        uint256 coinAmt = S.lpSupply;
        uint256 feeOrHook = S.feeOrHook;

        // If fewer than two tokens sold, nothing has a market price.
        // Burn LP tranche and return without adding liquidity:
        if (S.netSold < 2) {
            delete sales[coinId];
            emit Finalize(coinId, 0, 0, 0);
            return;
        }

        // Scale LP tranche to match spot price, even if sold out:
        {
            uint256 k = S.netSold;
            /* marginal spot price at boundary: wei per token (18‑dec) */
            uint256 p = _cost(k + 1, S.divisor) - _cost(k, S.divisor);
            uint256 scaled = ethAmt / p; // rounds down
            if (scaled < coinAmt) coinAmt = scaled;
        }

        // If LP tranche would be zero, just finalize without minting LP:
        if (coinAmt == 0) {
            delete sales[coinId];
            emit Finalize(coinId, ethAmt, 0, 0);
            return;
        }

        delete sales[coinId];

        /* deposit LP tranche and add liquidity */
        (,, uint256 lp) = Z.addLiquidity{value: ethAmt}(
            IZAMM.PoolKey({
                id0: 0,
                id1: coinId,
                token0: address(0),
                token1: address(Z),
                feeOrHook: feeOrHook
            }),
            ethAmt,
            coinAmt,
            0,
            0,
            address(this),
            block.timestamp
        );

        emit Finalize(coinId, ethAmt, coinAmt, lp);
    }

    /// @dev Quadratic bonding‑curve cost:
    ///      cost = n(n‑1)(2n‑1) · 1e18 / (6 d)
    ///      First two tokens are free (n < 2).
    ///
    /// Uses Solady’s `fullMulDivUnchecked`, which performs a full 512‑bit
    /// multiply‑divide **without** the `denominator > prod1` guard.
    /// Will only revert if `d == 0` (already forbidden at launch) or if the
    /// final cost itself cannot fit into uint256 — an economically impossible
    /// scenario for any realistic sale.
    function _cost(uint256 n, uint256 d) internal pure returns (uint256) {
        if (n < 2) return 0;
        unchecked {
            // Step‑1:  a = n · (n‑1)
            uint256 a = fullMulDivUnchecked(n, n - 1, 1);
            // Step‑2:  b = a · (2n‑1)
            uint256 b = fullMulDivUnchecked(a, 2 * n - 1, 1);
            // Step‑3:  cost = b · 1e18 / (6 d)
            return fullMulDivUnchecked(b, 1 ether, 6 * d);
        }
    }

    /* ---------------- view helpers ---------------- */

    // Price/Progress

    /// @dev All the key sale parameters and live status for UI dashboards:
    function saleSummary(uint256 coinId, address user)
        public
        view
        returns (
            address creator,
            uint96 saleCap,
            uint96 netSold,
            uint128 ethEscrow,
            uint128 ethTarget,
            uint64 deadline,
            bool isLive,
            bool isFinalized,
            uint256 currentPrice,
            uint24 percentFunded,
            uint64 timeRemaining,
            uint96 userBalance
        )
    {
        Sale storage S = sales[coinId];
        creator = S.creator;
        saleCap = S.saleCap;
        netSold = S.netSold;
        ethEscrow = S.ethEscrow;
        ethTarget = S.ethTarget;
        deadline = S.deadline;
        isFinalized = (creator == address(0));
        // live if launched, not yet finalized, before deadline, and not sold‑out/target
        isLive = !isFinalized && block.timestamp <= deadline && netSold < saleCap
            && ethEscrow < ethTarget;
        currentPrice = isLive ? _cost(netSold + 1, S.divisor) - _cost(netSold, S.divisor) : 0;
        percentFunded = ethTarget == 0 ? 0 : uint24((uint256(ethEscrow) * 10_000) / ethTarget);
        timeRemaining = block.timestamp >= deadline ? 0 : deadline - uint64(block.timestamp);
        userBalance = balances[coinId][user];
    }

    // Input/Output

    function buyCost(uint256 coinId, uint96 coins) public view returns (uint256) {
        Sale storage S = sales[coinId];
        if (S.creator == address(0)) return 0;
        return _cost(S.netSold + coins, S.divisor) - _cost(S.netSold, S.divisor);
    }

    function sellRefund(uint256 coinId, uint96 coins) public view returns (uint256) {
        Sale storage S = sales[coinId];
        uint96 netSold = S.netSold;
        if (coins > netSold) return 0;
        if (S.creator == address(0)) return 0;
        return _cost(netSold, S.divisor) - _cost(netSold - coins, S.divisor);
    }

    function tokensForEth(uint256 coinId, uint256 weiIn) public view returns (uint96) {
        Sale storage S = sales[coinId];
        if (S.creator == address(0)) return 0;
        uint256 div = S.divisor;
        uint96 netSold = S.netSold;

        uint96 lo;
        uint96 mid;
        uint96 hi = S.saleCap - netSold;
        uint256 cost;
        while (lo < hi) {
            mid = uint96((uint256(lo) + uint256(hi + 1)) >> 1);
            cost = _cost(netSold + mid, div) - _cost(netSold, div);
            if (cost <= weiIn) lo = mid;
            else hi = mid - 1;
        }
        return lo;
    }

    function tokensToBurnForEth(uint256 coinId, uint256 weiOut) public view returns (uint96) {
        Sale storage S = sales[coinId];
        uint96 netSold = S.netSold;
        if (S.creator == address(0) || netSold == 0) return 0;

        uint256 div = S.divisor;
        uint256 c0 = _cost(netSold, div);
        if (weiOut > c0) return 0;

        uint96 lo = 1;
        uint96 hi = netSold;
        while (lo < hi) {
            uint96 mid = uint96((uint256(lo) + uint256(hi)) >> 1);
            uint256 refund = c0 - _cost(netSold - mid, div);
            if (refund >= weiOut) {
                hi = mid;
            } else {
                lo = mid + 1;
            }
        }
        return lo;
    }
}

interface IZAMM {
    struct PoolKey {
        uint256 id0;
        uint256 id1;
        address token0;
        address token1;
        uint256 feeOrHook;
    }

    function addLiquidity(
        PoolKey calldata poolKey,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amount0, uint256 amount1, uint256 liquidity);

    function lockup(address token, address to, uint256 id, uint256 amount, uint256 unlockTime)
        external
        payable
        returns (bytes32 lockHash);

    function coin(address creator, uint256 supply, string calldata uri)
        external
        returns (uint256 coinId);
    function transfer(address to, uint256 id, uint256 amount) external returns (bool);
}

// Modified from Solady (https://github.com/Vectorized/solady/blob/main/src/utils/FixedPointMathLib.sol)

/// @dev Calculates `floor(x * y / d)` with full precision.
/// Behavior is undefined if `d` is zero or the final result cannot fit in 256 bits.
/// Performs the full 512 bit calculation regardless.
function fullMulDivUnchecked(uint256 x, uint256 y, uint256 d) pure returns (uint256 z) {
    /// @solidity memory-safe-assembly
    assembly {
        z := mul(x, y)
        let mm := mulmod(x, y, not(0))
        let p1 := sub(mm, add(z, lt(mm, z)))
        let t := and(d, sub(0, d))
        let r := mulmod(x, y, d)
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
    }
}

// Modified from Solady (https://github.com/Vectorized/solady/blob/main/src/utils/SafeTransferLib.sol)

error ETHTransferFailed();

function safeTransferETH(address to, uint256 amount) {
    assembly ("memory-safe") {
        if iszero(call(gas(), to, amount, codesize(), 0x00, codesize(), 0x00)) {
            mstore(0x00, 0xb12d13eb)
            revert(0x1c, 0x04)
        }
    }
}
