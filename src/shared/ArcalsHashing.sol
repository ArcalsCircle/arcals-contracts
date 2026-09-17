// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ArcalsTypes } from "./ArcalsTypes.sol";

library ArcalsHashing {
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 internal constant NAME_HASH = keccak256("ArcalsMint");
    bytes32 internal constant VERSION_HASH = keccak256("1");
    bytes32 internal constant CHALLENGE_TYPEHASH = keccak256(
        "Challenge(uint32 protocolVersion,bytes32 configDigest,bytes32 challengeId,uint64 epochId,address minter,uint256 mintNonce,bytes32 challengeInput,uint256 mintFee,uint64 validAfter,uint64 expiresAt,uint64 signerVersion)"
    );
    bytes32 internal constant WORK_CERTIFICATE_TYPEHASH = keccak256(
        "WorkCertificate(uint32 protocolVersion,bytes32 challengeHash,uint64 workNonce,bytes32 randomxHash,uint64 issuedAt,uint64 expiresAt,uint64 signerVersion)"
    );
    bytes32 internal constant WORK_CONFIG_TYPEHASH = keccak256(
        "WorkConfigV1(uint32 protocolVersion,bytes32 algorithmId,bytes32 parameterDigest,uint64 epochSeconds,uint64 keyLeadSeconds,uint64 maxChallengeTtl,uint64 maxCertificateTtl,uint256 target,uint64 effectiveEpoch)"
    );
    bytes32 internal constant CHALLENGE_DOMAIN = keccak256("ARCALS_WORK_INPUT_V1");
    bytes32 internal constant EPOCH_KEY_DOMAIN = keccak256("ARCALS_RANDOMX_EPOCH_V1");

    function domainSeparator(uint256 chainId, address verifyingContract)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(EIP712_DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, chainId, verifyingContract)
        );
    }

    function computeChallengeInput(
        uint256 chainId,
        address controllerProxy,
        ArcalsTypes.Challenge memory challenge
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                CHALLENGE_DOMAIN,
                chainId,
                controllerProxy,
                challenge.challengeId,
                challenge.epochId,
                challenge.minter,
                challenge.mintNonce,
                challenge.configDigest
            )
        );
    }

    function hashChallenge(ArcalsTypes.Challenge memory challenge) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                CHALLENGE_TYPEHASH,
                challenge.protocolVersion,
                challenge.configDigest,
                challenge.challengeId,
                challenge.epochId,
                challenge.minter,
                challenge.mintNonce,
                challenge.challengeInput,
                challenge.mintFee,
                challenge.validAfter,
                challenge.expiresAt,
                challenge.signerVersion
            )
        );
    }

    function hashWorkCertificate(ArcalsTypes.WorkCertificate memory certificate)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                WORK_CERTIFICATE_TYPEHASH,
                certificate.protocolVersion,
                certificate.challengeHash,
                certificate.workNonce,
                certificate.randomxHash,
                certificate.issuedAt,
                certificate.expiresAt,
                certificate.signerVersion
            )
        );
    }

    function typedDataDigest(bytes32 domain, bytes32 structHash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(hex"1901", domain, structHash));
    }

    function hashWorkConfig(ArcalsTypes.WorkConfigV1 memory config)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                WORK_CONFIG_TYPEHASH,
                config.protocolVersion,
                config.algorithmId,
                config.parameterDigest,
                config.epochSeconds,
                config.keyLeadSeconds,
                config.maxChallengeTtl,
                config.maxCertificateTtl,
                config.target,
                config.effectiveEpoch
            )
        );
    }

    function deriveEpochKey(
        uint256 chainId,
        address controllerProxy,
        uint64 epochId,
        uint64 anchorBlockNumber,
        bytes32 anchorBlockHash
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                EPOCH_KEY_DOMAIN,
                chainId,
                controllerProxy,
                epochId,
                anchorBlockNumber,
                anchorBlockHash
            )
        );
    }

    function randomXInput(bytes32 challengeInput, uint64 workNonce)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(challengeInput, reverseUint64(workNonce));
    }

    function reverseUint64(uint64 value) internal pure returns (uint64 reversed) {
        for (uint256 index = 0; index < 8; ++index) {
            // Only the low byte is selected on each iteration.
            // forge-lint: disable-next-line(unsafe-typecast)
            reversed = (reversed << 8) | uint8(value);
            value >>= 8;
        }
    }
}
