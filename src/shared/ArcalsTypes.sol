// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

library ArcalsTypes {
    struct Challenge {
        uint32 protocolVersion;
        bytes32 configDigest;
        bytes32 challengeId;
        uint64 epochId;
        address minter;
        uint256 mintNonce;
        bytes32 challengeInput;
        uint256 mintFee;
        uint64 validAfter;
        uint64 expiresAt;
        uint64 signerVersion;
    }

    struct WorkCertificate {
        uint32 protocolVersion;
        bytes32 challengeHash;
        uint64 workNonce;
        bytes32 randomxHash;
        uint64 issuedAt;
        uint64 expiresAt;
        uint64 signerVersion;
    }

    struct WorkConfigV1 {
        uint32 protocolVersion;
        bytes32 algorithmId;
        bytes32 parameterDigest;
        uint64 epochSeconds;
        uint64 keyLeadSeconds;
        uint64 maxChallengeTtl;
        uint64 maxCertificateTtl;
        uint256 target;
        uint64 effectiveEpoch;
    }

    struct EpochCommitment {
        uint64 epochId;
        bytes32 configDigest;
        bytes32 epochKey;
        uint64 validFrom;
        uint64 validUntil;
        uint64 anchorBlockNumber;
        bytes32 anchorBlockHash;
    }
}
