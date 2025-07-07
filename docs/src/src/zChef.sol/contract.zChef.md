# zChef
[Git Source](https://github.com/zammdefi/ZAMM/blob/f29647612706d56219b8c998c8009dfa5002472c/src/zChef.sol)

**Inherits:**
[ERC6909Lite](/src/zChef.sol/abstract.ERC6909Lite.md)

─────────────────────────────── zChef Singleton ────────────────────────────────

ERC6909 LP incentives staking rewards. Minimalist Multitoken MasterChef.


## State Variables
### ACC_PRECISION

```solidity
uint256 constant ACC_PRECISION = 1e12;
```


### pools

```solidity
mapping(uint256 chefId => Pool) public pools;
```


### streamCreator

```solidity
mapping(uint256 chefId => address) public streamCreator;
```


### userDebt

```solidity
mapping(uint256 chefId => mapping(address user => uint256)) public userDebt;
```


## Functions
### constructor


```solidity
constructor() payable;
```

### lock

*Reentrancy lock. We sanity check contract calls with this.*


```solidity
modifier lock();
```

### createStream

`rewardId == 0` ⇢ reward is ERC20; otherwise ERC6909.


```solidity
function createStream(
    address lpToken,
    uint256 lpId,
    address rewardToken,
    uint256 rewardId,
    uint256 amount,
    uint64 duration,
    bytes32
) public lock returns (uint256 chefId);
```

### deposit

Pull LP `amount` in for staking rewards for given `chefId`.


```solidity
function deposit(uint256 chefId, uint256 amount) public lock;
```

### withdraw

Pull LP `shares` out with staking rewards for given `chefId`.


```solidity
function withdraw(uint256 chefId, uint256 shares) public lock;
```

### harvest

Pull just LP staking rewards for given `chefId`.


```solidity
function harvest(uint256 chefId) public lock;
```

### emergencyWithdraw

Pull LP immediately, forfeit rewards.


```solidity
function emergencyWithdraw(uint256 chefId) public lock;
```

### sweepRemainder

Reclaim undistributed rewards after the stream has ended.


```solidity
function sweepRemainder(uint256 chefId, address to) public lock;
```

### migrate

Move an existing stake from one incentive stream to another
without leaving the contract or touching the user’s wallet.

*• Both pools **must** reference the same LP token and ID.
• Pending rewards from the old pool are harvested first.
• Reverts if the destination stream has already ended.*


```solidity
function migrate(uint256 fromChefId, uint256 toChefId, uint256 shares) public lock;
```

### rewardPerSharePerYear

Annualized reward flow per share, scaled by ACC_PRECISION (1e12).


```solidity
function rewardPerSharePerYear(uint256 chefId) public view returns (uint256);
```

### rewardPerShareRemaining

Reward per share from now until stream end.


```solidity
function rewardPerShareRemaining(uint256 chefId) public view returns (uint256);
```

### rewardPerYear

Annualized reward flow for `user`, in raw token units.


```solidity
function rewardPerYear(uint256 chefId, address user) public view returns (uint256);
```

### pendingReward

Pending (unharvested) reward for a user in raw token units.


```solidity
function pendingReward(uint256 chefId, address user) public view returns (uint256);
```

### _updatePool

*Update pool storage and stream accounting.*


```solidity
function _updatePool(uint256 chefId) internal returns (Pool storage p);
```

### _transferIn

*Pull tokens in. If `id` is 0, treat as ERC20.*


```solidity
function _transferIn(address token, uint256 id, uint256 amt) internal;
```

### _transferOut

*Push tokens out. If `id` is 0, treat as ERC20.*


```solidity
function _transferOut(address token, address to, uint256 id, uint256 amt) internal;
```

### zapDeposit

ETH LP zap for ZAMM-like `lpSrc`.


```solidity
function zapDeposit(
    address lpSrc,
    uint256 chefId,
    PoolKey memory poolKey,
    uint256 amountOutMin,
    uint256 amount0Min,
    uint256 amount1Min,
    uint256 deadline
) public payable lock returns (uint256 amount0, uint256 amount1, uint256 liquidity);
```

### _computePoolId

*Compute the hashed pool key Id for LP checks.*


```solidity
function _computePoolId(PoolKey memory poolKey) internal pure returns (uint256 poolId);
```

## Events
### Sweep

```solidity
event Sweep(uint256 indexed chefId, uint256 amount);
```

### StreamExtended

```solidity
event StreamExtended(uint256 indexed chefId, uint64 oldEnd, uint64 newEnd);
```

### Deposit

```solidity
event Deposit(address indexed user, uint256 indexed chefId, uint256 amount);
```

### EmergencyWithdraw

```solidity
event EmergencyWithdraw(address indexed user, uint256 indexed chefId, uint256 shares);
```

### Withdraw

```solidity
event Withdraw(address indexed user, uint256 indexed chefId, uint256 shares, uint256 pending);
```

### StreamCreated

```solidity
event StreamCreated(
    address indexed creator, uint256 indexed chefId, uint256 amount, uint64 duration
);
```

## Errors
### Reentrancy

```solidity
error Reentrancy();
```

### Exists

```solidity
error Exists();
```

### Overflow

```solidity
error Overflow();
```

### ZeroAmount

```solidity
error ZeroAmount();
```

### InvalidDuration

```solidity
error InvalidDuration();
```

### PrecisionOverflow

```solidity
error PrecisionOverflow();
```

### StreamEnded

```solidity
error StreamEnded();
```

### TransferFailed

```solidity
error TransferFailed();
```

### NoStake

```solidity
error NoStake();
```

### Unauthorized

```solidity
error Unauthorized();
```

### StreamActive

```solidity
error StreamActive();
```

### StakeRemaining

```solidity
error StakeRemaining();
```

### NothingToSweep

```solidity
error NothingToSweep();
```

### SamePool

```solidity
error SamePool();
```

### LPMismatch

```solidity
error LPMismatch();
```

### NoPool

```solidity
error NoPool();
```

### InvalidPoolId

```solidity
error InvalidPoolId();
```

### InvalidPoolKey

```solidity
error InvalidPoolKey();
```

### InvalidPoolAMM

```solidity
error InvalidPoolAMM();
```

### SwapExactInFail

```solidity
error SwapExactInFail();
```

### AddLiquidityFail

```solidity
error AddLiquidityFail();
```

## Structs
### Pool

```solidity
struct Pool {
    address lpToken;
    uint256 lpId;
    address rewardToken;
    uint256 rewardId;
    uint128 rewardRate;
    uint64 end;
    uint64 lastUpdate;
    uint128 totalShares;
    uint256 accRewardPerShare;
}
```

