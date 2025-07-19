// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

address constant ZAMM = 0x000000000000040470635EB91b7CE4D132D616eD;

/// @notice Demo ZAMM ETH tax hook.
/// @dev 0.3% LP swap fee hard-coded.
/// ERC20 pools also favored for demo.
contract ZAMMETHTaxHookV0 {
    address public receiver;
    uint96 public taxRate;

    address public immutable token1;

    error InvalidTaxRate();
    error InvalidToken1();

    constructor(address _token1, address _receiver, uint96 _taxRate) payable {
        require(_token1 != address(0), InvalidToken1());
        require(_taxRate < 10_000, InvalidTaxRate());
        _ensureAllowance(_token1);
        receiver = _receiver;
        taxRate = _taxRate;
        token1 = _token1;
    }

    error InvalidPoolKey();
    error InvalidMsgVal();

    function swapExactIn(
        PoolKey calldata poolKey,
        uint256 amountIn, // *token‑in* net amount; ignored for ETH‑in
        uint256 amountOutMin,
        bool zeroForOne, // true = ETH→token ; false = token→ETH
        address to,
        uint256 deadline
    ) public payable lock returns (uint256 amountOut) {
        // Pool sanity
        require(poolKey.token0 == address(0) && poolKey.id0 == 0, InvalidPoolKey());
        require(poolKey.token1 == token1 && poolKey.id1 == 0, InvalidPoolKey());
        _verifyHook(poolKey);

        uint256 bps = taxRate;

        if (zeroForOne) {
            /* ── ETH → token ───────────────────────────────────────────── */
            // User supplies *gross* ETH in msg.value; derive net & tax
            uint256 gross = msg.value;
            uint256 tax = (gross * bps) / 10_000;
            uint256 net = gross - tax; // ETH that reaches pool

            safeTransferETH(receiver, tax);

            amountOut =
                IZAMM(ZAMM).swapExactIn{value: net}(poolKey, net, amountOutMin, true, to, deadline);
        } else {
            /* ── token → ETH ───────────────────────────────────────────── */
            require(msg.value == 0, InvalidMsgVal());
            _pullERC20(token1, amountIn); // amountIn is net tokens
            amountOut = IZAMM(ZAMM).swapExactIn(
                poolKey, amountIn, amountOutMin, false, address(this), deadline
            );

            uint256 taxOut = (amountOut * bps) / 10_000;
            safeTransferETH(receiver, taxOut);
            safeTransferETH(to, amountOut - taxOut);
        }
    }

    error Overspend();

    function swapExactOut(
        PoolKey calldata poolKey,
        uint256 amountOut, // exact tokens or ETH user wants after tax
        uint256 amountInMax, // max tokens caller can possibly spend
        bool zeroForOne, // true = ETH→token ; false = token→ETH
        address to,
        uint256 deadline
    ) public payable lock returns (uint256 amountIn) {
        // Pool sanity
        require(poolKey.token0 == address(0) && poolKey.id0 == 0, InvalidPoolKey());
        require(poolKey.token1 == token1 && poolKey.id1 == 0, InvalidPoolKey());
        _verifyHook(poolKey);

        uint256 bps = taxRate;

        if (zeroForOne) {
            /* ── ETH → token ─────────────────────────────────────────── */
            // Caller sends *grossMax* ETH in msg.value.
            uint256 grossMax = msg.value;

            // Derive the *max net* we are willing to send into the pool:
            uint256 netMax = (grossMax * (10_000 - bps)) / 10_000;

            // Execute swap; any unused ETH will be refunded later
            amountIn = IZAMM(ZAMM).swapExactOut{value: netMax}(
                poolKey, amountOut, netMax, true, to, deadline
            );

            // Compute actual tax from net ETH spent
            uint256 tax = (amountIn * bps) / 10_000;

            // total ETH consumed = amountIn + tax
            uint256 spent = amountIn + tax;
            require(spent <= grossMax, Overspend()); // should always hold

            safeTransferETH(receiver, tax);

            uint256 refund = grossMax - spent;
            if (refund != 0) safeTransferETH(msg.sender, refund);
        } else {
            /* ── token → ETH ─────────────────────────────────────────── */
            require(msg.value == 0, InvalidMsgVal());
            _pullERC20(token1, amountInMax);

            // Derive the *gross* ETH we need from the pool to satisfy the net `amountOut`
            uint256 grossOut = (amountOut * 10_000 + (10_000 - bps) - 1) / (10_000 - bps); // ceil‑div

            // Swap for the gross amount; hook receives `grossOut` ETH
            amountIn = IZAMM(ZAMM).swapExactOut(
                poolKey, grossOut, amountInMax, false, address(this), deadline
            );

            uint256 tax = grossOut - amountOut; // exact tax in ETH
            safeTransferETH(receiver, tax);
            safeTransferETH(to, amountOut); // net ETH to user

            // refund unused tokens, if any
            if (amountInMax > amountIn) {
                IERC20(token1).transfer(msg.sender, amountInMax - amountIn);
            }
        }
    }

    function toGross(uint256 net) public view returns (uint256) {
        return (net * 10_000 + (10_000 - taxRate) - 1) / (10_000 - taxRate);
    }

    function toNet(uint256 gross) public view returns (uint256) {
        return gross * (10_000 - taxRate) / 10_000;
    }

    error NoLowLevelSwap();
    error NotHooked();

    function beforeAction(bytes4 sig, uint256, /*poolId*/ address sender, bytes calldata /*data*/ )
        public
        view
        returns (uint256)
    {
        require(sig != IZAMM.swap.selector, NoLowLevelSwap());

        bool isSwap = sig == IZAMM.swapExactIn.selector || sig == IZAMM.swapExactOut.selector;

        if (isSwap) {
            if (sender != address(this)) revert NotHooked();
            return 30; // 0.3% LP fee bps
        }

        return 0; // Empty return
    }

    error Unauthorized();

    receive() external payable {
        require(msg.sender == ZAMM, Unauthorized());
    }

    /// @dev Set new receiver to receive ETH taxes.
    function setReceiver(address _receiver) public {
        require(msg.sender == receiver, Unauthorized());
        receiver = _receiver;
    }

    /// @dev Set new tax rate for hook swaps.
    function setTaxRate(uint96 _taxRate) public {
        require(msg.sender == receiver, Unauthorized());
        require(_taxRate < 10_000, InvalidTaxRate());
        taxRate = _taxRate;
    }

    // Solady (https://github.com/Vectorized/soledge/blob/main/src/utils/ReentrancyGuard.sol)
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

    function _pullERC20(address token, uint256 amt) internal {
        IERC20(token).transferFrom(msg.sender, address(this), amt);
    }

    error HookMismatch();

    /* ─── hook‑matching guard ───────────────────────────────────────
     Ensures the pool’s feeOrHook is exactly:
         FLAG_BEFORE | address(this)
     i.e. before‑hook only, no after‑hook flag, no fee‑bps value. */
    function _verifyHook(PoolKey calldata pk) internal view {
        uint256 v = pk.feeOrHook;
        require(
            (v & ADDR_MASK) == uint256(uint160(address(this))) && (v & FLAG_BEFORE) != 0
                && (v & FLAG_AFTER) == 0,
            HookMismatch()
        );
    }
}

/* ────────── helpers ────────── */

uint256 constant FLAG_BEFORE = 1 << 255;
uint256 constant FLAG_AFTER = 1 << 254;
uint256 constant ADDR_MASK = (1 << 160) - 1;

struct PoolKey {
    uint256 id0;
    uint256 id1;
    address token0;
    address token1;
    uint256 feeOrHook; // bps-fee OR flags|address
}

interface IZAMM {
    function swapExactIn(
        PoolKey calldata poolKey,
        uint256 amountIn,
        uint256 amountOutMin,
        bool zeroForOne,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountOut);

    function swapExactOut(
        PoolKey calldata poolKey,
        uint256 amountOut,
        uint256 amountInMax,
        bool zeroForOne,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountIn);

    function swap(
        PoolKey calldata poolKey,
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external;
}

interface IERC20 {
    function transferFrom(address, address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

error ETHTransferFailed();

function safeTransferETH(address to, uint256 amount) {
    assembly ("memory-safe") {
        if iszero(call(gas(), to, amount, codesize(), 0x00, codesize(), 0x00)) {
            mstore(0x00, 0xb12d13eb) // `ETHTransferFailed()`
            revert(0x1c, 0x04)
        }
    }
}

function _ensureAllowance(address token) {
    IERC20(token).approve(ZAMM, type(uint256).max);
}
