# Tests

- `ArcalsContracts.t.sol`: issuance, conversion and governance unit tests, plus a
  stateful invariant suite that rechecks supply, reserve, circulating supply,
  Vault NFT count, FIFO membership and lock release after every operation.
- `SecurityRegressions.t.sol`: access control, deployment integrity and
  conversion safety regressions.
- `Reserve.t.sol`: reserved IDs, fixed recipient, batch bounds, public cap and
  reentrancy.
- `MetadataRenderer.t.sol`: on-chain artwork compared byte for byte with
  `test/fixtures/render`, Mirror renderer switching and fallback.
- `ContentRegistrar.t.sol`: scalar-ABI content registration.
- `ProtocolVectors.t.sol`: EIP-712, work configuration, epoch, RandomX input,
  amount and signature rules recomputed in Solidity against shared vectors.
- `PiArchiveVectors.t.sol`: Pi packing and Merkle membership proofs, read from
  `test/fixtures/pi`.

```sh
forge test
```
