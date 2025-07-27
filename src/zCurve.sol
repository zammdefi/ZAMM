// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

contract zCurve {
    IZAMM constant Z = IZAMM(0x000000000000040470635EB91b7CE4D132D616eD);

    /* ───────── launchpad constants ──────── */
    uint256 constant UNIT_SCALE = 1e12;
    uint256 constant MAX_DIV = type(uint256).max / 6;

    // - hook flags
    uint256 constant FLAG_BEFORE = 1 << 255;
    uint256 constant FLAG_AFTER = 1 << 254;
    uint256 constant ADDR_MASK = (1 << 160) - 1;
    uint256 constant MAX_FEE = 10000; // 100%

    // - lp unlock packing
    // quadCapWithFlags layout:
    // [255:160] = LP unlock timestamp (96 bits) - 0 means keep in zCurve
    // [159:96]  = unused (64 bits) - reserved for future use
    // [95:0]    = actual quadCap value (96 bits)

    uint256 constant QUADCAP_MASK = (1 << 96) - 1;
    uint256 constant LP_UNLOCK_SHIFT = 160;
    uint256 constant LP_UNLOCK_MASK = ((1 << 96) - 1) << LP_UNLOCK_SHIFT;

    /* ───────── storage (6 packed slots) ───────── */

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
        uint256 quadCap;
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

    error InvalidCap();
    error InvalidUnlock();
    error InvalidParams();
    error CurveTooCheap();
    error InvalidQuadCap();
    error InvalidLpSupply();
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
        uint256 quadCapWithFlags,
        uint56 duration,
        string calldata uri
    ) public payable lock returns (uint256 coinId, uint96 coinsOut) {
        require(saleCap >= UNIT_SCALE && saleCap % UNIT_SCALE == 0, InvalidCap());
        require(lpSupply >= UNIT_SCALE && lpSupply % UNIT_SCALE == 0, InvalidLpSupply());
        require(
            ethTargetWei != 0 && feeOrHook != 0 && duration != 0 && divisor != 0
                && divisor <= MAX_DIV,
            InvalidParams()
        );

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
                // add to internal IOU
                balances[coinId][msg.sender] += uint96(creatorSupply);
            }
        }

        (uint96 quadCap, uint96 lpUnlock) = unpackQuadCap(quadCapWithFlags);
        require(
            quadCap >= UNIT_SCALE && quadCap <= saleCap && quadCap % UNIT_SCALE == 0,
            InvalidQuadCap()
        );

        Sale storage S = sales[coinId];

        /* record sale */
        unchecked {
            S.creator = msg.sender;
            S.saleCap = saleCap;
            S.lpSupply = lpSupply;
            S.deadline = uint64(block.timestamp + duration);
            S.divisor = divisor;
            S.ethTarget = ethTargetWei;
            S.feeOrHook = feeOrHook;
            S.quadCap = quadCapWithFlags;
        }

        /* sanity check curve design */
        require(_cost(uint256(saleCap), S) <= type(uint256).max / 2, CurveTooCheap());
        /* prevent creator unlock while sale is running */
        require(creatorUnlock == 0 || creatorUnlock > S.deadline, InvalidUnlock());
        require(lpUnlock == 0 || lpUnlock > block.timestamp, InvalidUnlock());

        emit Launch(msg.sender, coinId, saleCap, lpSupply, ethTargetWei, divisor);

        // netSold is guaranteed 0 at launch, so _cost(0, d) == 0, and
        // we can skip the subtraction and call _cost(mid, d) directly
        if (msg.value != 0) {
            uint96 lo;
            uint96 mid;
            uint96 hi = saleCap;
            uint256 cost;

            while (lo < hi) {
                mid = uint96((uint256(lo) + uint256(hi + 1)) >> 1);
                cost = _cost(mid, S);
                if (cost <= msg.value) lo = mid;
                else hi = mid - 1;
            }

            coinsOut = _quantizeDown(lo);
            require(coinsOut != 0, InvalidMsgVal());

            uint256 ethCost = _cost(coinsOut, S);
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

    function buyForExactETH(uint256 coinId, uint96 minCoins)
        public
        payable
        lock
        returns (uint96 coinsOut, uint256 ethCost)
    {
        require(msg.value != 0, InvalidMsgVal());

        minCoins = _quantizeDown(minCoins);
        require(minCoins != 0, Slippage());

        Sale storage S = sales[coinId];
        _preLiveCheck(S);

        uint96 netSold = S.netSold;
        uint96 remaining = S.saleCap - netSold;

        // Shortcut: if they can afford every remaining coin, skip the binary search:
        {
            uint256 fullCost = _cost(netSold + remaining, S) - _cost(netSold, S);
            if (msg.value >= fullCost) {
                coinsOut = _quantizeDown(remaining);
                require(coinsOut >= minCoins, Slippage());
                ethCost = fullCost;
                _mintToBuyer(S, coinId, coinsOut, ethCost);
                if (msg.value > ethCost) {
                    safeTransferETH(msg.sender, msg.value - ethCost);
                }
                return (coinsOut, ethCost);
            }
        }

        // Otherwise do a binary search over [0..remaining]:
        uint96 lo;
        uint96 mid;
        uint96 hi = remaining;
        uint256 cost;

        while (lo < hi) {
            mid = uint96((uint256(lo) + uint256(hi + 1)) >> 1);
            cost = _cost(netSold + mid, S) - _cost(netSold, S);
            if (cost <= msg.value) {
                lo = mid;
            } else {
                hi = mid - 1;
            }
        }

        coinsOut = _quantizeDown(lo);
        require(coinsOut != 0 && coinsOut >= minCoins, Slippage());

        ethCost = _cost(netSold + coinsOut, S) - _cost(netSold, S);
        _mintToBuyer(S, coinId, coinsOut, ethCost);

        if (msg.value > ethCost) {
            safeTransferETH(msg.sender, msg.value - ethCost);
        }
    }

    function buyExactCoins(uint256 coinId, uint96 coinsWanted, uint256 maxETH)
        public
        payable
        lock
        returns (uint256 cost)
    {
        coinsWanted = _quantizeDown(coinsWanted);
        require(coinsWanted != 0, NoWant());

        Sale storage S = sales[coinId];
        _preLiveCheck(S);

        uint96 netSold = S.netSold;
        require(S.saleCap >= netSold + coinsWanted, SoldOut());

        cost = _cost(netSold + coinsWanted, S) - _cost(netSold, S);
        require(cost <= maxETH, Slippage());
        require(msg.value >= cost, InvalidMsgVal());

        _mintToBuyer(S, coinId, coinsWanted, cost);
        if (msg.value > cost) {
            safeTransferETH(msg.sender, msg.value - cost);
        }
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

            /* Compute the marginal price of the *next* coin */
            uint256 nextMarginal = _cost(S.netSold + UNIT_SCALE, S) - _cost(S.netSold, S);

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

    function sellExactCoins(uint256 coinId, uint96 coins, uint256 minETHOut)
        public
        lock
        returns (uint256 refundWei)
    {
        coins = _quantizeDown(coins);
        require(coins != 0, NoWant());

        Sale storage S = sales[coinId];
        require(S.creator != address(0), Finalized());

        refundWei = _executeSell(S, coinId, coins);
        require(refundWei >= minETHOut, Slippage());
    }

    function sellForExactETH(uint256 coinId, uint256 desiredETHOut, uint96 maxCoins)
        public
        lock
        returns (uint96 coinsBurned, uint256 refundWei)
    {
        require(desiredETHOut != 0, NoWant());

        maxCoins = _quantizeDown(maxCoins);
        require(maxCoins != 0, Slippage());

        Sale storage S = sales[coinId];

        uint96 netSold = S.netSold;

        require(S.creator != address(0), Finalized());
        require(netSold != 0, InsufficientEscrow());

        uint96 lo = 1;
        uint96 mid;
        uint96 hi = netSold;
        uint256 rf;
        while (lo < hi) {
            mid = uint96((uint256(lo) + uint256(hi)) >> 1);
            rf = _cost(netSold, S) - _cost(netSold - mid, S);
            if (rf >= desiredETHOut) hi = mid;
            else lo = mid + 1;
        }
        coinsBurned = _quantizeUp(lo);
        require(coinsBurned <= maxCoins, Slippage());

        refundWei = _executeSell(S, coinId, coinsBurned);
        require(refundWei >= desiredETHOut, Slippage());
    }

    /* ---------- core sell executor ---------- */
    function _executeSell(Sale storage S, uint256 coinId, uint96 coins)
        internal
        returns (uint256 refund)
    {
        refund = _cost(S.netSold, S) - _cost(S.netSold - coins, S);
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
        address creator = S.creator;
        uint64 deadline = S.deadline;

        // If fewer than two *ticks* sold, nothing has a market price.
        // Burn LP tranche and return without adding liquidity:
        if (S.netSold < 2 * UNIT_SCALE) {
            delete sales[coinId];
            emit Finalize(coinId, 0, 0, 0);
            return;
        }

        // Scale LP tranche to match spot price, even if sold out:
        {
            uint256 k = S.netSold;
            /* marginal spot price at boundary: wei per micro-coin (1e12 base units) */
            uint256 p = _cost(k + UNIT_SCALE, S) - _cost(k, S);
            /* if p == 0 we still have no real market price → burn LP and exit */
            if (p == 0) {
                delete sales[coinId];
                emit Finalize(coinId, 0, 0, 0);
                return;
            }
            uint256 ticks = ethAmt / p; // how many 1 µ‑coin quanta
            uint256 scaled = ticks * UNIT_SCALE; // convert back to base units
            if (scaled < coinAmt) coinAmt = scaled;
        }

        // If LP tranche would be zero, just finalize without minting LP:
        if (coinAmt == 0) {
            delete sales[coinId];
            emit Finalize(coinId, ethAmt, 0, 0);
            return;
        }

        (, uint96 lpUnlock) = unpackQuadCap(S.quadCap);

        // Determine LP recipient based on unlock logic:
        address lpRecipient;

        if (lpUnlock == 0) {
            /* default: LP stays in zCurve contract */
            lpRecipient = address(this);
        } else if (lpUnlock <= deadline) {
            /* special case: immediate transfer to creator */
            lpRecipient = creator;
        } else {
            /* prep LP shares for Z with specified unlock time */
            lpRecipient = address(this);
        }

        delete sales[coinId];

        IZAMM.PoolKey memory poolKey = IZAMM.PoolKey({
            id0: 0,
            id1: coinId,
            token0: address(0),
            token1: address(Z),
            feeOrHook: feeOrHook
        });

        /* deposit LP tranche and add liquidity */
        (,, uint256 lp) = Z.addLiquidity{value: ethAmt}(
            poolKey, ethAmt, coinAmt, 0, 0, lpRecipient, block.timestamp
        );

        // If LP needs to be locked in Z:
        if (lpUnlock != 0 && lpUnlock > deadline) {
            uint256 poolId = _computePoolId(poolKey);
            Z.lockup(address(Z), creator, poolId, lp, lpUnlock);
        }

        emit Finalize(coinId, ethAmt, coinAmt, lp);
    }

    function _computePoolId(IZAMM.PoolKey memory poolKey) internal pure returns (uint256 poolId) {
        assembly ("memory-safe") {
            poolId := keccak256(poolKey, 0xa0)
        }
    }

    /// @dev Quadratic‑then‑linear bonding‑curve cost, in wei.
    /// @param n  Number of base‑units (18‑dec) being bought.
    /// @param S  The Sale struct, from which we read quadCap and divisor.
    /// @return weiCost  The total wei required to buy `n` coins.
    function _cost(uint256 n, Sale storage S) internal view returns (uint256 weiCost) {
        // Convert to “tick” count (1 tick = UNIT_SCALE base‑units):
        uint256 m = n / UNIT_SCALE;
        // First tick free:
        if (m < 2) return 0;

        // How many ticks do we run pure‑quad? Up to the quadCap:
        uint256 K = (S.quadCap & QUADCAP_MASK) / UNIT_SCALE;

        // Our quadratic divisor:
        uint256 d = S.divisor;
        // We factor out the common (6*d) denominator and 1 ETH numerator:
        uint256 denom = 6 * d;
        uint256 oneETH = 1 ether;

        if (m <= K) {
            // --- PURE QUADRATIC PHASE ---
            // sum_{i=0..m-1} i^2 = m*(m-1)*(2m-1)/6
            uint256 sumSq = m * (m - 1) * (2 * m - 1) / 6;
            weiCost = (sumSq * oneETH) / denom;
        } else {
            // --- MIXED PHASE: QUAD TILL K, THEN LINEAR TAIL ---
            // 1) Quad area for first K ticks:
            //    sum_{i=0..K-1} i^2 = K*(K-1)*(2K-1)/6
            uint256 sumK = K * (K - 1) * (2 * K - 1) / 6;
            uint256 quadCost = (sumK * oneETH) / denom;

            // 2) Marginal price at tick K (for ticks K→m):
            //    p_K = cost(K+1) - cost(K) = (K^2 * 1 ETH) / (6*d)
            uint256 pK = (K * K * oneETH) / denom;

            // 3) Linear tail for the remaining (m - K) ticks:
            uint256 tailTicks = m - K;
            uint256 tailCost = pK * tailTicks;

            weiCost = quadCost + tailCost;
        }
    }

    /* ---------------- granularity ---------------- */

    error InvalidGranularity();

    /// @dev Down‑round to the nearest multiple of UNIT_SCALE (1e12 base‑units).
    function _quantizeDown(uint96 amount) internal pure returns (uint96) {
        return uint96(uint256(amount) / UNIT_SCALE * UNIT_SCALE);
    }

    /// @dev Up‑round to the nearest multiple of UNIT_SCALE, but cap at uint96::max.
    /// Used when we must not give the user *less* refund than requested.
    function _quantizeUp(uint96 amount) internal pure returns (uint96) {
        uint256 q = (uint256(amount) + UNIT_SCALE - 1) / UNIT_SCALE * UNIT_SCALE;
        require(q <= type(uint96).max, InvalidGranularity());
        return uint96(q);
    }

    /* ---------------- view helpers ---------------- */

    // Bit-packing:

    function packQuadCap(uint96 quadCap, uint96 lpUnlock) public pure returns (uint256) {
        return uint256(quadCap) | (uint256(lpUnlock) << LP_UNLOCK_SHIFT);
    }

    function unpackQuadCap(uint256 packed) public pure returns (uint96 quadCap, uint96 lpUnlock) {
        quadCap = uint96(packed & QUADCAP_MASK);
        lpUnlock = uint96((packed & LP_UNLOCK_MASK) >> LP_UNLOCK_SHIFT);
    }

    // Price/Progress:

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
            uint96 userBalance,
            uint256 feeOrHook,
            uint256 divisor,
            uint256 quadCap
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
        currentPrice = isLive ? _cost(netSold + UNIT_SCALE, S) - _cost(netSold, S) : 0;
        percentFunded = ethTarget == 0 ? 0 : uint24((uint256(ethEscrow) * 10_000) / ethTarget);
        timeRemaining = block.timestamp >= deadline ? 0 : deadline - uint64(block.timestamp);
        userBalance = balances[coinId][user];
        feeOrHook = S.feeOrHook;
        divisor = S.divisor;
        quadCap = S.quadCap;
    }

    // Input/Output:

    function buyCost(uint256 coinId, uint96 coins) public view returns (uint256) {
        coins = _quantizeDown(coins);
        if (coins == 0) return 0;
        Sale storage S = sales[coinId];
        if (S.creator == address(0)) return 0;
        return _cost(S.netSold + coins, S) - _cost(S.netSold, S);
    }

    function sellRefund(uint256 coinId, uint96 coins) public view returns (uint256) {
        Sale storage S = sales[coinId];
        uint96 netSold = S.netSold;
        coins = _quantizeDown(coins);
        if (coins == 0 || coins > netSold) return 0;
        if (S.creator == address(0)) return 0;
        return _cost(netSold, S) - _cost(netSold - coins, S);
    }

    function coinsForETH(uint256 coinId, uint256 weiIn) public view returns (uint96) {
        Sale storage S = sales[coinId];
        if (S.creator == address(0)) return 0;
        uint96 netSold = S.netSold;

        uint96 lo;
        uint96 mid;
        uint96 hi = S.saleCap - netSold;
        uint256 cost;
        while (lo < hi) {
            mid = uint96((uint256(lo) + uint256(hi + 1)) >> 1);
            cost = _cost(netSold + mid, S) - _cost(netSold, S);
            if (cost <= weiIn) lo = mid;
            else hi = mid - 1;
        }
        return _quantizeDown(lo);
    }

    function coinsToBurnForETH(uint256 coinId, uint256 weiOut) public view returns (uint96) {
        Sale storage S = sales[coinId];
        uint96 netSold = S.netSold;
        if (S.creator == address(0) || netSold == 0) return 0;

        uint256 c0 = _cost(netSold, S);
        if (weiOut > c0) return 0;

        uint96 lo = 1;
        uint96 hi = netSold;
        while (lo < hi) {
            uint96 mid = uint96((uint256(lo) + uint256(hi)) >> 1);
            uint256 refund = c0 - _cost(netSold - mid, S);
            if (refund >= weiOut) {
                hi = mid;
            } else {
                lo = mid + 1;
            }
        }
        return _quantizeUp(lo);
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
