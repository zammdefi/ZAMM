# ERC6909Lite
[Git Source](https://github.com/zammdefi/ZAMM/blob/f29647612706d56219b8c998c8009dfa5002472c/src/zChef.sol)

───────────────────────────── Minimal ERC6909-Lite ───────────────────────────────

Minimalist and gas efficient "lite" ERC6909 implementation. Serves backend for incentives.
Adapted from Solmate (https://github.com/transmissions11/solmate/blob/main/src/tokens/ERC6909.sol).


## State Variables
### balanceOf

```solidity
mapping(address => mapping(uint256 => uint256)) public balanceOf;
```


## Functions
### _mint


```solidity
function _mint(address receiver, uint256 id, uint256 amount) internal;
```

### _burn


```solidity
function _burn(address sender, uint256 id, uint256 amount) internal;
```

## Events
### Transfer

```solidity
event Transfer(
    address caller, address indexed from, address indexed to, uint256 indexed id, uint256 amount
);
```

