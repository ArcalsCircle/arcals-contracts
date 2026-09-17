// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { Vm } from "forge-std/Vm.sol";

import { ArcalsTestBase } from "./ArcalsContracts.t.sol";
import { ArcalMirror } from "../src/ArcalMirror.sol";
import { ArcalsDeploymentFactory } from "../src/ArcalsDeploymentFactory.sol";
import { ArcalsVault } from "../src/ArcalsVault.sol";
import { ArcalsDeploymentPlan } from "../src/deployment/ArcalsDeploymentPlan.sol";
import { IARCLBase } from "../src/interfaces/IARCLBase.sol";
import { IArcalsVault } from "../src/interfaces/IArcalsVault.sol";
import { IArcalsErrors } from "../src/interfaces/IArcalsErrors.sol";
import { IArcalsMetadataRenderer } from "../src/interfaces/IArcalsMetadataRenderer.sol";
import { ArcalsHashing } from "../src/shared/ArcalsHashing.sol";
import { ArcalsTypes } from "../src/shared/ArcalsTypes.sol";

contract StaticRenderer is IArcalsMetadataRenderer {
    string private _token;
    string private _collection;

    constructor(string memory token_, string memory collection_) {
        _token = token_;
        _collection = collection_;
    }

    function tokenURI(uint256) external view returns (string memory) {
        return _token;
    }

    function contractURI() external view returns (string memory) {
        return _collection;
    }
}

contract RevertingRenderer is IArcalsMetadataRenderer {
    function tokenURI(uint256) external pure returns (string memory) {
        revert("RENDER_FAILED");
    }

    function contractURI() external pure returns (string memory) {
        revert("RENDER_FAILED");
    }
}

contract GarbageRenderer {
    fallback() external {
        assembly ("memory-safe") {
            mstore(0, 0x40)
            mstore(0x20, 0xffffffffffffffff)
            mstore(0x40, 0x1234)
            return(0, 0x60)
        }
    }
}

contract GasBurnerRenderer {
    fallback() external {
        uint256 counter;
        while (true) {
            ++counter;
        }
    }
}

contract HugeRenderer {
    fallback() external {
        assembly ("memory-safe") {
            let size := 300000
            mstore(0, 0x20)
            mstore(0x20, size)
            return(0, add(size, 0x40))
        }
    }
}

contract BurnThenValidRenderer {
    uint256 public immutable responseBytes;
    bool public immutable burnFirst;

    constructor(uint256 responseBytes_, bool burnFirst_) {
        responseBytes = responseBytes_;
        burnFirst = burnFirst_;
    }

    fallback() external {
        uint256 size = responseBytes;
        if (burnFirst) {
            while (gasleft() > 200_000) { }
        }
        assembly ("memory-safe") {
            mstore(0, 0x20)
            mstore(0x20, size)
            let cursor := 0x40
            let end := add(0x40, size)
            for { } lt(cursor, end) { cursor := add(cursor, 0x20) } {
                mstore(cursor, 0x4141414141414141414141414141414141414141414141414141414141414141)
            }
            return(0, add(0x40, size))
        }
    }
}

contract BackdooredVault is ArcalsVault {
    constructor(address c, address b, address m, address l, address g)
        ArcalsVault(c, b, m, l, g)
    { }

    function drain(address to) external {
        IARCLBase(base).vaultRelease(to);
    }
}

/// @notice Regression tests for access control, deployment integrity and conversion safety.
contract SecurityRegressionsTest is ArcalsTestBase {
    using stdJson for string;

    bytes internal constant JSON_PREFIX = "data:application/json;base64,";

    // ---------------------------------------------------------------- metadata (finding 1)

    function testBuiltinTokenUriDescribesTokenAndTracksContentAndForm() public {
        address holder = makeAddr("metadata-holder");
        (uint256 id,) = _mint(holder);

        string memory pending = _decodeJson(mirror.tokenURI(id));
        assertEq(pending.readString(".name"), "Arcal #1");
        assertEq(pending.readUint(".pi_digit_start"), 1);
        assertEq(pending.readUint(".pi_digit_end"), 360);
        assertFalse(pending.readBool(".content_registered"));
        assertEq(pending.readString(".content_hash"), "");
        assertFalse(pending.readBool(".in_vault"));
        assertEq(pending.readUint(".attributes[0].value"), 1);
        assertEq(pending.readUint(".attributes[1].value"), 360);
        assertFalse(vm.keyExistsJson(pending, ".attributes[2]"), "only fixed Pi traits");
        assertTrue(_startsWith(bytes(pending.readString(".image")), "data:image/svg+xml;base64,"));

        _register(id);
        _activate();
        vm.prank(holder);
        mirror.approve(address(vault), id);
        vm.recordLogs();
        vm.prank(holder);
        vault.liquify(id, holder, uint64(block.timestamp));
        assertTrue(_sawMetadataUpdate(id), "liquify refreshes metadata");

        string memory banked = _decodeJson(mirror.tokenURI(id));
        assertTrue(banked.readBool(".content_registered"));
        assertTrue(banked.readBool(".in_vault"));
        assertEq(banked.readBytes32(".content_hash"), mirror.contentHash(id), "content hash");

        vm.prank(holder);
        base.approve(address(vault), UNIT);
        vm.recordLogs();
        vm.prank(holder);
        vault.reform(holder, id, uint64(block.timestamp));
        assertTrue(_sawMetadataUpdate(id), "reform refreshes metadata");
        assertFalse(_decodeJson(mirror.tokenURI(id)).readBool(".in_vault"));

        string memory collection = _decodeJson(mirror.contractURI());
        assertEq(collection.readString(".name"), "Arcals");
        _assertConservation();
    }

    function testTokenUriRevertsForUnmintedId() public {
        vm.expectRevert();
        mirror.tokenURI(1);
    }

    function testRendererIsGovernanceOnlyAndFallsBackWhenBrokenOrEmpty() public {
        (uint256 id,) = _mint(makeAddr("renderer-holder"));
        string memory builtin = mirror.tokenURI(id);
        StaticRenderer custom = new StaticRenderer("ipfs://token", "ipfs://collection");

        vm.expectRevert(abi.encodeWithSelector(IArcalsErrors.Unauthorized.selector, guardian));
        vm.prank(guardian);
        mirror.setMetadataRenderer(address(custom));

        address noCode = makeAddr("renderer-typo");
        vm.expectRevert(abi.encodeWithSelector(IArcalsErrors.Unauthorized.selector, noCode));
        vm.prank(management);
        mirror.setMetadataRenderer(noCode);

        vm.recordLogs();
        vm.prank(management);
        mirror.setMetadataRenderer(address(custom));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool sawBatchUpdate;
        for (uint256 index = 0; index < logs.length; ++index) {
            if (logs[index].topics[0] == keccak256("BatchMetadataUpdate(uint256,uint256)")) {
                sawBatchUpdate = true;
            }
        }
        assertTrue(sawBatchUpdate, "ERC-4906 batch refresh");
        assertEq(mirror.tokenURI(id), "ipfs://token");
        assertEq(mirror.contractURI(), "ipfs://collection");

        StaticRenderer empty = new StaticRenderer("", "");
        vm.prank(management);
        mirror.setMetadataRenderer(address(empty));
        assertEq(mirror.tokenURI(id), builtin);

        RevertingRenderer broken = new RevertingRenderer();
        vm.prank(management);
        mirror.setMetadataRenderer(address(broken));
        assertEq(mirror.tokenURI(id), builtin);
        assertTrue(bytes(mirror.contractURI()).length > JSON_PREFIX.length);

        vm.prank(management);
        mirror.setMetadataRenderer(address(0));
        assertEq(mirror.tokenURI(id), builtin);
    }

    function testHostileRenderersCannotBreakTokenUriFallback() public {
        address holder = makeAddr("hostile-renderer-holder");
        (uint256 id,) = _mint(holder);
        _register(id);
        _activate();
        vm.prank(holder);
        mirror.approve(address(vault), id);
        vm.prank(holder);
        vault.liquify(id, holder, uint64(block.timestamp));

        uint256 before = gasleft();
        string memory builtin = mirror.tokenURI(id);
        uint256 builtinGas = before - gasleft();
        emit log_named_uint("built-in tokenURI gas", builtinGas);
        assertLt(builtinGas * 2, mirror.RENDER_FALLBACK_GAS(), "fallback reserve has 2x margin");

        address[3] memory hostile = [
            address(new GarbageRenderer()),
            address(new GasBurnerRenderer()),
            address(new HugeRenderer())
        ];
        for (uint256 index = 0; index < hostile.length; ++index) {
            vm.prank(management);
            mirror.setMetadataRenderer(hostile[index]);
            assertEq(mirror.tokenURI{ gas: 30_000_000 }(id), builtin);
            assertTrue(bytes(mirror.contractURI{ gas: 30_000_000 }()).length > JSON_PREFIX.length);
        }
    }

    function testLargeValidRenderResponsesNeverRevertTokenUri() public {
        (uint256 id,) = _mint(makeAddr("large-render-holder"));
        string memory builtin = mirror.tokenURI(id);
        uint256[3] memory sizes = [uint256(16_384), 64_000, 255_936];
        uint256[4] memory callerGas =
            [uint256(1_300_000), uint256(5_000_000), uint256(12_000_000), uint256(50_000_000)];
        for (uint256 i = 0; i < sizes.length; ++i) {
            BurnThenValidRenderer burner = new BurnThenValidRenderer(sizes[i], true);
            vm.prank(management);
            mirror.setMetadataRenderer(address(burner));
            for (uint256 j = 0; j < callerGas.length; ++j) {
                (bool ok, bytes memory result) = address(mirror).staticcall{ gas: callerGas[j] }(
                    abi.encodeCall(mirror.tokenURI, (id))
                );
                assertTrue(ok, "tokenURI must not revert");
                string memory uri = abi.decode(result, (string));
                assertTrue(
                    bytes(uri).length == sizes[i]
                        || keccak256(bytes(uri)) == keccak256(bytes(builtin)),
                    "renderer output or built-in"
                );
            }
        }

        // An honest maximum-size response is returned in full without large copy costs.
        BurnThenValidRenderer honest = new BurnThenValidRenderer(255_936, false);
        vm.prank(management);
        mirror.setMetadataRenderer(address(honest));
        uint256 before = gasleft();
        string memory full = mirror.tokenURI{ gas: 30_000_000 }(id);
        emit log_named_uint("max-size render gas", before - gasleft());
        assertEq(bytes(full).length, 255_936);
    }

    function testRoyaltyIsOffByDefaultGovernanceOnlyAndCapped() public {
        (uint256 id,) = _mint(makeAddr("royalty-holder"));
        (address receiver, uint256 amount) = mirror.royaltyInfo(id, 100 ether);
        assertEq(receiver, address(0));
        assertEq(amount, 0);
        assertTrue(mirror.supportsInterface(0x2a55205a), "ERC-2981");
        assertTrue(mirror.supportsInterface(0x49064906), "ERC-4906");
        assertTrue(mirror.supportsInterface(0x80ac58cd), "ERC-721");
        assertTrue(mirror.supportsInterface(0x5b5e139f), "ERC-721 metadata");

        vm.expectRevert(abi.encodeWithSelector(IArcalsErrors.Unauthorized.selector, treasuryOwner));
        vm.prank(treasuryOwner);
        mirror.setDefaultRoyalty(address(treasury), 500);

        vm.expectRevert(abi.encodeWithSelector(ArcalMirror.RoyaltyTooHigh.selector, 1001, 1000));
        vm.prank(management);
        mirror.setDefaultRoyalty(address(treasury), 1001);

        address[6] memory protocolReceivers = [
            address(mirror),
            address(core),
            address(base),
            address(vault),
            address(controller),
            address(treasury)
        ];
        for (uint256 index = 0; index < protocolReceivers.length; ++index) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IArcalsErrors.Unauthorized.selector, protocolReceivers[index]
                )
            );
            vm.prank(management);
            mirror.setDefaultRoyalty(protocolReceivers[index], 500);
        }

        address royaltyReceiver = makeAddr("royalty-receiver");
        vm.prank(management);
        mirror.setDefaultRoyalty(royaltyReceiver, 500);
        (receiver, amount) = mirror.royaltyInfo(id, 100 ether);
        assertEq(receiver, royaltyReceiver);
        assertEq(amount, 5 ether);

        vm.prank(management);
        mirror.deleteDefaultRoyalty();
        (receiver, amount) = mirror.royaltyInfo(id, 100 ether);
        assertEq(receiver, address(0));
        assertEq(amount, 0);
    }

    // ------------------------------------------------------- role rotation (finding 3)

    function testGovernanceRotatesCompromisedGuardianOnCoreAndController() public {
        address newGuardian = makeAddr("new-guardian");
        vm.expectRevert(abi.encodeWithSelector(IArcalsErrors.Unauthorized.selector, guardian));
        vm.prank(guardian);
        core.setGuardian(guardian);

        assertEq(controller.guardian(), guardian);
        vm.prank(management);
        core.setGuardian(newGuardian);
        assertEq(core.guardian(), newGuardian);
        assertEq(controller.guardian(), newGuardian);

        vm.expectRevert(abi.encodeWithSelector(IArcalsErrors.Unauthorized.selector, guardian));
        vm.prank(guardian);
        core.pauseMint();
        vm.expectRevert(abi.encodeWithSelector(IArcalsErrors.Unauthorized.selector, guardian));
        vm.prank(guardian);
        controller.pauseMint();

        vm.prank(newGuardian);
        controller.pauseMint();
        assertTrue(core.mintPaused());

        vm.expectRevert(IArcalsErrors.ZeroAddress.selector);
        vm.prank(management);
        core.setGuardian(address(0));
    }

    function testGovernanceReplacesLaunchAuthorityOnlyBeforeActivation() public {
        address replacement = makeAddr("replacement-launch");
        vm.expectRevert(
            abi.encodeWithSelector(IArcalsErrors.Unauthorized.selector, launchAuthority)
        );
        vm.prank(launchAuthority);
        vault.setLaunchAuthority(replacement);

        vm.prank(management);
        vault.setLaunchAuthority(replacement);
        vm.expectRevert(
            abi.encodeWithSelector(IArcalsErrors.Unauthorized.selector, launchAuthority)
        );
        vm.prank(launchAuthority);
        vault.activateConversions();

        vm.prank(replacement);
        vault.activateConversions();
        assertTrue(vault.conversionOpen());
        assertEq(vault.launchAuthority(), address(0));

        vm.expectRevert(IArcalsVault.ConversionsAlreadyActive.selector);
        vm.prank(management);
        vault.setLaunchAuthority(replacement);
    }

    // ------------------------------------------------ late epoch registration (finding 4)

    function testEpochCanBeRegisteredLateWithinItsOwnEpochAndMintResumes() public {
        uint64 nextEpoch = EPOCH_ID + 1;
        uint64 nextValidFrom = epochValidFrom + 1 days;
        ArcalsTypes.EpochCommitment memory commitment =
            _commitment(nextEpoch, configDigest, nextValidFrom);

        vm.warp(nextValidFrom + 6 hours);
        vm.prank(epochPublisher);
        controller.registerEpoch(commitment);

        address minter = makeAddr("late-epoch-minter");
        SignedMint memory signed = _signedMintForEpoch(minter, nextEpoch, keccak256("late"));
        vm.deal(minter, MINT_FEE);
        vm.prank(minter);
        controller.mint{ value: MINT_FEE }(
            signed.challenge, signed.issuerSignature, signed.certificate, signed.verifierSignature
        );
        assertEq(mirror.ownerOf(1), minter);

        ArcalsTypes.EpochCommitment memory expired =
            _commitment(nextEpoch + 1, configDigest, nextValidFrom + 1 days);
        vm.warp(nextValidFrom + 2 days);
        vm.expectRevert(IArcalsErrors.InvalidWork.selector);
        vm.prank(epochPublisher);
        controller.registerEpoch(expired);
        _assertConservation();
    }

    // --------------------------------------------- active work config only (finding 5)

    function testEpochMustBindTheActiveConfigAndConfigsAreOrderedWithLead() public {
        ArcalsTypes.WorkConfigV1 memory harder = _config(type(uint256).max / 2, 3);
        vm.prank(management);
        bytes32 harderDigest = controller.registerWorkConfig(harder);
        assertEq(controller.workConfigCount(), 2);

        // Earlier than the latest config.
        vm.expectRevert(IArcalsErrors.InvalidWork.selector);
        vm.prank(management);
        controller.registerWorkConfig(_config(type(uint256).max / 3, 2));

        // Less than one full epoch of notice before its effective epoch starts.
        vm.warp(workGenesisTime + 3 days + 1);
        vm.expectRevert(IArcalsErrors.InvalidWork.selector);
        vm.prank(management);
        controller.registerWorkConfig(_config(type(uint256).max / 3, 4));

        (bytes32 activeTwo,) = controller.activeWorkConfigDigest(2);
        (bytes32 activeThree,) = controller.activeWorkConfigDigest(3);
        assertEq(activeTwo, configDigest);
        assertEq(activeThree, harderDigest);

        uint64 epochFourFrom = workGenesisTime + 4 days;
        vm.warp(epochFourFrom - 10 minutes);
        vm.expectRevert(IArcalsErrors.InvalidWork.selector);
        vm.prank(epochPublisher);
        controller.registerEpoch(_commitment(4, configDigest, epochFourFrom));

        vm.prank(epochPublisher);
        controller.registerEpoch(_commitment(4, harderDigest, epochFourFrom));
        (ArcalsTypes.EpochCommitment memory stored, bool exists) = controller.epoch(4);
        assertTrue(exists);
        assertEq(stored.configDigest, harderDigest);
    }

    function testPendingConfigCanBeReplacedButNotAfterNoticeOrBeyondHorizon() public {
        vm.prank(management);
        bytes32 typo = controller.registerWorkConfig(_config(1, 5));
        vm.prank(management);
        bytes32 fixedDigest = controller.registerWorkConfig(_config(type(uint256).max / 4, 5));
        assertEq(controller.workConfigCount(), 2, "pending typo replaced in place");
        (bytes32 activeFive,) = controller.activeWorkConfigDigest(5);
        assertEq(activeFive, fixedDigest);
        assertTrue(activeFive != typo);

        // Too far ahead of the current epoch.
        vm.expectRevert(IArcalsErrors.InvalidWork.selector);
        vm.prank(management);
        controller.registerWorkConfig(_config(type(uint256).max / 5, 31));
        vm.expectRevert(IArcalsErrors.InvalidWork.selector);
        vm.prank(management);
        controller.registerWorkConfig(_config(type(uint256).max / 5, type(uint64).max));

        // Within one epoch of taking effect, the pending config is locked.
        vm.warp(workGenesisTime + 4 days + 1);
        vm.expectRevert(IArcalsErrors.InvalidWork.selector);
        vm.prank(management);
        controller.registerWorkConfig(_config(type(uint256).max / 6, 5));

        // Later configs still work inside the horizon.
        vm.prank(management);
        controller.registerWorkConfig(_config(type(uint256).max / 6, 20));
        assertEq(controller.workConfigCount(), 3);
    }

    // --------------------------------------------- factory code evidence (finding 6)

    function testFactoryRecordsCreationCodeHashesThatMatchThePlan() public view {
        bytes32[7] memory expected =
            ArcalsDeploymentPlan.creationCodeHashes(factory, _expectations());
        for (uint256 index = 0; index < 7; ++index) {
            assertEq(factory.creationCodeHashes(index), expected[index]);
        }
    }

    function testBackdooredChildIsExposedByRecordedCodeHash() public {
        ArcalsDeploymentFactory evilFactory = new ArcalsDeploymentFactory(address(this));
        ArcalsDeploymentFactory.Expectations memory expected = _expectations();
        bytes[] memory codes = ArcalsDeploymentPlan.creationCodes(evilFactory, expected);
        codes[5] = abi.encodePacked(
            type(BackdooredVault).creationCode,
            abi.encode(
                evilFactory.predictChildAddress(3),
                evilFactory.predictChildAddress(4),
                evilFactory.predictChildAddress(5),
                expected.launchAuthority,
                expected.managementMultisig
            )
        );
        evilFactory.deploy(codes, expected);

        bytes32[7] memory honest = ArcalsDeploymentPlan.creationCodeHashes(evilFactory, expected);
        for (uint256 index = 0; index < 7; ++index) {
            if (index == 5) {
                assertTrue(evilFactory.creationCodeHashes(index) != honest[index], "detected");
            } else {
                assertEq(evilFactory.creationCodeHashes(index), honest[index]);
            }
        }
    }

    function testArcMainnetDeploymentRequiresContractGovernanceRoles() public {
        vm.chainId(5042);
        ArcalsDeploymentFactory mainnetFactory = new ArcalsDeploymentFactory(address(this));
        ArcalsDeploymentFactory.Expectations memory expected = _expectations();
        bytes[] memory codes = ArcalsDeploymentPlan.creationCodes(mainnetFactory, expected);
        vm.expectRevert(ArcalsDeploymentFactory.InvalidDeploymentPlan.selector);
        mainnetFactory.deploy(codes, expected);

        vm.etch(management, hex"00");
        vm.etch(guardian, abi.encodePacked(hex"ef0100", makeAddr("7702-delegate")));
        vm.etch(treasuryOwner, hex"00");
        vm.etch(launchAuthority, hex"00");
        vm.expectRevert(ArcalsDeploymentFactory.InvalidDeploymentPlan.selector);
        mainnetFactory.deploy(codes, expected);

        vm.etch(guardian, hex"00");
        vm.etch(treasuryOwner, hex"00");
        vm.etch(launchAuthority, hex"00");
        // The reserve recipient must also be a contract account (a Safe) on Arc Mainnet.
        vm.expectRevert(ArcalsDeploymentFactory.InvalidDeploymentPlan.selector);
        mainnetFactory.deploy(codes, expected);

        vm.etch(reserveRecipient, hex"00");
        mainnetFactory.deploy(codes, expected);
        assertTrue(mainnetFactory.deploymentComplete());
    }

    // ------------------------------------------- governance without timelock

    function testFactoryWiresGovernanceDirectlyToManagementMultisig() public {
        assertEq(ProxyAdmin(proxyAdmin).owner(), management);
        assertEq(controller.governance(), management);
        assertEq(core.governance(), management);
        assertEq(mirror.governance(), management);
        assertEq(vault.governance(), management);

        address outsider = makeAddr("governance-outsider");
        vm.startPrank(outsider);
        vm.expectRevert(abi.encodeWithSelector(IArcalsErrors.Unauthorized.selector, outsider));
        core.resumeMint();
        vm.expectRevert(abi.encodeWithSelector(IArcalsErrors.Unauthorized.selector, outsider));
        core.setGuardian(outsider);
        vm.expectRevert(abi.encodeWithSelector(IArcalsErrors.Unauthorized.selector, outsider));
        mirror.setDefaultRoyalty(outsider, 100);
        vm.expectRevert(abi.encodeWithSelector(IArcalsErrors.Unauthorized.selector, outsider));
        vault.setLaunchAuthority(outsider);
        vm.expectRevert();
        controller.configureSigners(outsider, outsider, 9);
        vm.stopPrank();

        vm.prank(guardian);
        core.pauseMint();
        vm.prank(management);
        core.resumeMint();
        assertFalse(core.mintPaused());
    }

    // ---------------------------------------------------------------------- helpers

    function _sawMetadataUpdate(uint256 id) internal view returns (bool) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 index = 0; index < logs.length; ++index) {
            if (
                logs[index].emitter == address(mirror)
                    && logs[index].topics[0] == keccak256("MetadataUpdate(uint256)")
                    && abi.decode(logs[index].data, (uint256)) == id
            ) return true;
        }
        return false;
    }

    function _config(uint256 target, uint64 effectiveEpoch)
        internal
        pure
        returns (ArcalsTypes.WorkConfigV1 memory)
    {
        return ArcalsTypes.WorkConfigV1({
            protocolVersion: 1,
            algorithmId: keccak256("ARCALS_RANDOMX_V2_SALT_V1"),
            parameterDigest: keccak256("TEST_LOCAL_PARAMETERS"),
            epochSeconds: 1 days,
            keyLeadSeconds: 15 minutes,
            maxChallengeTtl: 20 minutes,
            maxCertificateTtl: 5 minutes,
            target: target,
            effectiveEpoch: effectiveEpoch
        });
    }

    function _commitment(uint64 epochId, bytes32 digest, uint64 validFrom)
        internal
        view
        returns (ArcalsTypes.EpochCommitment memory)
    {
        bytes32 anchorHash = keccak256(abi.encode("REGRESSION_ANCHOR", epochId));
        return ArcalsTypes.EpochCommitment({
            epochId: epochId,
            configDigest: digest,
            epochKey: ArcalsHashing.deriveEpochKey(
                block.chainid, address(controller), epochId, 99, anchorHash
            ),
            validFrom: validFrom,
            validUntil: validFrom + 1 days,
            anchorBlockNumber: 99,
            anchorBlockHash: anchorHash
        });
    }

    function _signedMintForEpoch(address minter, uint64 epochId, bytes32 unique)
        internal
        view
        returns (SignedMint memory signed)
    {
        signed = _signedMint(minter, core.nextMintNonce(minter), unique);
        signed.challenge.epochId = epochId;
        signed.challenge.challengeInput = ArcalsHashing.computeChallengeInput(
            block.chainid, address(controller), signed.challenge
        );
        bytes32 domain = ArcalsHashing.domainSeparator(block.chainid, address(controller));
        signed.issuerSignature = _sign(
            issuerPrivateKey,
            ArcalsHashing.typedDataDigest(domain, ArcalsHashing.hashChallenge(signed.challenge))
        );
        signed.certificate.challengeHash = ArcalsHashing.hashChallenge(signed.challenge);
        signed.receiptHash = ArcalsHashing.typedDataDigest(
            domain, ArcalsHashing.hashWorkCertificate(signed.certificate)
        );
        signed.verifierSignature = _sign(verifierPrivateKey, signed.receiptHash);
    }

    function _decodeJson(string memory uri) internal pure returns (string memory) {
        bytes memory raw = bytes(uri);
        assertTrue(_startsWith(raw, JSON_PREFIX), "json data uri");
        bytes memory payload = new bytes(raw.length - JSON_PREFIX.length);
        for (uint256 index = 0; index < payload.length; ++index) {
            payload[index] = raw[index + JSON_PREFIX.length];
        }
        return string(_base64Decode(payload));
    }

    function _startsWith(bytes memory value, bytes memory prefix) internal pure returns (bool) {
        if (value.length < prefix.length) return false;
        for (uint256 index = 0; index < prefix.length; ++index) {
            if (value[index] != prefix[index]) return false;
        }
        return true;
    }

    function _base64Decode(bytes memory input) internal pure returns (bytes memory output) {
        uint256 padding;
        if (input.length != 0 && input[input.length - 1] == "=") ++padding;
        if (input.length > 1 && input[input.length - 2] == "=") ++padding;
        // Base64 input length is always a multiple of four, so the division is exact.
        // forge-lint: disable-next-line(divide-before-multiply)
        output = new bytes((input.length / 4) * 3 - padding);
        uint256 out;
        for (uint256 index = 0; index < input.length; index += 4) {
            uint256 chunk;
            for (uint256 offset = 0; offset < 4; ++offset) {
                chunk = (chunk << 6) | _base64Value(input[index + offset]);
            }
            for (uint256 shift = 0; shift < 3; ++shift) {
                if (out < output.length) {
                    // Each extracted value is masked to one byte.
                    // forge-lint: disable-next-line(unsafe-typecast)
                    output[out++] = bytes1(uint8(chunk >> (16 - shift * 8)));
                }
            }
        }
    }

    function _base64Value(bytes1 char) internal pure returns (uint256) {
        uint8 c = uint8(char);
        if (c >= 65 && c <= 90) return c - 65;
        if (c >= 97 && c <= 122) return c - 71;
        if (c >= 48 && c <= 57) return c + 4;
        if (c == 43) return 62;
        if (c == 47) return 63;
        return 0;
    }
}
