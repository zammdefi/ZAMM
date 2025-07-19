// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

error MaxFee();
error Unauthorized();
error InvalidMetadata();
error DeploymentFailed();

uint256 constant MAX_BPS = 10_000; // 100%
address payable constant ZAMM = payable(0x000000000000040470635EB91b7CE4D132D616eD);

/// @title zCoins (V0)
/// @notice Singleton for ERC6909 & ERC20s with hooks
/// @author z0r0z & 0xc0de4c0ffee & kobuta23 & rhynotic
contract zCoins {
    event MetadataSet(uint256 indexed);
    event OwnershipTransferred(uint256 indexed);

    event OperatorSet(address indexed, address indexed, bool);
    event Approval(address indexed, address indexed, uint256 indexed, uint256);
    event Transfer(address, address indexed, address indexed, uint256 indexed, uint256);

    zToken immutable implementation = new zToken{salt: keccak256("")}();

    mapping(uint256 id => Metadata) _metadata;

    mapping(uint256 id => uint256) public totalSupply;
    mapping(uint256 id => address owner) public ownerOf;

    mapping(address owner => mapping(uint256 id => uint256)) public balanceOf;
    mapping(address owner => mapping(address operator => bool)) public isOperator;
    mapping(address owner => mapping(address spender => mapping(uint256 id => uint256))) public
        allowance;

    modifier onlyOwnerOf(uint256 id) {
        require(msg.sender == ownerOf[id], Unauthorized());
        _;
    }

    /* ─── re-entrancy guard ─── */
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

    constructor() payable {}

    // METADATA

    struct Metadata {
        string name;
        string symbol;
        string tokenURI;
    }

    function name(uint256 id) public view returns (string memory) {
        return _metadata[id].name;
    }

    function symbol(uint256 id) public view returns (string memory) {
        return _metadata[id].symbol;
    }

    function decimals(uint256) public pure returns (uint8) {
        return 18;
    }

    function tokenURI(uint256 id) public view returns (string memory) {
        return _metadata[id].tokenURI;
    }

    // CREATION

    error InvalidPoolSupply();

    function create(
        string calldata _name,
        string calldata _symbol,
        string calldata _tokenURI,
        address owner,
        uint256 ownerSupply,
        uint256 poolSupply
    ) public payable returns (uint256 amount0, uint256 amount1, uint256 liquidity) {
        require(bytes(_tokenURI).length != 0, InvalidMetadata());

        uint256 id;
        zToken _implementation = implementation;
        bytes32 salt = keccak256(abi.encodePacked(_name, address(this), _symbol));
        assembly ("memory-safe") {
            mstore(0x21, 0x5af43d3d93803e602a57fd5bf3)
            mstore(0x14, _implementation)
            mstore(0x00, 0x602c3d8160093d39f33d3d3d3d363d3d37363d73)
            id := create2(0, 0x0c, 0x35, salt)
            if iszero(id) {
                mstore(0x00, 0x30116425) // `DeploymentFailed()`
                revert(0x1c, 0x04)
            }
            mstore(0x21, 0)
        }

        _metadata[id] = Metadata(_name, _symbol, _tokenURI);

        _mint(owner, id, ownerSupply);

        ownerOf[id] = owner;

        if (poolSupply != 0) {
            _mint(address(this), id, poolSupply);
            uint256 hook = (1 << 255) | uint256(uint160(id)); // FLAG_BEFORE | coinId
            (amount0, amount1, liquidity) = IZAMM(ZAMM).addLiquidity{value: msg.value}(
                PoolKey(0, id, address(0), address(this), hook),
                msg.value,
                poolSupply,
                0,
                0,
                owner,
                block.timestamp
            );
        } else {
            revert InvalidPoolSupply();
        }
    }

    // MINT/BURN

    function mint(address to, uint256 id, uint256 amount) public onlyOwnerOf(id) {
        _mint(to, id, amount);
    }

    function burn(uint256 id, uint256 amount) public {
        _burn(msg.sender, id, amount);
    }

    // GOVERNANCE

    function setMetadata(uint256 id, string calldata _tokenURI) public onlyOwnerOf(id) {
        require(bytes(_tokenURI).length != 0, InvalidMetadata());
        _metadata[id].tokenURI = _tokenURI;
        emit MetadataSet(id);
    }

    function transferOwnership(uint256 id, address newOwner) public onlyOwnerOf(id) {
        ownerOf[id] = newOwner;
        emit OwnershipTransferred(id);
    }

    // ERC6909

    function transfer(address to, uint256 id, uint256 amount)
        public
        enforceRecipient(id, to)
        returns (bool)
    {
        balanceOf[msg.sender][id] -= amount;
        unchecked {
            balanceOf[to][id] += amount;
        }
        emit Transfer(msg.sender, msg.sender, to, id, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 id, uint256 amount)
        public
        enforceRecipient(id, to)
        returns (bool)
    {
        if (msg.sender == ZAMM && from != address(this)) revert DisallowedRecipient();

        if (msg.sender != from) {
            if (msg.sender != ZAMM) {
                if (msg.sender != address(uint160(id))) {
                    if (!isOperator[from][msg.sender]) {
                        if (allowance[from][msg.sender][id] != type(uint256).max) {
                            allowance[from][msg.sender][id] -= amount;
                        }
                    }
                }
            }
        }

        balanceOf[from][id] -= amount;
        unchecked {
            balanceOf[to][id] += amount;
        }
        emit Transfer(msg.sender, from, to, id, amount);
        return true;
    }

    function approve(address spender, uint256 id, uint256 amount) public returns (bool) {
        allowance[msg.sender][spender][id] = amount;
        emit Approval(msg.sender, spender, id, amount);
        return true;
    }

    function setOperator(address operator, bool approved) public returns (bool) {
        isOperator[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
        return true;
    }

    // ERC20 APPROVAL

    function setAllowance(address owner, address spender, uint256 id, uint256 amount)
        public
        payable
        returns (bool)
    {
        require(msg.sender == address(uint160(id)), Unauthorized());
        allowance[owner][spender][id] = amount;
        emit Approval(owner, spender, id, amount);
        return true;
    }

    // ERC165

    function supportsInterface(bytes4 interfaceId) public pure returns (bool) {
        return interfaceId == 0x01ffc9a7 // ERC165
            || interfaceId == 0x0f632fb3; // ERC6909
    }

    // INTERNAL MINT/BURN

    function _mint(address to, uint256 id, uint256 amount) internal {
        totalSupply[id] += amount;
        unchecked {
            balanceOf[to][id] += amount;
        }
        emit Transfer(msg.sender, address(0), to, id, amount);
    }

    function _burn(address from, uint256 id, uint256 amount) internal {
        balanceOf[from][id] -= amount;
        unchecked {
            totalSupply[id] -= amount;
        }
        emit Transfer(msg.sender, from, address(0), id, amount);
    }

    // ZAMM EXCHANGE INTEGRATIONS

    event TaxSet(uint256 indexed id, uint256 taxBps);
    event RecipientAllowed(uint256 indexed id, address indexed to, bool allowed);

    mapping(uint256 id => uint256) public taxBps;
    mapping(uint256 id => mapping(address recipient => bool)) public isAllowedRecipient;

    error InvalidMsgVal();
    error InvalidPoolKey();
    error DisallowedRecipient();

    function _depositCoin(uint256 id, uint256 amount) internal {
        transferFrom(msg.sender, address(this), id, amount);
    }

    function setTaxBps(uint256 id, uint256 bps) public onlyOwnerOf(id) {
        require(bps < MAX_BPS, MaxFee());
        emit TaxSet(id, taxBps[id] = bps);
    }

    function setAllowedRecipient(uint256 id, address to, bool allowed) public onlyOwnerOf(id) {
        isAllowedRecipient[id][to] = allowed;
        emit RecipientAllowed(id, to, allowed);
    }

    /*─────────────────────────────────────────────────────────────
    │ Exact‑IN swap with creator tax
    │   zeroForOne == true   →  ETH  →  COIN   (fee on ETH‑in)
    │   zeroForOne == false  →  COIN →  ETH    (fee on ETH‑out)
    └─────────────────────────────────────────────────────────────*/
    function swapExactIn(
        PoolKey calldata k,
        uint256 amountIn,
        uint256 amountOutMin,
        bool zeroForOne, // true = ETH→COIN, false = COIN→ETH
        uint256 deadline
    ) public payable lock returns (uint256 result) {
        _assertKey(k);

        uint256 id = k.id1; // coinId
        uint256 bps = taxBps[id];

        if (zeroForOne) {
            /* ───── ETH → COIN (fee on ETH‑in) ───── */
            require(msg.value == amountIn, InvalidMsgVal());

            uint256 fee = (amountIn * bps) / MAX_BPS;
            if (fee != 0) safeTransferETH(ownerOf[id], fee);

            uint256 sent = amountIn - fee;
            result = IZAMM(ZAMM).swapExactIn{value: sent}(
                k, sent, amountOutMin, /*zeroForOne*/ true, msg.sender, deadline
            );
        } else {
            /* ───── COIN → ETH (fee on ETH‑out) ───── */
            require(msg.value == 0, InvalidMsgVal());

            _depositCoin(id, amountIn);

            uint256 rawOut = IZAMM(ZAMM).swapExactIn(
                k, amountIn, amountOutMin, /*zeroForOne*/ false, address(this), deadline
            );

            uint256 fee = (rawOut * bps) / MAX_BPS;
            if (fee != 0) safeTransferETH(ownerOf[id], fee);

            unchecked {
                uint256 send = rawOut - fee;
                if (send != 0) safeTransferETH(msg.sender, send);
                result = send;
            }
        }
    }

    /*─────────────────────────────────────────────────────────────
    │ Exact‑OUT swap with creator tax
    │   zeroForOne == true   →  ETH  →  COIN
    │   zeroForOne == false  →  COIN →  ETH
    └─────────────────────────────────────────────────────────────*/
    function swapExactOut(
        PoolKey calldata k,
        uint256 amountOut, // desired COIN or ETH out
        uint256 amountInMax, // max ETH‑in or COIN‑in
        bool zeroForOne, // true = ETH→COIN, false = COIN→ETH
        uint256 deadline
    ) public payable lock returns (uint256 amountInSpent) {
        _assertKey(k);

        uint256 id = k.id1;
        uint256 bps = taxBps[id];

        if (zeroForOne) {
            /* ───── ETH → COIN ───── */
            require(msg.value == amountInMax, InvalidMsgVal());
            uint256 preBal = address(this).balance - msg.value;

            amountInSpent = IZAMM(ZAMM).swapExactOut{value: amountInMax}(
                k, amountOut, amountInMax, /*zeroForOne*/ true, address(this), deadline
            );

            uint256 fee = (amountInSpent * bps) / MAX_BPS;
            if (fee != 0) safeTransferETH(ownerOf[id], fee);

            unchecked {
                uint256 refund = address(this).balance - preBal - fee;
                if (refund != 0) safeTransferETH(msg.sender, refund);
            }

            transfer(msg.sender, id, amountOut);
        } else {
            /* ───── COIN → ETH ───── */
            require(msg.value == 0, InvalidMsgVal());

            _depositCoin(id, amountInMax);

            amountInSpent = IZAMM(ZAMM).swapExactOut(
                k, amountOut, amountInMax, /*zeroForOne*/ false, address(this), deadline
            );

            if (amountInSpent < amountInMax) {
                transfer(msg.sender, id, amountInMax - amountInSpent);
            }

            uint256 fee = (amountOut * bps) / MAX_BPS;
            if (fee != 0) safeTransferETH(ownerOf[id], fee);

            safeTransferETH(msg.sender, amountOut - fee);
        }
    }

    /*───────────────────────────────────────────────────────────────
    │  Community LP helpers (ETH ↔ zCoin)      
    └───────────────────────────────────────────────────────────────*/

    function addLiquidity(uint256 id, uint256 amountCoinDesired, uint256 deadline)
        public
        payable
        lock
        returns (uint256 ethUsed, uint256 coinUsed, uint256 liquidity)
    {
        require(msg.value != 0, InvalidMsgVal());

        /* pull caller’s zCoins into *this* so ZAMM can grab them */
        transferFrom(msg.sender, address(this), id, amountCoinDesired);

        uint256 hook = (1 << 255) | id; // FLAG_BEFORE | coinId

        PoolKey memory k =
            PoolKey({id0: 0, id1: id, token0: address(0), token1: address(this), feeOrHook: hook});

        /* forward both legs to ZAMM */
        (ethUsed, coinUsed, liquidity) = IZAMM(ZAMM).addLiquidity{value: msg.value}(
            k,
            msg.value,
            amountCoinDesired,
            0,
            0,
            msg.sender, // LP tokens to caller
            deadline
        );

        /*── refund dust ───────────────────────────────*/
        if (coinUsed < amountCoinDesired) {
            transfer(msg.sender, id, amountCoinDesired - coinUsed);
        }
        if (ethUsed < msg.value) {
            unchecked {
                // ≡ msg.value - ethUsed
                safeTransferETH(msg.sender, msg.value - ethUsed);
            }
        }
    }

    function removeLiquidity(
        uint256 id,
        uint256 liquidity,
        uint256 amountEthMin,
        uint256 amountCoinMin,
        uint256 deadline
    ) public lock returns (uint256 ethOut, uint256 coinOut) {
        require(liquidity != 0, Unauthorized());

        uint256 hook = (1 << 255) | id;

        /* canonical pool key */
        PoolKey memory k =
            PoolKey({id0: 0, id1: id, token0: address(0), token1: address(this), feeOrHook: hook});

        /* poolId = keccak256(abi.encode(k))  (5×32 bytes = 0xa0) */
        uint256 poolId =
            uint256(keccak256(abi.encode(uint256(0), id, address(0), address(this), hook)));

        /* pull LP tokens into zCoins so ZAMM can burn them */
        zCoins(ZAMM).transferFrom(msg.sender, address(this), poolId, liquidity);

        /* remove liquidity, send proceeds directly to the user */
        (ethOut, coinOut) = IZAMM(ZAMM).removeLiquidity(
            k,
            liquidity,
            amountEthMin,
            amountCoinMin,
            msg.sender, // receives ETH + zCoin
            deadline
        );
    }

    /*──────────────────────── helpers ──────────────────────────*/
    /// @dev Reverts when `to` is a *foreign* contract that has **not** been whitelisted.
    ///      Order of checks = cheapest → most expensive to avoid unnecessary SLOADs.
    modifier enforceRecipient(uint256 id, address to) {
        if (to == address(this) || to == ZAMM) {
            _;
            return;
        }

        if (to.code.length == 0) {
            _;
            return;
        }

        if (!isAllowedRecipient[id][to]) revert DisallowedRecipient();
        _;
    }

    /// @dev Enforce ETH (token0, id0==0) ↔ zCoin (token1==this) pool.
    function _assertKey(PoolKey calldata k) internal view {
        if (k.token0 != address(0) || k.id0 != 0 || k.token1 != address(this)) {
            revert InvalidPoolKey();
        }
    }

    /// @dev Prevent accidental ETH sends but allow ZAMM refunds.
    receive() external payable {
        require(msg.sender == ZAMM, Unauthorized());
    }
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

    function addLiquidity(
        PoolKey calldata poolKey,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amount0, uint256 amount1, uint256 liquidity);

    function removeLiquidity(
        PoolKey calldata poolKey,
        uint256 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        address to,
        uint256 deadline
    ) external returns (uint256 amount0, uint256 amount1);
}

contract zToken {
    event Approval(address indexed, address indexed, uint256);
    event Transfer(address indexed, address indexed, uint256);

    uint256 public constant decimals = 18;
    address payable immutable zc = payable(msg.sender);

    constructor() payable {}

    function name() public view returns (string memory) {
        return zCoins(zc).name(uint160(address(this)));
    }

    function symbol() public view returns (string memory) {
        return zCoins(zc).symbol(uint160(address(this)));
    }

    function totalSupply() public view returns (uint256) {
        return zCoins(zc).totalSupply(uint160(address(this)));
    }

    function balanceOf(address owner) public view returns (uint256) {
        return zCoins(zc).balanceOf(owner, uint160(address(this)));
    }

    function allowance(address owner, address spender) public view returns (uint256) {
        if (zCoins(zc).isOperator(owner, spender)) return type(uint256).max;
        return zCoins(zc).allowance(owner, spender, uint160(address(this)));
    }

    function approve(address spender, uint256 amount) public returns (bool) {
        emit Approval(msg.sender, spender, amount);
        return zCoins(zc).setAllowance(msg.sender, spender, uint160(address(this)), amount);
    }

    function transfer(address to, uint256 amount) public returns (bool) {
        emit Transfer(msg.sender, to, amount);
        return zCoins(zc).transferFrom(msg.sender, to, uint160(address(this)), amount);
    }

    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        require(allowance(from, msg.sender) >= amount, Unauthorized());
        emit Transfer(from, to, amount);
        return zCoins(zc).transferFrom(from, to, uint160(address(this)), amount);
    }

    // ZAMM FEE GOVERNANCE

    event SwapFeeSet(uint256 indexed swapFee);

    uint256 public swapFee;

    function setSwapFee(uint256 _swapFee) public {
        require(_swapFee < MAX_BPS, MaxFee());
        require(msg.sender == zCoins(zc).ownerOf(uint160(address(this))), Unauthorized());
        emit SwapFeeSet(swapFee = _swapFee);
    }

    function beforeAction(
        bytes4, /*sig*/
        uint256, /*poolId*/
        address sender,
        bytes calldata /*data*/
    ) public view returns (uint256 feeBps) {
        require(sender == zc, Unauthorized());
        uint256 _swapFee = swapFee;
        return _swapFee == 0 ? 30 : _swapFee;
    }
}
