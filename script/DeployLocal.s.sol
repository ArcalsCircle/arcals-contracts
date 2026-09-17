// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Script } from "forge-std/Script.sol";

import { ArcalsDeploymentFactory } from "../src/ArcalsDeploymentFactory.sol";
import { MintController } from "../src/MintController.sol";

/// @notice Local/testnet deployment entry. It never contains production addresses or secrets.
contract DeployLocal is Script {
    error InvalidLocalConfiguration();

    function run() external returns (ArcalsDeploymentFactory factory, address[8] memory deployed) {
        address deployer = msg.sender;
        uint256 signerVersionInput = vm.envUint("ARCALS_SIGNER_VERSION");
        uint256 workGenesisInput = vm.envUint("ARCALS_WORK_GENESIS_TIME");
        if (
            signerVersionInput == 0 || signerVersionInput > type(uint64).max
                || workGenesisInput == 0 || workGenesisInput > type(uint64).max
        ) revert InvalidLocalConfiguration();
        ArcalsDeploymentFactory.Expectations memory expected = ArcalsDeploymentFactory.Expectations({
            managementMultisig: vm.envAddress("ARCALS_MANAGEMENT_MULTISIG"),
            guardian: vm.envAddress("ARCALS_GUARDIAN"),
            treasuryOwner: vm.envAddress("ARCALS_TREASURY_OWNER"),
            launchAuthority: vm.envAddress("ARCALS_LAUNCH_AUTHORITY"),
            epochPublisher: vm.envAddress("ARCALS_EPOCH_PUBLISHER"),
            // The explicit bound above makes the uint64 cast lossless.
            // forge-lint: disable-next-line(unsafe-typecast)
            workGenesisTime: uint64(workGenesisInput),
            issuerSigner: vm.envAddress("ARCALS_ISSUER_SIGNER"),
            verifierSigner: vm.envAddress("ARCALS_VERIFIER_SIGNER"),
            // The explicit bound above makes the uint64 cast lossless.
            // forge-lint: disable-next-line(unsafe-typecast)
            signerVersion: uint64(signerVersionInput),
            datasetRoot: vm.envBytes32("ARCALS_DATASET_ROOT"),
            reserveRecipient: vm.envAddress("ARCALS_RESERVE_RECIPIENT")
        });

        vm.startBroadcast();
        factory = new ArcalsDeploymentFactory(deployer);
        bytes[] memory creationCodes = _creationCodes(factory, expected);
        deployed = factory.deploy(creationCodes, expected);
        vm.stopBroadcast();
    }

    function _creationCodes(
        ArcalsDeploymentFactory factory,
        ArcalsDeploymentFactory.Expectations memory expected
    ) private view returns (bytes[] memory codes) {
        address[7] memory predicted;
        for (uint256 index = 0; index < predicted.length; ++index) {
            predicted[index] = factory.predictChildAddress(index + 1);
        }
        // Governance is the management account itself; there is no timelock.
        address governance = expected.managementMultisig;

        bytes memory initialization = abi.encodeCall(
            MintController.initialize,
            (
                predicted[2],
                governance,
                expected.guardian,
                expected.epochPublisher,
                expected.workGenesisTime,
                expected.issuerSigner,
                expected.verifierSigner,
                expected.signerVersion
            )
        );
        codes = new bytes[](7);
        codes[0] = vm.getCode("MintController.sol:MintController");
        codes[1] = _withArgs(
            "TransparentUpgradeableProxy.sol:TransparentUpgradeableProxy",
            abi.encode(predicted[0], governance, initialization)
        );
        codes[2] = _withArgs(
            "ArcalsCore.sol:ArcalsCore",
            abi.encode(
                predicted[1],
                predicted[3],
                predicted[4],
                predicted[5],
                predicted[6],
                expected.guardian,
                governance,
                expected.reserveRecipient
            )
        );
        codes[3] = _withArgs(
            "ARCLBase.sol:ARCLBase", abi.encode(predicted[2], predicted[4], predicted[5])
        );
        codes[4] = _withArgs(
            "ArcalMirror.sol:ArcalMirror",
            abi.encode(predicted[2], predicted[3], predicted[5], expected.datasetRoot, governance)
        );
        codes[5] = _withArgs(
            "ArcalsVault.sol:ArcalsVault",
            abi.encode(
                predicted[2], predicted[3], predicted[4], expected.launchAuthority, governance
            )
        );
        codes[6] = _withArgs(
            "RevenueTreasury.sol:RevenueTreasury", abi.encode(predicted[2], expected.treasuryOwner)
        );
    }

    function _withArgs(string memory artifact, bytes memory arguments)
        private
        view
        returns (bytes memory)
    {
        return abi.encodePacked(vm.getCode(artifact), arguments);
    }
}
