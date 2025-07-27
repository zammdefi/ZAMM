# zAMM

A Minimal Multitoken AMM with Coin factory. By [z0r0z](https://x.com/z0r0zzz).

Deployed to [`0x000000000000040470635EB91b7CE4D132D616eD`](https://contractscan.xyz/contract/0x000000000000040470635EB91b7CE4D132D616eD).

This deployment includes hooks, embedded orderbook, and timelock extensions. See [V0](https://contractscan.xyz/contract/0x00000000000008882D72EfA6cCE4B6a40b24C860) for previous deployment.

Docs: [docs.zamm.eth.limo](https://docs.zamm.eth.limo/)

## Incentives

zChef: [`0x00000000009991E374a1628e3B2f60991Bc26DA4`](https://contractscan.xyz/contract/0x00000000009991E374a1628e3B2f60991Bc26DA4)
> ERC-6909 LP streamed incentives (works with all versions of zAMM)

## Periphery

zCurve: [`0x00000000007732aBAd9e86BDd0C3A270197EF2e1`](https://contractscan.xyz/contract/0x00000000007732aBAd9e86BDd0C3A270197EF2e1)
> Quadratic-then-linear bonding curve to sell coins to fund zAMM LP (burned or locked for creator)

ZAMMLaunch: [`0x000000000077A9C733B9ac3781fB5A1BC7701FBc`](https://contractscan.xyz/contract/0x000000000077A9C733B9ac3781fB5A1BC7701FBc)
> Fixed-price tranches for OTC or ICO-style coin sales that fund locked liquidity in zAMM

ZAMMDrop: [`0x0000000000123A35801d0c49B3aE054ed71AC828`](https://contractscan.xyz/contract/0x0000000000123A35801d0c49B3aE054ed71AC828)
> Batch transfer and airdropping tool for ERC-6909 coin Ids.

coinchan: [`0x00000000007762D8DCADEddD5Aa5E9a5e2B7c6f5`](https://contractscan.xyz/contract/0x00000000007762D8DCADEddD5Aa5E9a5e2B7c6f5)
> Simple pool initializer with vested LP (phased out in favor of ZAMMLaunch and zCurve)

## Getting Started

Run: `curl -L https://foundry.paradigm.xyz | bash && source ~/.bashrc && foundryup`

Build the foundry project with `forge build`. Run tests with `forge test`. Measure gas with `forge snapshot`. Format with `forge fmt`.

## Disclaimer

*These smart contracts and testing suite are being provided as is. No guarantee, representation or warranty is being made, express or implied, as to the safety or correctness of anything provided herein or through related user interfaces. This repository and related code have not been audited and as such there can be no assurance anything will work as intended, and users may experience delays, failures, errors, omissions, loss of transmitted information or loss of funds. The creators are not liable for any of the foregoing. Users should proceed with caution and use at their own risk.*

## License

MIT. See [LICENSE](./LICENSE) for more details.
