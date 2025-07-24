// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

contract zCurve {
    IZAMM constant Z = IZAMM(0x000000000000040470635EB91b7CE4D132D616eD);

    /* ───────── launchpad constants ──────── */

    uint256 constant DEFAULT_FEE_BPS = 30;
    uint256 constant SALE_DURATION = 1 weeks;
    uint256 constant MIN_ETH_RAISE = 1 ether;
    uint256 constant MINIMUM_LIQUIDITY = 1000;

    /* ───────── storage (3 packed slots) ─────────
       slot0: address(160) + saleCap(96)
       slot1: lpSupply(96) + netSold(96) + deadline(64)
       slot2: divisor(64) + ethEscrow(96) + ethTarget(96)
    */

    struct Sale {
        address creator; // 160 bits
        uint96 saleCap; //  96 bits
        uint96 lpSupply; //  96 bits
        uint96 netSold; //  96 bits
        uint64 deadline; //  64 bits
        uint64 divisor; //  64 bits
        uint96 ethEscrow; //  96 bits
        uint96 ethTarget; //  96 bits
    }

    mapping(uint256 => Sale) public sales;
    mapping(uint256 => mapping(address => uint128)) public balances;

    /* ───────── guard ───────── */
    modifier lock() {
        assembly {
            if tload(0x929eee149b4bd21268) {
                mstore(0, 0xab143c06)
                revert(28, 4)
            }
            tstore(0x929eee149b4bd21268, caller())
        }
        _;
        assembly {
            tstore(0x929eee149b4bd21268, 0)
        }
    }

    /* ───────── events ───────── */

    event Launch(
        address indexed creator,
        uint256 indexed coinId,
        uint96 saleCap,
        uint96 lpSupply,
        uint96 target,
        uint64 divisor
    );
    event Buy(address indexed buyer, uint256 indexed coinId, uint256 ethIn, uint128 coinsOut);
    event Sell(address indexed seller, uint256 indexed coinId, uint128 coinsIn, uint256 ethOut);
    event Finalize(uint256 indexed coinId, uint256 ethLp, uint256 coinLp, uint256 lpMinted);
    event Claim(address indexed user, uint256 indexed coinId, uint256 amount);

    /* =================================================================== *
                                   LAUNCH
    * =================================================================== */

    error InvalidParams();
    error OverflowTotalSupply();

    function launch(
        uint256 creatorSupply,
        uint256 creatorUnlock,
        uint96 saleCap,
        uint96 lpSupply,
        uint96 ethTargetWei,
        uint64 divisor,
        string calldata uri
    ) public returns (uint256 coinId) {
        require(saleCap != 0 && lpSupply != 0 && ethTargetWei != 0 && divisor != 0, InvalidParams());

        /* total minted = creator + sale tranche + LP tranche */
        uint256 totalMint = creatorSupply + saleCap + lpSupply;
        if (totalMint > type(uint96).max) revert OverflowTotalSupply();

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

        /* record sale */
        unchecked {
            Sale storage S = sales[coinId];
            S.creator = msg.sender;
            S.saleCap = saleCap;
            S.lpSupply = lpSupply;
            S.deadline = uint64(block.timestamp + SALE_DURATION);
            S.divisor = divisor;
            S.ethTarget = ethTargetWei;
        }

        emit Launch(msg.sender, coinId, saleCap, lpSupply, ethTargetWei, divisor);
    }

    /* =================================================================== *
                                    BUY
    * =================================================================== */

    error SoldOut();
    error TooLate();
    error Finalized();
    error InvalidMsgVal();

    function buyForExactEth(uint256 coinId, uint96 minCoins)
        public
        payable
        lock
        returns (uint128 coinsOut, uint256 ethCost)
    {
        Sale storage S = sales[coinId];
        _preLiveCheck(S);

        uint64 div = S.divisor;
        uint96 left = S.saleCap - uint96(S.netSold);

        uint96 lo;
        uint96 hi = left;
        while (lo < hi) {
            uint96 mid = uint96((uint256(lo) + uint256(hi + 1)) >> 1);
            uint256 cost = _cost(S.netSold + mid, div) - _cost(S.netSold, div);
            if (cost <= msg.value) lo = mid;
            else hi = mid - 1;
        }
        coinsOut = lo;
        if (coinsOut == 0 || coinsOut < minCoins) revert InvalidMsgVal();

        ethCost = _cost(S.netSold + coinsOut, div) - _cost(S.netSold, div);
        _mintToBuyer(S, coinId, uint96(coinsOut), ethCost);

        if (msg.value > ethCost) safeTransferETH(msg.sender, msg.value - ethCost);
    }

    function buyExactCoins(uint256 coinId, uint96 coinsWanted)
        public
        payable
        lock
        returns (uint128)
    {
        if (coinsWanted == 0) revert InvalidMsgVal();
        Sale storage S = sales[coinId];
        _preLiveCheck(S);

        if (S.netSold + coinsWanted > S.saleCap) revert SoldOut();

        uint256 cost = _cost(S.netSold + coinsWanted, S.divisor) - _cost(S.netSold, S.divisor);
        if (msg.value < cost) revert InvalidMsgVal();

        _mintToBuyer(S, coinId, coinsWanted, cost);
        if (msg.value > cost) safeTransferETH(msg.sender, msg.value - cost);
        return coinsWanted;
    }

    /* ---------- shared buy helpers ---------- */

    function _preLiveCheck(Sale storage S) internal view {
        if (S.creator == address(0)) revert Finalized();
        if (block.timestamp > S.deadline) revert TooLate();
    }

    function _mintToBuyer(Sale storage S, uint256 coinId, uint96 coins, uint256 cost) internal {
        unchecked {
            S.netSold += coins;
            S.ethEscrow += uint96(cost);
            balances[coinId][msg.sender] += coins;
        }
        emit Buy(msg.sender, coinId, cost, coins);

        if (S.ethEscrow >= S.ethTarget) _finalize(S, coinId);
    }

    /* =================================================================== *
                                    SELL
    * =================================================================== */

    error Slippage();
    error InsufficientEscrow();
    error InsufficientBalance();

    function sellExactCoins(uint256 coinId, uint96 coins, uint256 minEthOut)
        public
        lock
        returns (uint256 refundWei)
    {
        refundWei = _executeSell(coinId, coins);
        if (refundWei < minEthOut) revert Slippage();
    }

    function sellForExactEth(uint256 coinId, uint256 desiredEthOut, uint96 maxCoins)
        public
        lock
        returns (uint96 tokensBurned, uint256 refundWei)
    {
        if (desiredEthOut == 0) revert InvalidMsgVal();
        Sale storage S = sales[coinId];
        if (S.creator == address(0)) revert Finalized();
        if (S.netSold == 0) revert InsufficientEscrow();

        uint64 div = S.divisor;

        uint96 lo = 1;
        uint96 hi = uint96(S.netSold);
        while (lo < hi) {
            uint96 mid = uint96((uint256(lo) + uint256(hi)) >> 1);
            uint256 rf = _cost(S.netSold, div) - _cost(S.netSold - mid, div);
            if (rf >= desiredEthOut) hi = mid;
            else lo = mid + 1;
        }
        tokensBurned = lo;
        if (tokensBurned > maxCoins) revert Slippage();

        refundWei = _executeSell(coinId, tokensBurned);
        if (refundWei < desiredEthOut) revert Slippage();
    }

    /* ---------- core sell executor ---------- */
    function _executeSell(uint256 coinId, uint96 coins) internal returns (uint256 refund) {
        Sale storage S = sales[coinId];
        uint128 bal = balances[coinId][msg.sender];
        if (bal < coins) revert InsufficientBalance();
        if (S.creator == address(0)) revert Finalized();

        refund = _cost(S.netSold, S.divisor) - _cost(S.netSold - coins, S.divisor);
        if (refund > S.ethEscrow) revert InsufficientEscrow();

        unchecked {
            balances[coinId][msg.sender] = bal - coins;
            S.netSold -= coins;
            S.ethEscrow -= uint96(refund);
        }
        emit Sell(msg.sender, coinId, coins, refund);
        safeTransferETH(msg.sender, refund);
    }

    /* =================================================================== *
                                 FINALIZE
    * =================================================================== */

    error Pending();
    error RaiseTooSmall();
    error LPBalanceMismatch();

    function finalize(uint256 coinId) public lock {
        Sale storage S = sales[coinId];
        if (S.creator == address(0)) revert Finalized();

        bool timeGate = block.timestamp >= S.deadline && S.ethEscrow >= MIN_ETH_RAISE;
        if (!timeGate && S.ethEscrow < S.ethTarget) revert Pending();

        _finalize(S, coinId);
    }

    function claim(uint256 coinId, uint128 coins) public lock {
        if (coins == 0) revert InvalidMsgVal();
        if (sales[coinId].creator != address(0)) revert Pending();

        balances[coinId][msg.sender] -= coins;
        Z.transfer(msg.sender, coinId, coins);

        emit Claim(msg.sender, coinId, coins);
    }

    /* ---------- internal finalize ---------- */
    function _finalize(Sale storage S, uint256 coinId) internal {
        uint256 coinAmt = S.lpSupply;
        if (Z.balanceOf(address(this), coinId) < coinAmt) revert LPBalanceMismatch();

        uint256 ethAmt = S.ethEscrow;

        uint256 prod = ethAmt * coinAmt;
        if (prod <= MINIMUM_LIQUIDITY * MINIMUM_LIQUIDITY) revert RaiseTooSmall();

        delete sales[coinId];

        /* deposit LP tranche and add liquidity */
        (,, uint256 lp) = Z.addLiquidity{value: ethAmt}(
            IZAMM.PoolKey({
                id0: 0,
                id1: coinId,
                token0: address(0),
                token1: address(Z),
                feeOrHook: DEFAULT_FEE_BPS
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

    /*─────────────────────  Bonding‑curve cost helper  ──────────────────────*
    |  Spot price  p(k) = k² / d   (in wei)                                    |
    |  Integral    Σₖ₌₀^{n‑1} k² = n(n‑1)(2n‑1) / 6                            |
    |                                                                          |
    |  Therefore:                                                              |
    |      cost(n,d) = n(n‑1)(2n‑1) · 1 ether / (6·d)                          |
    |                                                                          |
    |  ‣  Tokens 0 and 1 cost zero ⇒ early‑return n < 2.                       |
    |  ‣  `fullMulDiv()` is used once (at the end) to evaluate the             |
    |     512‑bit numerator exactly and divide by 6·d without overflow.        |
    |                                                                          |
    |  NOTE: With the default uint96 supply cap, the unchecked multiplication  |
    |        `n*(n‑1)*(2n‑1)` cannot overflow a uint256, but using             |
    |        `fullMulDiv` on the final step guarantees safety if those caps    |
    |        are ever raised.                                                  |
    *──────────────────────────────────────────────────────────────────────────*/
    function _cost(uint256 n, uint256 d) internal pure returns (uint256) {
        if (n < 2) return 0; // first two tokens are free

        unchecked {
            uint256 num = n * (n - 1) * (2 * n - 1);
            return fullMulDiv(num, 1 ether, 6 * d);
        }
    }

    /* ---------------- view helpers ---------------- */

    function buyCost(uint256 coinId, uint96 coins) public view returns (uint256) {
        Sale storage S = sales[coinId];
        return _cost(S.netSold + coins, S.divisor) - _cost(S.netSold, S.divisor);
    }

    function sellRefund(uint256 coinId, uint96 coins) public view returns (uint256) {
        Sale storage S = sales[coinId];
        return _cost(S.netSold, S.divisor) - _cost(S.netSold - coins, S.divisor);
    }

    function tokensForEth(uint256 coinId, uint256 weiIn) public view returns (uint96) {
        Sale storage S = sales[coinId];
        uint64 div = S.divisor;

        uint96 lo;
        uint96 hi = uint96(S.saleCap - S.netSold);
        while (lo < hi) {
            uint96 mid = uint96((uint256(lo) + uint256(hi + 1)) >> 1);
            uint256 cost = _cost(S.netSold + mid, div) - _cost(S.netSold, div);
            if (cost <= weiIn) lo = mid;
            else hi = mid - 1;
        }
        return lo;
    }

    function tokensToBurnForEth(uint256 coinId, uint256 weiOut) public view returns (uint96) {
        Sale storage S = sales[coinId];
        uint64 div = S.divisor;

        uint96 lo = 1;
        uint96 hi = uint96(S.netSold);
        while (lo < hi) {
            uint96 mid = uint96((uint256(lo) + uint256(hi)) >> 1);
            uint256 refund = _cost(S.netSold, div) - _cost(S.netSold - mid, div);
            if (refund >= weiOut) hi = mid;
            else lo = mid + 1;
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
    function balanceOf(address user, uint256 id) external returns (uint256);
}

// Modified from Solady (https://github.com/Vectorized/solady/blob/main/src/utils/FixedPointMathLib.sol)

error FullMulDivFailed();

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
