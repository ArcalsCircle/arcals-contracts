// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";

import { ArcalsHashing } from "../src/shared/ArcalsHashing.sol";
import { ArcalsTypes } from "../src/shared/ArcalsTypes.sol";
import { PiProof } from "../src/shared/PiProof.sol";

contract EcdsaHarness {
    function recover(bytes32 digest, bytes calldata signature) external pure returns (address) {
        return ECDSA.recover(digest, signature);
    }
}

contract ProtocolVectorsTest is Test {
    string private fixture;
    EcdsaHarness private ecdsaHarness;

    function setUp() public {
        fixture = vm.readFile(
            string.concat(vm.projectRoot(), "/test/fixtures/golden/protocol-v1.json")
        );
        ecdsaHarness = new EcdsaHarness();
    }

    function testChallengeAndCertificateMatchGoldenVector() public view {
        uint256 chainId = _uint(".domain.input.chainId");
        address controller = vm.parseJsonAddress(fixture, ".domain.input.verifyingContract");
        ArcalsTypes.Challenge memory challenge = _challenge();

        assertEq(
            ArcalsHashing.domainSeparator(chainId, controller),
            vm.parseJsonBytes32(fixture, ".domain.separator")
        );
        assertEq(
            ArcalsHashing.computeChallengeInput(chainId, controller, challenge),
            challenge.challengeInput
        );
        bytes32 challengeHash = ArcalsHashing.hashChallenge(challenge);
        assertEq(challengeHash, vm.parseJsonBytes32(fixture, ".challenge.challengeHash"));
        assertEq(
            ArcalsHashing.typedDataDigest(
                ArcalsHashing.domainSeparator(chainId, controller), challengeHash
            ),
            vm.parseJsonBytes32(fixture, ".challenge.typedDataDigest")
        );

        ArcalsTypes.WorkCertificate memory certificate = _certificate();
        bytes32 certificateHash = ArcalsHashing.hashWorkCertificate(certificate);
        assertEq(certificateHash, vm.parseJsonBytes32(fixture, ".certificate.certificateHash"));
        bytes32 receiptHash = ArcalsHashing.typedDataDigest(
            ArcalsHashing.domainSeparator(chainId, controller), certificateHash
        );
        assertEq(receiptHash, vm.parseJsonBytes32(fixture, ".certificate.receiptHash"));
    }

    function testWorkConfigEpochAndRandomXInputMatchGoldenVector() public view {
        ArcalsTypes.WorkConfigV1 memory config = ArcalsTypes.WorkConfigV1({
            protocolVersion: uint32(_uint(".workConfig.input.protocolVersion")),
            algorithmId: vm.parseJsonBytes32(fixture, ".workConfig.input.algorithmId"),
            parameterDigest: vm.parseJsonBytes32(fixture, ".workConfig.input.parameterDigest"),
            epochSeconds: uint64(_uint(".workConfig.input.epochSeconds")),
            keyLeadSeconds: uint64(_uint(".workConfig.input.keyLeadSeconds")),
            maxChallengeTtl: uint64(_uint(".workConfig.input.maxChallengeTtl")),
            maxCertificateTtl: uint64(_uint(".workConfig.input.maxCertificateTtl")),
            target: _uint(".workConfig.input.target"),
            effectiveEpoch: uint64(_uint(".workConfig.input.effectiveEpoch"))
        });
        assertEq(
            ArcalsHashing.hashWorkConfig(config),
            vm.parseJsonBytes32(fixture, ".workConfig.configDigest")
        );

        assertEq(
            ArcalsHashing.deriveEpochKey(
                _uint(".domain.input.chainId"),
                vm.parseJsonAddress(fixture, ".domain.input.verifyingContract"),
                uint64(_uint(".epoch.epochId")),
                uint64(_uint(".epoch.anchorBlockNumber")),
                vm.parseJsonBytes32(fixture, ".epoch.anchorBlockHash")
            ),
            vm.parseJsonBytes32(fixture, ".epoch.epochKey")
        );

        bytes memory input = ArcalsHashing.randomXInput(
            vm.parseJsonBytes32(fixture, ".challenge.input.challengeInput"),
            uint64(_uint(".randomx.workNonce"))
        );
        assertEq(input.length, 40);
        assertEq(input, vm.parseJsonBytes(fixture, ".randomx.inputBytes"));
    }

    function testPiVectorsMatchAtFirstMiddleAndLastIds() public view {
        _assertPiVector(".pi.first");
        _assertPiVector(".pi.middle");
        _assertPiVector(".pi.last");
        assertEq(
            PiProof.emptyLeaf(_uint(".pi.padding.index")),
            vm.parseJsonBytes32(fixture, ".pi.padding.emptyLeaf")
        );
        assertEq(
            PiProof.node(
                0x3333333333333333333333333333333333333333333333333333333333333333,
                0x4444444444444444444444444444444444444444444444444444444444444444
            ),
            vm.parseJsonBytes32(fixture, ".pi.nodeSample")
        );
    }

    function testPiRejectsInvalidEncodingLengthAndDirection() public view {
        bytes memory packed = vm.parseJsonBytes(fixture, ".pi.middle.packedDigits");
        bytes32[] memory proof = vm.parseJsonBytes32Array(fixture, ".pi.middle.proof");
        bytes32 expectedRoot = vm.parseJsonBytes32(fixture, ".pi.middle.root");

        bytes memory invalidNibble = bytes.concat(packed);
        invalidNibble[0] = 0xfa;
        assertFalse(PiProof.isValidPackedDigits(invalidNibble));

        bytes memory shortDigits = new bytes(179);
        assertFalse(PiProof.isValidPackedDigits(shortDigits));

        (proof[0], proof[1]) = (proof[1], proof[0]);
        assertFalse(PiProof.verify(500_000, packed, proof, expectedRoot));
    }

    function testRuntimeSignatureRejectsHighSAndBadV() public {
        Vm.Wallet memory signer = vm.createWallet("runtime issuer");
        bytes32 digest = vm.parseJsonBytes32(fixture, ".challenge.typedDataDigest");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signer.privateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);
        assertEq(ecdsaHarness.recover(digest, signature), signer.addr);

        uint256 curveOrder = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 highS = bytes32(curveOrder - uint256(s));
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, highS));
        ecdsaHarness.recover(digest, abi.encodePacked(r, highS, v));

        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        ecdsaHarness.recover(digest, abi.encodePacked(r, s, uint8(29)));
    }

    function testCanonicalAmounts() public view {
        assertEq(_uint(".amounts.mintFeeNative"), 0.1 ether);
        assertEq(_uint(".amounts.unit"), 360 ether);
    }

    function _assertPiVector(string memory base) private view {
        uint256 id = _uint(string.concat(base, ".id"));
        bytes memory packed = vm.parseJsonBytes(fixture, string.concat(base, ".packedDigits"));
        bytes32 contentHash = vm.parseJsonBytes32(fixture, string.concat(base, ".contentHash"));
        bytes32[] memory proof = vm.parseJsonBytes32Array(fixture, string.concat(base, ".proof"));
        bytes32 root = vm.parseJsonBytes32(fixture, string.concat(base, ".root"));

        assertTrue(PiProof.isValidPackedDigits(packed));
        assertEq(PiProof.contentHash(packed), contentHash);
        assertEq(
            PiProof.leaf(id, contentHash),
            vm.parseJsonBytes32(fixture, string.concat(base, ".leaf"))
        );
        assertEq(PiProof.rootFromProof(id, contentHash, proof), root);
        assertTrue(PiProof.verify(id, packed, proof, root));
        (uint256 startDigit, uint256 endDigit) = PiProof.piRange(id);
        assertEq(startDigit, _uint(string.concat(base, ".range.startDigit")));
        assertEq(endDigit, _uint(string.concat(base, ".range.endDigit")));
    }

    function _challenge() private view returns (ArcalsTypes.Challenge memory) {
        return ArcalsTypes.Challenge({
            protocolVersion: uint32(_uint(".challenge.input.protocolVersion")),
            configDigest: vm.parseJsonBytes32(fixture, ".challenge.input.configDigest"),
            challengeId: vm.parseJsonBytes32(fixture, ".challenge.input.challengeId"),
            epochId: uint64(_uint(".challenge.input.epochId")),
            minter: vm.parseJsonAddress(fixture, ".challenge.input.minter"),
            mintNonce: _uint(".challenge.input.mintNonce"),
            challengeInput: vm.parseJsonBytes32(fixture, ".challenge.input.challengeInput"),
            mintFee: _uint(".challenge.input.mintFee"),
            validAfter: uint64(_uint(".challenge.input.validAfter")),
            expiresAt: uint64(_uint(".challenge.input.expiresAt")),
            signerVersion: uint64(_uint(".challenge.input.signerVersion"))
        });
    }

    function _certificate() private view returns (ArcalsTypes.WorkCertificate memory) {
        return ArcalsTypes.WorkCertificate({
            protocolVersion: uint32(_uint(".certificate.input.protocolVersion")),
            challengeHash: vm.parseJsonBytes32(fixture, ".certificate.input.challengeHash"),
            workNonce: uint64(_uint(".certificate.input.workNonce")),
            randomxHash: vm.parseJsonBytes32(fixture, ".certificate.input.randomxHash"),
            issuedAt: uint64(_uint(".certificate.input.issuedAt")),
            expiresAt: uint64(_uint(".certificate.input.expiresAt")),
            signerVersion: uint64(_uint(".certificate.input.signerVersion"))
        });
    }

    function _uint(string memory path) private view returns (uint256) {
        return vm.parseUint(vm.parseJsonString(fixture, path));
    }
}
