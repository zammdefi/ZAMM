// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/*───────────────────────────  zCurve  ──────────────────────────*/
contract zCurve {
    /* ───────── external constants ───────── */
    IZAMM constant Z = IZAMM(0x000000000000040470635EB91b7CE4D132D616eD);

    /* ───────── launchpad constants ──────── */
    uint56 constant SALE_DURATION = 1 weeks;
    uint256 constant DEFAULT_FEE_BPS = 100;
    uint128 constant MIN_ETH_RAISE = 1 ether;
    uint256 constant MINIMUM_LIQUIDITY = 1000;

    /* ───────── storage (6 slots) ───────── */
    struct Sale {
        /* slot‑0 */
        address creator;
        uint96 divisor;
        uint56 deadline;
        /* slot‑1 */
        uint96 saleCap;
        uint96 lpSupply; // <── new explicit LP tranche
        uint128 ethEscrow;
        /* slot‑2 */
        uint128 netSold;
        uint128 ethTarget;
        /* slot‑3 */
        uint256 coinId;
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
        uint128 target,
        uint96 divisor
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

    function launchFT(
        uint96 creatorSupply,
        uint256 creatorUnlock,
        uint96 saleCap,
        uint96 lpSupply,
        string calldata uri,
        uint128 ethTargetWei,
        uint96 divisor
    ) external returns (uint256 coinId) {
        if (saleCap == 0 || lpSupply == 0 || ethTargetWei == 0 || divisor == 0) {
            revert InvalidParams();
        }

        /* total minted = creator + sale tranche + LP tranche */
        uint256 totalMint = creatorSupply + saleCap + lpSupply;
        if (totalMint > type(uint96).max) revert OverflowTotalSupply();

        coinId = Z.coin(address(this), totalMint, uri);

        /* handle creator tranche */
        if (creatorSupply != 0) {
            if (creatorUnlock > block.timestamp) {
                /* lock to creator */
                Z.lockup(address(Z), msg.sender, coinId, creatorSupply, creatorUnlock);
            } else {
                /* immediate transfer */
                Z.transfer(msg.sender, coinId, creatorSupply);
            }
        }

        /* record sale */
        Sale storage S = sales[coinId];
        S.creator = msg.sender;
        S.deadline = uint56(block.timestamp) + SALE_DURATION;
        S.saleCap = saleCap;
        S.lpSupply = lpSupply;
        S.ethTarget = ethTargetWei;
        S.divisor = divisor;
        S.coinId = coinId;

        emit Launch(msg.sender, coinId, saleCap, lpSupply, ethTargetWei, divisor);
    }

    /* =================================================================== *
                                    BUY
    * =================================================================== */
    error Finalized();
    error TooLate();
    error SoldOut();
    error InvalidMsgVal();

    function buyForExactEth(uint256 coinId, uint96 minCoins)
        external
        payable
        lock
        returns (uint128 coinsOut, uint256 ethCost)
    {
        Sale storage S = sales[coinId];
        _preLiveCheck(S);

        uint96 div = S.divisor;
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
        external
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
    function _preLiveCheck(Sale storage S) private view {
        if (S.creator == address(0)) revert Finalized();
        if (block.timestamp > S.deadline) revert TooLate();
    }

    function _mintToBuyer(Sale storage S, uint256 coinId, uint96 coins, uint256 cost) private {
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
    error InsufficientBalance();
    error InsufficientEscrow();
    error Slippage();

    function sellExactCoins(uint256 coinId, uint96 coins, uint256 minEthOut)
        external
        lock
        returns (uint256 refundWei)
    {
        refundWei = _executeSell(coinId, coins);
        if (refundWei < minEthOut) revert Slippage();
    }

    function sellForExactEth(uint256 coinId, uint256 desiredEthOut, uint96 maxCoins)
        external
        lock
        returns (uint96 tokensBurned, uint256 refundWei)
    {
        if (desiredEthOut == 0) revert InvalidMsgVal();
        Sale storage S = sales[coinId];
        if (S.creator == address(0)) revert Finalized();

        uint96 div = S.divisor;

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
    function _executeSell(uint256 coinId, uint96 coins) private returns (uint256 refund) {
        Sale storage S = sales[coinId];
        uint128 bal = balances[coinId][msg.sender];
        if (bal < coins) revert InsufficientBalance();

        refund = _cost(S.netSold, S.divisor) - _cost(S.netSold - coins, S.divisor);
        if (refund > S.ethEscrow) revert InsufficientEscrow();

        unchecked {
            balances[coinId][msg.sender] = bal - coins;
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
    error RaiseTooSmall();
    error LPBalanceMismatch();

    function finalize(uint256 coinId) external lock {
        Sale storage S = sales[coinId];
        if (S.creator == address(0)) revert Finalized();

        bool timeGate = block.timestamp >= S.deadline && S.ethEscrow >= MIN_ETH_RAISE;
        if (!timeGate && S.ethEscrow < S.ethTarget) revert Pending();

        _finalize(S, coinId);
    }

    function claim(uint256 coinId, uint128 coins) external lock {
        if (coins == 0) revert InvalidMsgVal();
        if (sales[coinId].creator != address(0)) revert Pending();

        balances[coinId][msg.sender] -= coins;
        Z.transfer(msg.sender, coinId, coins);

        emit Claim(msg.sender, coinId, coins);
    }

    /* ---------- internal finalise ---------- */
    function _finalize(Sale storage S, uint256 coinId) private {
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

    /* ------------ quadratic cost ------------ */
    function _cost(uint256 n, uint256 d) private pure returns (uint256) {
        unchecked {
            return n * (n - 1) * (2 * n - 1) * 1 ether / (6 * d);
        }
    }

    /* ---------------- view helpers ---------------- */
    function buyCost(uint256 coinId, uint96 coins) external view returns (uint256) {
        Sale storage S = sales[coinId];
        return _cost(S.netSold + coins, S.divisor) - _cost(S.netSold, S.divisor);
    }

    function sellRefund(uint256 coinId, uint96 coins) external view returns (uint256) {
        Sale storage S = sales[coinId];
        return _cost(S.netSold, S.divisor) - _cost(S.netSold - coins, S.divisor);
    }

    function tokensForEth(uint256 coinId, uint256 weiIn) external view returns (uint96) {
        Sale storage S = sales[coinId];
        uint96 div = S.divisor;

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

    function tokensToBurnForEth(uint256 coinId, uint256 weiOut) external view returns (uint96) {
        Sale storage S = sales[coinId];
        uint96 div = S.divisor;

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

/*────────────────────────  ZAMM interface  ─────────────────────────*/
interface IZAMM {
    struct PoolKey {
        uint256 id0;
        uint256 id1;
        address token0;
        address token1;
        uint256 feeOrHook;
    }

    function coin(address, uint256, string calldata) external returns (uint256);
    function transfer(address, uint256, uint256) external returns (bool);
    function lockup(address, address, uint256, uint256, uint256)
        external
        payable
        returns (bytes32);
    function deposit(address, uint256, uint256) external payable;
    function balanceOf(address, uint256) external view returns (uint256);
    function addLiquidity(PoolKey calldata, uint256, uint256, uint256, uint256, address, uint256)
        external
        payable
        returns (uint256, uint256, uint256);
}

/*──── minimal ETH helper ────*/
function safeTransferETH(address to, uint256 amt) {
    assembly {
        if iszero(call(gas(), to, amt, 0, 0, 0, 0)) {
            mstore(0, 0xb12d13eb)
            revert(28, 4)
        }
    }
}
