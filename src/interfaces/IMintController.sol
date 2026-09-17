// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ArcalsTypes } from "../shared/ArcalsTypes.sol";
import { IArcalsErrors } from "./IArcalsErrors.sol";

interface IMintController is IArcalsErrors {
    event WorkAccepted(
        bytes32 indexed receiptHash,
        bytes32 indexed challengeId,
        uint64 epochId,
        uint64 signerVersion,
        bytes32 configDigest
    );
    event SignersConfigured(
        address indexed issuerSigner, address indexed verifierSigner, uint64 signerVersion
    );
    event WorkConfigRegistered(bytes32 indexed configDigest, uint64 effectiveEpoch);
    event EpochRegistered(
        uint64 indexed epochId,
        bytes32 indexed configDigest,
        bytes32 epochKey,
        uint64 validFrom,
        uint64 validUntil,
        uint64 anchorBlockNumber,
        bytes32 anchorBlockHash
    );
    event EpochPublisherConfigured(address indexed epochPublisher);

    function mint(
        ArcalsTypes.Challenge calldata challenge,
        bytes calldata issuerSignature,
        ArcalsTypes.WorkCertificate calldata certificate,
        bytes calldata verifierSignature
    ) external payable returns (uint256 id);

    /// @notice Circle-compatible scalar ABI entry. `payload` is exactly
    /// abi.encode(challenge, issuerSignature, certificate, verifierSignature).
    function mintEncoded(bytes calldata payload) external payable returns (uint256 id);

    function pauseMint() external;
    function configureSigners(address issuerSigner, address verifierSigner, uint64 signerVersion)
        external;
    function configureEpochPublisher(address epochPublisher) external;
    function registerWorkConfig(ArcalsTypes.WorkConfigV1 calldata config)
        external
        returns (bytes32 configDigest);
    function registerEpoch(ArcalsTypes.EpochCommitment calldata epoch) external;
    function issuerSigner() external view returns (address);
    function verifierSigner() external view returns (address);
    function signerVersion() external view returns (uint64);
    function core() external view returns (address);
    function governance() external view returns (address);
    function guardian() external view returns (address);
    function epochPublisher() external view returns (address);
    function workGenesisTime() external view returns (uint64);
    function workConfig(bytes32 configDigest)
        external
        view
        returns (ArcalsTypes.WorkConfigV1 memory config, bool exists);
    function activeWorkConfigDigest(uint64 epochId)
        external
        view
        returns (bytes32 configDigest, bool exists);
    function workConfigCount() external view returns (uint256);
    function epoch(uint64 epochId)
        external
        view
        returns (ArcalsTypes.EpochCommitment memory commitment, bool exists);
}
