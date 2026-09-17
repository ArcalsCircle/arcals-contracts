// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Script, console } from "forge-std/Script.sol";

import { ArcalsContentRegistrar } from "../src/ArcalsContentRegistrar.sol";
import { ArcalsCore } from "../src/ArcalsCore.sol";
import { ArcalsDeploymentFactory } from "../src/ArcalsDeploymentFactory.sol";
import { ArcalsMetadataRenderer } from "../src/ArcalsMetadataRenderer.sol";
import { ArcalMirror } from "../src/ArcalMirror.sol";
import { MintController } from "../src/MintController.sol";
import { ArcalsDeploymentPlan } from "../src/deployment/ArcalsDeploymentPlan.sol";
import { ArcalsTypes } from "../src/shared/ArcalsTypes.sol";

/// @notice Arc Mainnet production deployment. The deployer EOA only creates contracts. There is
///         no timelock: the launch governance actions (work config, renderer, Mint resume)
///         are printed as direct calls for the management Safe to execute immediately.
/// @dev Required env: ARCALS_MANAGEMENT_MULTISIG, ARCALS_GUARDIAN, ARCALS_TREASURY_OWNER,
///      ARCALS_LAUNCH_AUTHORITY, ARCALS_RESERVE_RECIPIENT (all Safe contracts), ARCALS_EPOCH_PUBLISHER,
///      ARCALS_ISSUER_SIGNER, ARCALS_VERIFIER_SIGNER, ARCALS_SIGNER_VERSION,
///      ARCALS_WORK_GENESIS_TIME, ARCALS_DATASET_ROOT (production Pi dataset root), and the initial work
///      config ARCALS_ALGORITHM_ID, ARCALS_PARAMETER_DIGEST, ARCALS_TARGET.
contract DeployArcMainnet is Script {
    uint256 private constant ARC_MAINNET_CHAIN_ID = 5042;
    // Indices into ArcalsDeploymentFactory.deploy's returned address[8].
    uint256 private constant CONTROLLER_PROXY = 1;
    uint256 private constant CORE = 3;
    uint256 private constant MIRROR = 5;

    error NotArcMainnet(uint256 chainId);
    error InvalidProductionConfiguration();
    error CreationCodeHashMismatch(uint256 index);

    function run()
        external
        returns (
            ArcalsDeploymentFactory factory,
            address[8] memory deployed,
            ArcalsContentRegistrar registrar,
            ArcalsMetadataRenderer renderer
        )
    {
        if (block.chainid != ARC_MAINNET_CHAIN_ID) {
            revert NotArcMainnet(block.chainid);
        }
        ArcalsDeploymentFactory.Expectations memory expected = _expectations();
        ArcalsTypes.WorkConfigV1 memory config = _initialConfig();

        vm.startBroadcast();
        factory = new ArcalsDeploymentFactory(msg.sender);
        bytes[] memory codes = ArcalsDeploymentPlan.creationCodes(factory, expected);
        deployed = factory.deploy(codes, expected);
        registrar = new ArcalsContentRegistrar(deployed[MIRROR]);
        renderer = new ArcalsMetadataRenderer(deployed[MIRROR]);
        vm.stopBroadcast();

        bytes32[7] memory planned = ArcalsDeploymentPlan.creationCodeHashes(factory, expected);
        for (uint256 index = 0; index < planned.length; ++index) {
            if (factory.creationCodeHashes(index) != planned[index]) {
                revert CreationCodeHashMismatch(index);
            }
        }
        if (
            registrar.mirror() != deployed[MIRROR] || address(renderer.mirror()) != deployed[MIRROR]
        ) {
            revert InvalidProductionConfiguration();
        }

        _printGovernanceCalls(expected.managementMultisig, deployed, config, address(renderer));
    }

    function _expectations()
        private
        view
        returns (ArcalsDeploymentFactory.Expectations memory expected)
    {
        uint256 signerVersion = vm.envUint("ARCALS_SIGNER_VERSION");
        uint256 genesis = vm.envUint("ARCALS_WORK_GENESIS_TIME");
        if (
            signerVersion == 0 || signerVersion > type(uint64).max || genesis <= block.timestamp
                || genesis > type(uint64).max
        ) revert InvalidProductionConfiguration();
        expected = ArcalsDeploymentFactory.Expectations({
            managementMultisig: vm.envAddress("ARCALS_MANAGEMENT_MULTISIG"),
            guardian: vm.envAddress("ARCALS_GUARDIAN"),
            treasuryOwner: vm.envAddress("ARCALS_TREASURY_OWNER"),
            launchAuthority: vm.envAddress("ARCALS_LAUNCH_AUTHORITY"),
            epochPublisher: vm.envAddress("ARCALS_EPOCH_PUBLISHER"),
            // Bounds checked above make both casts lossless.
            // forge-lint: disable-next-line(unsafe-typecast)
            workGenesisTime: uint64(genesis),
            issuerSigner: vm.envAddress("ARCALS_ISSUER_SIGNER"),
            verifierSigner: vm.envAddress("ARCALS_VERIFIER_SIGNER"),
            // forge-lint: disable-next-line(unsafe-typecast)
            signerVersion: uint64(signerVersion),
            datasetRoot: vm.envBytes32("ARCALS_DATASET_ROOT"),
            reserveRecipient: vm.envAddress("ARCALS_RESERVE_RECIPIENT")
        });
    }

    function _initialConfig() private view returns (ArcalsTypes.WorkConfigV1 memory config) {
        config = ArcalsTypes.WorkConfigV1({
            protocolVersion: 1,
            algorithmId: vm.envBytes32("ARCALS_ALGORITHM_ID"),
            parameterDigest: vm.envBytes32("ARCALS_PARAMETER_DIGEST"),
            epochSeconds: 1 days,
            keyLeadSeconds: 15 minutes,
            maxChallengeTtl: 20 minutes,
            maxCertificateTtl: 5 minutes,
            target: vm.envUint("ARCALS_TARGET"),
            effectiveEpoch: 0
        });
        if (config.target == 0 || config.target == type(uint256).max) {
            revert InvalidProductionConfiguration();
        }
    }

    function _printGovernanceCalls(
        address managementMultisig,
        address[8] memory deployed,
        ArcalsTypes.WorkConfigV1 memory config,
        address renderer
    ) private pure {
        console.log("Send from the management Safe", managementMultisig);
        console.log("1. registerWorkConfig on Controller", deployed[CONTROLLER_PROXY]);
        console.logBytes(abi.encodeCall(MintController.registerWorkConfig, (config)));
        console.log("2. setMetadataRenderer on Mirror", deployed[MIRROR]);
        console.logBytes(abi.encodeCall(ArcalMirror.setMetadataRenderer, (renderer)));
        console.log("3. resumeMint on Core (after the first Epoch is registered)", deployed[CORE]);
        console.logBytes(abi.encodeCall(ArcalsCore.resumeMint, ()));
        console.log(
            "Reserve: call Core.mintReserve(500) 20 times from any funded account", deployed[CORE]
        );
    }
}
