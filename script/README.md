# Deployment scripts

Both scripts deploy a one-use `ArcalsDeploymentFactory`, build the creation code
for the seven contracts in the fixed CREATE order and create the whole address
graph in one transaction. The factory records a hash of every creation code; the
scripts recompute and compare them. No private key is read from the
environment: broadcasting uses the wallet passed to `forge script`.

## `DeployArcMainnet.s.sol`

Runs only on Arc Mainnet (chain ID 5042). It also deploys
`ArcalsContentRegistrar` and `ArcalsMetadataRenderer` and prints the calldata
that the management Safe sends to finish the launch:

1. `MintController.registerWorkConfig` with the initial work configuration;
2. `ArcalMirror.setMetadataRenderer` with the deployed renderer;
3. `ArcalsCore.resumeMint`. Mint still cannot start before
   `ARCALS_WORK_GENESIS_TIME`, when the first epoch becomes valid.

The reserved Arcals are issued afterwards with `ArcalsCore.mintReserve(500)`,
repeated until `reserveMintedCount()` reaches 10,000.

| Variable                     | Meaning                                                   |
| ---------------------------- | --------------------------------------------------------- |
| `ARCALS_MANAGEMENT_MULTISIG` | Governance Safe                                           |
| `ARCALS_GUARDIAN`            | Address allowed to pause Mint                             |
| `ARCALS_TREASURY_OWNER`      | Owner of `RevenueTreasury`                                |
| `ARCALS_LAUNCH_AUTHORITY`    | Address allowed to activate conversions                   |
| `ARCALS_RESERVE_RECIPIENT`   | Safe that receives the reserved IDs                       |
| `ARCALS_EPOCH_PUBLISHER`     | Address allowed to register epochs                        |
| `ARCALS_ISSUER_SIGNER`       | Challenge signer                                          |
| `ARCALS_VERIFIER_SIGNER`     | Work certificate signer                                   |
| `ARCALS_SIGNER_VERSION`      | Initial signer version (non-zero)                         |
| `ARCALS_WORK_GENESIS_TIME`   | Mint start: Unix time when epoch 0 becomes valid (future) |
| `ARCALS_DATASET_ROOT`        | Merkle root of the Pi dataset                             |
| `ARCALS_ALGORITHM_ID`        | RandomX algorithm identifier                              |
| `ARCALS_PARAMETER_DIGEST`    | RandomX parameter digest                                  |
| `ARCALS_TARGET`              | Initial proof-of-work target                              |

```sh
forge script script/DeployArcMainnet.s.sol \
  --rpc-url https://rpc.mainnet.arc.io \
  --broadcast --slow \
  --account <deployer>
```

## `DeployLocal.s.sol`

Deploys the same graph with the same variables (except the work configuration)
to a local or development chain, for example Anvil.
