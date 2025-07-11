// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// ───────────────────────────── LP & Reward Interfaces ─────────────────────────────
/// @notice Multitoken transfer interface.
interface IERC6909 {
    function transfer(address, uint256, uint256) external returns (bool);
    function transferFrom(address, address, uint256, uint256) external returns (bool);
}

/// ───────────────────────────── Minimal ERC6909-Lite ───────────────────────────────
/// @notice Minimalist and gas efficient "lite" ERC6909 implementation. Serves backend for incentives.
/// Adapted from Solmate (https://github.com/transmissions11/solmate/blob/main/src/tokens/ERC6909.sol).
abstract contract ERC6909Lite {
    event Transfer(
        address caller, address indexed from, address indexed to, uint256 indexed id, uint256 amount
    );

    mapping(address => mapping(uint256 => uint256)) public balanceOf;

    function _mint(address receiver, uint256 id, uint256 amount) internal {
        unchecked {
            balanceOf[receiver][id] += amount;
        }
        emit Transfer(msg.sender, address(0), receiver, id, amount);
    }

    function _burn(address sender, uint256 id, uint256 amount) internal {
        balanceOf[sender][id] -= amount;
        emit Transfer(msg.sender, sender, address(0), id, amount);
    }
}

/// ─────────────────────────────── zChef Singleton ────────────────────────────────
/// @notice ERC6909 LP incentives staking rewards. Minimalist Multitoken MasterChef.
contract zChef is ERC6909Lite {
    /* ───────────────────────────── Events ───────────────────────────── */
    event Sweep(uint256 indexed chefId, uint256 amount);
    event StreamExtended(uint256 indexed chefId, uint64 oldEnd, uint64 newEnd);
    event Deposit(address indexed user, uint256 indexed chefId, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed chefId, uint256 shares);
    event Withdraw(address indexed user, uint256 indexed chefId, uint256 shares, uint256 pending);
    event StreamCreated(
        address indexed creator, uint256 indexed chefId, uint256 amount, uint64 duration
    );

    /* ─── constants ─── */
    uint256 constant ACC_PRECISION = 1e12;

    /* ─── pool state ─── */
    struct Pool {
        // reward pair
        address lpToken;
        uint256 lpId;
        address rewardToken;
        uint256 rewardId;
        // vesting
        uint128 rewardRate; // tokens-1e12 per second
        uint64 end;
        uint64 lastUpdate;
        // accounting
        uint128 totalShares; // ≡ total x-shares outstanding
        uint256 accRewardPerShare; // scaled 1e12
    }

    mapping(uint256 chefId => Pool) public pools;
    mapping(uint256 chefId => address) public streamCreator;
    mapping(uint256 chefId => mapping(address user => uint256)) public userDebt;

    constructor() payable {} // gas optimization

    /* ─── re-entrancy guard ─── */
    // Solady (https://github.com/Vectorized/soledge/blob/main/src/utils/ReentrancyGuard.sol)
    error Reentrancy();

    /// @dev Reentrancy lock. We sanity check contract calls with this.
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

    /* ───────────────────────────── Stream creation ───────────────────────────── */
    error Exists();
    error Overflow();
    error ZeroAmount();
    error InvalidDuration();
    error PrecisionOverflow();

    /// @notice `rewardId == 0` ⇢ reward is ERC20; otherwise ERC6909.
    function createStream(
        address lpToken,
        uint256 lpId,
        address rewardToken,
        uint256 rewardId,
        uint256 amount,
        uint64 duration,
        bytes32 // uniqueness and/or vanity mining
    ) public lock returns (uint256 chefId) {
        require(amount != 0, ZeroAmount());
        require(duration != 0, InvalidDuration());
        require(duration <= 730 days, InvalidDuration()); // 2 years max

        chefId = uint256(keccak256(abi.encode(msg.sender, msg.data)));
        streamCreator[chefId] = msg.sender;
        Pool storage p = pools[chefId];
        require(p.end == 0, Exists());

        /* pull incentives in */
        _transferIn(rewardToken, rewardId, amount);

        /* overflow-safe reward rate */
        require(amount <= type(uint256).max / ACC_PRECISION, PrecisionOverflow());
        uint256 rate = amount * ACC_PRECISION / duration;
        require(rate <= type(uint128).max, Overflow());

        /* initialize pool */
        p.lpToken = lpToken;
        p.lpId = lpId;
        p.rewardToken = rewardToken;
        p.rewardId = rewardId;
        p.rewardRate = uint128(rate);
        p.lastUpdate = uint64(block.timestamp);
        p.end = uint64(block.timestamp + duration);

        emit StreamCreated(msg.sender, chefId, amount, duration);
    }

    /* ───────────────────────────── Deposit / Withdraw ───────────────────────────── */
    error StreamEnded();

    /// @notice Pull LP `amount` in for staking rewards for given `chefId`.
    function deposit(uint256 chefId, uint256 amount) public lock {
        require(amount != 0, ZeroAmount());
        require(amount <= type(uint128).max, Overflow());

        Pool storage p = _updatePool(chefId);

        if (block.timestamp >= p.end) revert StreamEnded();

        /* ── pull LP & mint shares 1:1 ── */
        require(
            IERC6909(p.lpToken).transferFrom(msg.sender, address(this), p.lpId, amount),
            TransferFromFailed()
        );

        uint128 shares = uint128(amount); // 1:1

        // explicit uint256 cast avoids pre-overflow and guarantees custom error
        require(uint256(p.totalShares) + shares <= type(uint128).max, Overflow());
        p.totalShares += shares;

        _mint(msg.sender, chefId, shares);

        /* ── update user debt ── */
        userDebt[chefId][msg.sender] += uint256(shares) * p.accRewardPerShare / ACC_PRECISION;

        emit Deposit(msg.sender, chefId, amount);
    }

    error TransferFailed();

    /// @notice Pull LP `shares` out with staking rewards for given `chefId`.
    function withdraw(uint256 chefId, uint256 shares) public lock {
        require(shares != 0, ZeroAmount());

        Pool storage p = _updatePool(chefId);

        uint256 uShares = balanceOf[msg.sender][chefId];
        /* pending */
        uint256 pending =
            uShares * p.accRewardPerShare / ACC_PRECISION - userDebt[chefId][msg.sender];

        /* burn shares & update supply */
        _burn(msg.sender, chefId, shares);
        p.totalShares -= uint128(shares);

        /* return LP */
        require(IERC6909(p.lpToken).transfer(msg.sender, p.lpId, shares), TransferFailed());

        /* pay rewards */
        if (pending != 0) _transferOut(p.rewardToken, msg.sender, p.rewardId, pending);

        /* reset debt */
        uint256 newShares = uShares - shares;
        userDebt[chefId][msg.sender] = newShares * p.accRewardPerShare / ACC_PRECISION;

        emit Withdraw(msg.sender, chefId, shares, pending);
    }

    error NoStake();

    /// @notice Pull just LP staking rewards for given `chefId`.
    function harvest(uint256 chefId) public lock {
        uint256 shares = balanceOf[msg.sender][chefId];
        if (shares == 0) revert NoStake();

        Pool storage p = _updatePool(chefId);

        uint256 pending =
            shares * p.accRewardPerShare / ACC_PRECISION - userDebt[chefId][msg.sender];
        userDebt[chefId][msg.sender] = shares * p.accRewardPerShare / ACC_PRECISION;
        if (pending != 0) _transferOut(p.rewardToken, msg.sender, p.rewardId, pending);

        emit Withdraw(msg.sender, chefId, 0, pending);
    }

    /// @notice Pull LP immediately, forfeit rewards.
    function emergencyWithdraw(uint256 chefId) public lock {
        uint256 shares = balanceOf[msg.sender][chefId];
        require(shares != 0, NoStake());

        Pool storage p = pools[chefId];

        _burn(msg.sender, chefId, shares);
        p.totalShares -= uint128(shares);

        delete userDebt[chefId][msg.sender];
        require(IERC6909(p.lpToken).transfer(msg.sender, p.lpId, shares), TransferFailed());

        emit EmergencyWithdraw(msg.sender, chefId, shares);
    }

    error Unauthorized();
    error StreamActive();
    error StakeRemaining();
    error NothingToSweep();

    /// @notice Reclaim undistributed rewards after the stream has ended.
    function sweepRemainder(uint256 chefId, address to) public lock {
        if (msg.sender != streamCreator[chefId]) revert Unauthorized();

        Pool storage p = pools[chefId];

        if (block.timestamp <= p.end) revert StreamActive();
        if (p.totalShares != 0) revert StakeRemaining();

        // seconds between last distribution and scheduled end
        uint64 dt = p.end > p.lastUpdate ? uint64(p.end - p.lastUpdate) : 0;
        uint256 amt = uint256(dt) * p.rewardRate / ACC_PRECISION;
        if (amt == 0) revert NothingToSweep();

        // mark all rewards as streamed, preventing double-sweep
        p.lastUpdate = p.end;

        _transferOut(p.rewardToken, to, p.rewardId, amt);

        emit Sweep(chefId, amt);
    }

    error SamePool();
    error LPMismatch();

    /// @notice Move an existing stake from one incentive stream to another
    ///         without leaving the contract or touching the user’s wallet.
    /// @dev    • Both pools **must** reference the same LP token and ID.
    ///         • Pending rewards from the old pool are harvested first.
    ///         • Reverts if the destination stream has already ended.
    function migrate(uint256 fromChefId, uint256 toChefId, uint256 shares) public lock {
        require(shares != 0, ZeroAmount());
        require(fromChefId != toChefId, SamePool());

        Pool storage p = _updatePool(fromChefId);

        address fromLpToken = p.lpToken;
        uint256 fromLpId = p.lpId;

        uint256 uShares = balanceOf[msg.sender][fromChefId];
        /* pending */
        uint256 pending =
            uShares * p.accRewardPerShare / ACC_PRECISION - userDebt[fromChefId][msg.sender];

        /* burn shares & update supply */
        _burn(msg.sender, fromChefId, shares);
        p.totalShares -= uint128(shares);

        /* pay rewards */
        if (pending != 0) _transferOut(p.rewardToken, msg.sender, p.rewardId, pending);

        /* reset debt */
        uint256 newShares = uShares - shares;
        userDebt[fromChefId][msg.sender] = newShares * p.accRewardPerShare / ACC_PRECISION;

        emit Withdraw(msg.sender, fromChefId, shares, pending);

        p = _updatePool(toChefId);

        // now, also confirm migrating LP tokens actually match
        require(fromLpToken == p.lpToken, LPMismatch());
        require(fromLpId == p.lpId, LPMismatch());

        if (block.timestamp >= p.end) revert StreamEnded();

        // explicit uint256 cast avoids pre-overflow and guarantees custom error
        require(uint256(p.totalShares) + shares <= type(uint128).max, Overflow());
        p.totalShares += uint128(shares);

        _mint(msg.sender, toChefId, shares);

        /* ── update user debt ── */
        userDebt[toChefId][msg.sender] += uint256(shares) * p.accRewardPerShare / ACC_PRECISION;

        emit Deposit(msg.sender, toChefId, shares);
    }

    /* ───────────────────────────── View helper ───────────────────────────── */
    /// @notice Annualized reward flow per share, scaled by ACC_PRECISION (1e12).
    function rewardPerSharePerYear(uint256 chefId) public view returns (uint256) {
        Pool storage p = pools[chefId];
        if (p.totalShares == 0 || block.timestamp >= p.end) return 0;
        return uint256(p.rewardRate) * 365 days / p.totalShares;
    }

    /// @notice Reward per share from now until stream end.
    function rewardPerShareRemaining(uint256 chefId) public view returns (uint256) {
        Pool storage p = pools[chefId];
        if (block.timestamp >= p.end || p.totalShares == 0) return 0;
        uint256 secsLeft = p.end - block.timestamp;
        return uint256(p.rewardRate) * secsLeft / p.totalShares; // raw tokens ×1e12
    }

    /// @notice Annualized reward flow for `user`, in raw token units.
    function rewardPerYear(uint256 chefId, address user) public view returns (uint256) {
        uint256 perShare = rewardPerSharePerYear(chefId);
        return balanceOf[user][chefId] * perShare / ACC_PRECISION;
    }

    /// @notice Pending (unharvested) reward for a user in raw token units.
    function pendingReward(uint256 chefId, address user) public view returns (uint256) {
        Pool storage p = pools[chefId];
        if (p.end == 0) return 0;

        uint256 acc = p.accRewardPerShare;
        if (block.timestamp > p.lastUpdate && p.totalShares != 0) {
            uint256 till = block.timestamp < p.end ? block.timestamp : p.end;
            uint256 dt = till - p.lastUpdate;
            acc += dt * p.rewardRate / p.totalShares;
        }
        uint256 shares = balanceOf[user][chefId];
        return shares * acc / ACC_PRECISION - userDebt[chefId][user];
    }

    /* ───────────────────────────── Internal: pool update ───────────────────────────── */
    error NoPool();

    /// @dev Update pool storage and stream accounting.
    function _updatePool(uint256 chefId) internal returns (Pool storage p) {
        p = pools[chefId];
        require(p.end != 0, NoPool());

        uint64 nowTs = uint64(block.timestamp);
        if (nowTs <= p.lastUpdate) return p; // already up-to-date

        /* ─────────────────────  IDLE-POOL HANDLING  ───────────────────── */
        if (p.totalShares == 0) {
            // No stakers: slide the stream forward by the idle duration
            uint64 idle = nowTs - p.lastUpdate; // safe: nowTs > lastUpdate
            uint64 oldEnd = p.end;

            // Extend only while the stream is still active (oldEnd ≥ nowTs)
            if (oldEnd >= nowTs) {
                uint64 newEnd = oldEnd + idle;
                require(newEnd >= oldEnd, Overflow()); // uint64 wrap guard
                p.end = newEnd;
                emit StreamExtended(chefId, oldEnd, newEnd);
            }

            p.lastUpdate = nowTs;
            return p;
        }

        /* ─────────────────────  NORMAL ACCRUAL  ───────────────────── */
        uint64 till = nowTs < p.end ? nowTs : p.end;
        uint256 dt = till - p.lastUpdate; // p.totalShares != 0
        p.accRewardPerShare += dt * p.rewardRate / p.totalShares;
        p.lastUpdate = till;
    }

    /* ───────────────────────────── Token transfer helpers ───────────────────────────── */
    /// @dev Pull tokens in. If `id` is 0, treat as ERC20.
    function _transferIn(address token, uint256 id, uint256 amt) internal {
        if (id != 0) {
            require(
                IERC6909(token).transferFrom(msg.sender, address(this), id, amt),
                TransferFromFailed()
            );
        } else {
            safeTransferFrom(token, msg.sender, address(this), amt);
        }
    }

    /// @dev Push tokens out. If `id` is 0, treat as ERC20.
    function _transferOut(address token, address to, uint256 id, uint256 amt) internal {
        if (id != 0) require(IERC6909(token).transfer(to, id, amt), TransferFailed());
        else safeTransfer(token, to, amt);
    }

    /* ───────────────────────────── ETH LP ZAP ───────────────────────────── */
    error InvalidPoolId();
    error InvalidPoolKey();
    error InvalidPoolAMM();
    error SwapExactInFail();
    error AddLiquidityFail();

    /// @notice ETH LP zap for ZAMM-like `lpSrc`.
    function zapDeposit(
        address lpSrc, // e.g., ZAMM
        uint256 chefId, // incentives
        PoolKey memory poolKey,
        uint256 amountOutMin,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    ) public payable lock returns (uint256 amount0, uint256 amount1, uint256 liquidity) {
        unchecked {
            require(poolKey.token0 == address(0), InvalidPoolKey());
            require(lpSrc == ZAMM_0 || lpSrc == ZAMM_1, InvalidPoolAMM());

            assembly ("memory-safe") {
                pop(call(gas(), lpSrc, callvalue(), codesize(), 0x00, codesize(), 0x00))
            }

            amount0 = msg.value / 2;

            if (lpSrc == ZAMM_0) poolKey.feeOrHook = uint256(uint96(poolKey.feeOrHook));

            // 1) swapExactIn
            {
                bytes4 sel = lpSrc == ZAMM_0 ? bytes4(0x7466fde7) : bytes4(0x3c5eec50);
                bytes memory callData = abi.encodeWithSelector(
                    sel, poolKey, amount0, amountOutMin, true, lpSrc, deadline
                );
                (bool ok, bytes memory ret) = lpSrc.call(callData);
                require(ok, SwapExactInFail());
                amount1 = abi.decode(ret, (uint256));
            }

            // 2) addLiquidity
            {
                bytes4 sel = lpSrc == ZAMM_0 ? bytes4(0x48416da8) : bytes4(0xc42957a8);
                bytes memory callData = abi.encodeWithSelector(
                    sel, poolKey, amount0, amount1, amount0Min, amount1Min, address(this), deadline
                );
                (bool ok, bytes memory ret) = lpSrc.call(callData);
                require(ok, AddLiquidityFail());
                (amount0, amount1, liquidity) = abi.decode(ret, (uint256, uint256, uint256));
            }

            // refund any excess
            IZAMM(lpSrc).recoverTransientBalance(address(0), 0, msg.sender);
            IZAMM(lpSrc).recoverTransientBalance(poolKey.token1, poolKey.id1, msg.sender);
        }

        Pool storage p = _updatePool(chefId);

        require(p.lpToken == lpSrc, LPMismatch());
        require(p.lpId == _computePoolId(poolKey), InvalidPoolId());

        if (block.timestamp >= p.end) revert StreamEnded();

        uint128 shares = uint128(liquidity); // 1:1

        // explicit uint256 cast avoids pre-overflow and guarantees custom error
        require(uint256(p.totalShares) + shares <= type(uint128).max, Overflow());
        p.totalShares += shares;

        _mint(msg.sender, chefId, shares);

        /* ── update user debt ── */
        userDebt[chefId][msg.sender] += uint256(shares) * p.accRewardPerShare / ACC_PRECISION;

        emit Deposit(msg.sender, chefId, liquidity);
    }

    /// @dev Compute the hashed pool key Id for LP checks.
    function _computePoolId(PoolKey memory poolKey) internal pure returns (uint256 poolId) {
        assembly ("memory-safe") {
            poolId := keccak256(poolKey, 0xa0)
        }
    }
}

// Modified from Solady (https://github.com/Vectorized/solady/blob/main/src/utils/SafeTransferLib.sol)
function safeTransfer(address token, address to, uint256 amount) {
    assembly ("memory-safe") {
        mstore(0x14, to)
        mstore(0x34, amount)
        mstore(0x00, 0xa9059cbb000000000000000000000000)
        let success := call(gas(), token, 0, 0x10, 0x44, 0x00, 0x20)
        if iszero(and(eq(mload(0x00), 1), success)) {
            if iszero(lt(or(iszero(extcodesize(token)), returndatasize()), success)) {
                mstore(0x00, 0x90b8ec18) // `TransferFailed()`
                revert(0x1c, 0x04)
            }
        }
        mstore(0x34, 0)
    }
}

error TransferFromFailed();

function safeTransferFrom(address token, address from, address to, uint256 amount) {
    assembly ("memory-safe") {
        let m := mload(0x40)
        mstore(0x60, amount)
        mstore(0x40, to)
        mstore(0x2c, shl(96, from))
        mstore(0x0c, 0x23b872dd000000000000000000000000)
        let success := call(gas(), token, 0, 0x1c, 0x64, 0x00, 0x20)
        if iszero(and(eq(mload(0x00), 1), success)) {
            if iszero(lt(or(iszero(extcodesize(token)), returndatasize()), success)) {
                mstore(0x00, 0x7939f424) // `TransferFromFailed()`
                revert(0x1c, 0x04)
            }
        }
        mstore(0x60, 0)
        mstore(0x40, m)
    }
}

// ZAMM LP zap extension utils
address constant ZAMM_0 = 0x00000000000008882D72EfA6cCE4B6a40b24C860;
address constant ZAMM_1 = 0x000000000000040470635EB91b7CE4D132D616eD;

struct PoolKey {
    uint256 id0;
    uint256 id1;
    address token0;
    address token1;
    uint256 feeOrHook; // bps-fee OR flags|address
}

interface IZAMM {
    function recoverTransientBalance(address token, uint256 id, address to)
        external
        returns (uint256 amount);
}
