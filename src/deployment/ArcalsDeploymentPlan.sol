// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import { ARCLBase } from "../ARCLBase.sol";
import { ArcalMirror } from "../ArcalMirror.sol";
import { ArcalsCore } from "../ArcalsCore.sol";
import { ArcalsDeploymentFactory } from "../ArcalsDeploymentFactory.sol";
import { ArcalsVault } from "../ArcalsVault.sol";
import { MintController } from "../MintController.sol";
import { RevenueTreasury } from "../RevenueTreasury.sol";

/// @notice Canonical constructor-code builder for the factory's fixed CREATE order.
library ArcalsDeploymentPlan {
    function creationCodes(
        ArcalsDeploymentFactory factory,
        ArcalsDeploymentFactory.Expectations memory expected
    ) internal view returns (bytes[] memory codes) {
        return _creationCodes(factory, expected);
    }

    /// @notice Recomputes the creation-code hashes a correct deployment must have recorded.
    function creationCodeHashes(
        ArcalsDeploymentFactory factory,
        ArcalsDeploymentFactory.Expectations memory expected
    ) internal view returns (bytes32[7] memory hashes) {
        bytes[] memory codes = _creationCodes(factory, expected);
        for (uint256 index = 0; index < codes.length; ++index) {
            hashes[index] = keccak256(codes[index]);
        }
    }

    /// @dev CREATE order: controller implementation, controller proxy, core, base, mirror,
    ///      vault, treasury. Governance is the management multisig itself.
    function _creationCodes(
        ArcalsDeploymentFactory factory,
        ArcalsDeploymentFactory.Expectations memory expected
    ) private view returns (bytes[] memory codes) {
        address[7] memory predicted;
        for (uint256 index = 0; index < predicted.length; ++index) {
            predicted[index] = factory.predictChildAddress(index + 1);
        }
        address governance = expected.managementMultisig;

        codes = new bytes[](7);
        codes[0] = type(MintController).creationCode;
        codes[1] = _proxyCode(predicted[0], governance, predicted[2], expected);
        codes[2] = _coreCode(predicted, expected.guardian, governance, expected.reserveRecipient);
        codes[3] = abi.encodePacked(
            type(ARCLBase).creationCode, abi.encode(predicted[2], predicted[4], predicted[5])
        );
        codes[4] = abi.encodePacked(
            type(ArcalMirror).creationCode,
            abi.encode(predicted[2], predicted[3], predicted[5], expected.datasetRoot, governance)
        );
        codes[5] = abi.encodePacked(
            type(ArcalsVault).creationCode,
            abi.encode(
                predicted[2], predicted[3], predicted[4], expected.launchAuthority, governance
            )
        );
        codes[6] = abi.encodePacked(
            type(RevenueTreasury).creationCode, abi.encode(predicted[2], expected.treasuryOwner)
        );
    }

    function _proxyCode(
        address implementation,
        address governance,
        address core,
        ArcalsDeploymentFactory.Expectations memory expected
    ) private pure returns (bytes memory) {
        bytes memory initialization =
            abi.encodeCall(
                MintController.initialize,
                (
                    core,
                    governance,
                    expected.guardian,
                    expected.epochPublisher,
                    expected.workGenesisTime,
                    expected.issuerSigner,
                    expected.verifierSigner,
                    expected.signerVersion
                )
            );
        return abi.encodePacked(
            type(TransparentUpgradeableProxy).creationCode,
            abi.encode(implementation, governance, initialization)
        );
    }

    function _coreCode(
        address[7] memory predicted,
        address guardian,
        address governance,
        address reserveRecipient
    ) private pure returns (bytes memory) {
        return abi.encodePacked(
            type(ArcalsCore).creationCode,
            abi.encode(
                predicted[1],
                predicted[3],
                predicted[4],
                predicted[5],
                predicted[6],
                guardian,
                governance,
                reserveRecipient
            )
        );
    }
}
