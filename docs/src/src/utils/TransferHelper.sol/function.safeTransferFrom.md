# safeTransferFrom
[Git Source](https://github.com/zammdefi/ZAMM/blob/f29647612706d56219b8c998c8009dfa5002472c/src/utils/TransferHelper.sol)

*Sends `amount` of ERC20 `token` from `from` to `to`.
Reverts upon failure.
The `from` account must have at least `amount` approved for
the current contract to manage.*


```solidity
function safeTransferFrom(address token, address from, address to, uint256 amount);
```

