// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

contract zCurve {
    IZAMM constant Z = IZAMM(0x000000000000040470635EB91b7CE4D132D616eD);

    /* ───────── launchpad constants ──────── */

    uint256 constant DEFAULT_FEE_BPS = 30;
    uint256 constant SALE_DURATION = 2 weeks;
    uint256 constant MAX_DIV = type(uint256).max / 6;

    /* ───────── storage (4 packed slots) ───────── */

    struct Sale {
        address creator;
        uint96 saleCap;
        uint96 lpSupply;
        uint96 netSold;
        uint64 deadline;
        uint256 divisor;
        uint128 ethEscrow;
        uint128 ethTarget;
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
    error OverflowTotalSupply();

    function launch(
        uint256 creatorSupply,
        uint256 creatorUnlock,
        uint96 saleCap,
        uint96 lpSupply,
        uint128 ethTargetWei,
        uint256 divisor,
        string calldata uri
    ) public payable lock returns (uint256 coinId, uint96 coinsOut) {
        require(divisor <= MAX_DIV, InvalidParams());
        require(saleCap != 0 && lpSupply != 0 && ethTargetWei != 0 && divisor != 0, InvalidParams());

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

        emit Launch(msg.sender, coinId, saleCap, lpSupply, ethTargetWei, divisor);
    }

    /* =================================================================== *
                                    BUY
    * =================================================================== */

    error NoWant();
    error SoldOut();
    error TooLate();
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
        uint96 lo;
        uint96 mid;
        uint96 hi = S.saleCap - S.netSold;
        uint256 cost;

        while (lo < hi) {
            mid = uint96((uint256(lo) + uint256(hi + 1)) >> 1);
            cost = _cost(S.netSold + mid, div) - _cost(S.netSold, div);
            if (cost <= msg.value) lo = mid;
            else hi = mid - 1;
        }

        coinsOut = lo;
        require(coinsOut != 0 && coinsOut >= minCoins, InvalidMsgVal());

        ethCost = _cost(S.netSold + coinsOut, div) - _cost(S.netSold, div);
        _mintToBuyer(S, coinId, coinsOut, ethCost);

        if (msg.value > ethCost) safeTransferETH(msg.sender, msg.value - ethCost);
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

        require(S.saleCap >= S.netSold + coinsWanted, SoldOut());

        cost = _cost(S.netSold + coinsWanted, S.divisor) - _cost(S.netSold, S.divisor);
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
        }
        emit Buy(msg.sender, coinId, cost, coins);

        if (S.ethEscrow >= S.ethTarget) _finalize(S, coinId);
    }

    /* =================================================================== *
                                    SELL
    * =================================================================== */

    error Slippage();
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
        require(S.creator != address(0), Finalized());
        require(S.netSold != 0, InsufficientEscrow());

        uint256 div = S.divisor;

        uint96 lo = 1;
        uint96 mid;
        uint96 hi = S.netSold;
        uint256 rf;
        while (lo < hi) {
            mid = uint96((uint256(lo) + uint256(hi)) >> 1);
            rf = _cost(S.netSold, div) - _cost(S.netSold - mid, div);
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

        // If any portion of the sale remains unsold,
        // scale LP tranche to match spot price:
        if (S.netSold != S.saleCap) {
            uint256 k = S.netSold;
            // Marginal spot price at boundary: wei per token (18-dec)
            uint256 p = _cost(k + 1, S.divisor) - _cost(k, S.divisor);
            uint256 scaled = ethAmt / p; // rounds down
            if (scaled < coinAmt) coinAmt = scaled; // cap at lpSupply
                // (If scaled >= lpSupply, we just keep full lpSupply)
        }

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

    /// @dev cost(n, d) = n(n-1)(2n-1) * 1e18 / (6 * d)
    ///      First two tokens are free (n < 2).
    function _cost(uint256 n, uint256 d) internal pure returns (uint256) {
        if (n < 2) return 0;
        unchecked {
            // 1) A = n * (n - 1)
            uint256 A = fullMulDiv(n, n - 1, 1);
            // 2) B = A * (2n - 1)
            uint256 B = fullMulDiv(A, 2 * n - 1, 1);
            // 3) Scale and divide
            return fullMulDiv(B, 1 ether, 6 * d);
        }
    }

    /* ---------------- view helpers ---------------- */

    function buyCost(uint256 coinId, uint96 coins) public view returns (uint256) {
        Sale storage S = sales[coinId];
        if (S.creator == address(0)) return 0;
        return _cost(S.netSold + coins, S.divisor) - _cost(S.netSold, S.divisor);
    }

    function sellRefund(uint256 coinId, uint96 coins) public view returns (uint256) {
        Sale storage S = sales[coinId];
        if (coins > S.netSold) return 0;
        if (S.creator == address(0)) return 0;
        return _cost(S.netSold, S.divisor) - _cost(S.netSold - coins, S.divisor);
    }

    function tokensForEth(uint256 coinId, uint256 weiIn) public view returns (uint96) {
        Sale storage S = sales[coinId];
        if (S.creator == address(0)) return 0;
        uint256 div = S.divisor;

        uint96 lo;
        uint96 mid;
        uint96 hi = S.saleCap - S.netSold;
        uint256 cost;
        while (lo < hi) {
            mid = uint96((uint256(lo) + uint256(hi + 1)) >> 1);
            cost = _cost(S.netSold + mid, div) - _cost(S.netSold, div);
            if (cost <= weiIn) lo = mid;
            else hi = mid - 1;
        }
        return lo;
    }

    function tokensToBurnForEth(uint256 coinId, uint256 weiOut) public view returns (uint96) {
        Sale storage S = sales[coinId];
        if (S.creator == address(0) || S.netSold == 0) return 0;

        uint256 div = S.divisor;
        uint256 c0 = _cost(S.netSold, div);
        if (weiOut > c0) return 0;

        uint96 lo = 1;
        uint96 hi = S.netSold;
        while (lo < hi) {
            uint96 mid = uint96((uint256(lo) + uint256(hi)) >> 1);
            uint256 refund = c0 - _cost(S.netSold - mid, div);
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
