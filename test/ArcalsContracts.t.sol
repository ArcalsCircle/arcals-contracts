// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { Test, Vm } from "forge-std/Test.sol";

import { ARCLBase } from "../src/ARCLBase.sol";
import { ArcalMirror } from "../src/ArcalMirror.sol";
import { ArcalsCore } from "../src/ArcalsCore.sol";
import { ArcalsDeploymentFactory } from "../src/ArcalsDeploymentFactory.sol";
import { ArcalsVault } from "../src/ArcalsVault.sol";
import { MintController } from "../src/MintController.sol";
import { RevenueTreasury } from "../src/RevenueTreasury.sol";
import { ArcalsDeploymentPlan } from "../src/deployment/ArcalsDeploymentPlan.sol";
import { IArcalsErrors } from "../src/interfaces/IArcalsErrors.sol";
import { IMintController } from "../src/interfaces/IMintController.sol";
import { ArcalsHashing } from "../src/shared/ArcalsHashing.sol";
import { ArcalsTypes } from "../src/shared/ArcalsTypes.sol";
import { PiProof } from "../src/shared/PiProof.sol";

contract RejectingReceiver is IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert("NFT_REJECTED");
    }

    receive() external payable {
        revert("NATIVE_REJECTED");
    }
}

contract MintForwarder is IERC721Receiver {
    bool public rejectNft;

    function execute(address controller, bytes calldata callData)
        external
        payable
        returns (bytes memory)
    {
        (bool success, bytes memory result) = controller.call{ value: msg.value }(callData);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }
        return result;
    }

    function setRejectNft(bool rejectNft_) external {
        rejectNft = rejectNft_;
    }

    function onERC721Received(address, address, uint256, bytes calldata)
        external
        view
        returns (bytes4)
    {
        if (rejectNft) revert("NFT_REJECTED");
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract ReentrantMinter is IERC721Receiver {
    address public controller;
    bytes public nestedCall;
    bool public attempted;
    bool public nestedSucceeded;
    bytes4 public nestedError;

    function execute(address controller_, bytes calldata outerCall, bytes calldata nestedCall_)
        external
        payable
    {
        controller = controller_;
        nestedCall = nestedCall_;
        (bool success, bytes memory result) = controller_.call{ value: 0.1 ether }(outerCall);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        attempted = true;
        (bool success, bytes memory result) = controller.call{ value: 0.1 ether }(nestedCall);
        nestedSucceeded = success;
        if (!nestedSucceeded && result.length >= 4) {
            bytes4 selector;
            assembly ("memory-safe") {
                selector := mload(add(result, 0x20))
            }
            nestedError = selector;
        }
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract ReentrantReformReceiver is IERC721Receiver {
    address public vault;
    bytes public nestedCall;
    bool public attempted;
    bool public nestedSucceeded;
    bytes4 public nestedError;

    function configure(address vault_, bytes calldata nestedCall_) external {
        vault = vault_;
        nestedCall = nestedCall_;
    }

    function approveArcl(ARCLBase base, address spender, uint256 amount) external {
        base.approve(spender, amount);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        attempted = true;
        (bool success, bytes memory result) = vault.call(nestedCall);
        nestedSucceeded = success;
        if (!nestedSucceeded && result.length >= 4) {
            bytes4 selector;
            assembly ("memory-safe") {
                selector := mload(add(result, 0x20))
            }
            nestedError = selector;
        }
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract MintControllerV2 is MintController {
    function implementationVersion() external pure returns (uint256) {
        return 2;
    }

    function bypassWork(address minter, uint256 nonce, bytes32 receiptHash)
        external
        payable
        returns (uint256)
    {
        return ArcalsCore(core).issue{ value: msg.value }(minter, nonce, receiptHash);
    }

    function attemptReserveMint() external {
        ArcalsCore coreContract = ArcalsCore(core);
        ARCLBase(coreContract.base()).protocolMintReserve(1);
    }

    function attemptVaultRelease(address recipient) external {
        ArcalsCore coreContract = ArcalsCore(core);
        ARCLBase(coreContract.base()).vaultRelease(recipient);
    }
}

abstract contract ArcalsTestBase is Test {
    using ArcalsDeploymentPlan for ArcalsDeploymentFactory;

    uint256 internal constant UNIT = 360 ether;
    uint256 internal constant MINT_FEE = 0.1 ether;
    uint256 internal constant GENESIS_LEAD = 1 hours;
    uint64 internal constant EPOCH_ID = 0;

    ArcalsDeploymentFactory internal factory;
    ProxyAdmin internal proxyAdmin;
    MintController internal controller;
    MintController internal implementation;
    ArcalsCore internal core;
    ARCLBase internal base;
    ArcalMirror internal mirror;
    ArcalsVault internal vault;
    RevenueTreasury internal treasury;

    address internal management;
    address internal guardian;
    address internal treasuryOwner;
    address internal launchAuthority;
    address internal epochPublisher;
    address internal reserveRecipient;
    uint256 internal issuerPrivateKey;
    address internal issuer;
    uint256 internal verifierPrivateKey;
    address internal verifier;
    bytes32 internal datasetRoot;
    bytes32 internal configDigest;
    uint64 internal epochValidFrom;
    uint64 internal workGenesisTime;

    mapping(uint256 id => bytes packed) internal packedDigits;
    mapping(uint256 id => bytes32[] proof) internal contentProofs;

    struct SignedMint {
        ArcalsTypes.Challenge challenge;
        bytes issuerSignature;
        ArcalsTypes.WorkCertificate certificate;
        bytes verifierSignature;
        bytes32 receiptHash;
    }

    function setUp() public virtual {
        management = makeAddr("management");
        guardian = makeAddr("guardian");
        treasuryOwner = makeAddr("treasury-owner");
        launchAuthority = makeAddr("launch-authority");
        epochPublisher = makeAddr("epoch-publisher");
        reserveRecipient = makeAddr("reserve-recipient");
        Vm.Wallet memory issuerWallet = vm.createWallet("runtime issuer");
        issuerPrivateKey = issuerWallet.privateKey;
        issuer = issuerWallet.addr;
        Vm.Wallet memory verifierWallet = vm.createWallet("runtime verifier");
        verifierPrivateKey = verifierWallet.privateKey;
        verifier = verifierWallet.addr;
        // Test timestamps remain far below uint64.max.
        // forge-lint: disable-next-line(unsafe-typecast)
        workGenesisTime = uint64(block.timestamp + GENESIS_LEAD);

        _buildContentFixture();
        _deployProtocol();
        _configureProtocol();
        _assertConservation();
    }

    function _buildContentFixture() internal virtual {
        bytes32[4] memory leaves;
        for (uint256 id = 1; id <= 4; ++id) {
            bytes memory packed = new bytes(180);
            // Test IDs are limited to 1...4, so the uint8 cast is lossless.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint8 digit = uint8(id);
            bytes1 pair = bytes1((digit << 4) | digit);
            for (uint256 index = 0; index < packed.length; ++index) {
                packed[index] = pair;
            }
            packedDigits[id] = packed;
            leaves[id - 1] = PiProof.leaf(id, keccak256(packed));
        }

        bytes32 pairZero = PiProof.node(leaves[0], leaves[1]);
        bytes32 pairOne = PiProof.node(leaves[2], leaves[3]);
        bytes32 currentRoot = PiProof.node(pairZero, pairOne);
        for (uint256 id = 1; id <= 4; ++id) {
            bytes32[] memory proof = new bytes32[](20);
            proof[0] = id & 1 == 1 ? leaves[id] : leaves[id - 2];
            proof[1] = id <= 2 ? pairOne : pairZero;
            contentProofs[id] = proof;
        }
        for (uint256 level = 2; level < 20; ++level) {
            bytes32 sibling = keccak256(abi.encode("ARCALS_TEST_SIBLING", level));
            for (uint256 id = 1; id <= 4; ++id) {
                contentProofs[id][level] = sibling;
            }
            currentRoot = PiProof.node(currentRoot, sibling);
        }
        datasetRoot = currentRoot;
    }

    function _deployProtocol() internal {
        factory = new ArcalsDeploymentFactory(address(this));
        ArcalsDeploymentFactory.Expectations memory expected = _expectations();
        bytes[] memory creationCodes = factory.creationCodes(expected);
        address[8] memory deployed = factory.deploy(creationCodes, expected);
        implementation = MintController(deployed[0]);
        controller = MintController(payable(deployed[1]));
        proxyAdmin = ProxyAdmin(deployed[2]);
        core = ArcalsCore(deployed[3]);
        base = ARCLBase(deployed[4]);
        mirror = ArcalMirror(deployed[5]);
        vault = ArcalsVault(deployed[6]);
        treasury = RevenueTreasury(payable(deployed[7]));
    }

    function _expectations()
        internal
        view
        returns (ArcalsDeploymentFactory.Expectations memory expected)
    {
        return ArcalsDeploymentFactory.Expectations({
            managementMultisig: management,
            guardian: guardian,
            treasuryOwner: treasuryOwner,
            launchAuthority: launchAuthority,
            epochPublisher: epochPublisher,
            workGenesisTime: workGenesisTime,
            issuerSigner: issuer,
            verifierSigner: verifier,
            signerVersion: 1,
            datasetRoot: datasetRoot,
            reserveRecipient: reserveRecipient
        });
    }

    function _configureProtocol() internal {
        ArcalsTypes.WorkConfigV1 memory config = ArcalsTypes.WorkConfigV1({
            protocolVersion: 1,
            algorithmId: keccak256("ARCALS_RANDOMX_V2_SALT_V1"),
            parameterDigest: keccak256("TEST_LOCAL_PARAMETERS"),
            epochSeconds: 1 days,
            keyLeadSeconds: 15 minutes,
            maxChallengeTtl: 20 minutes,
            maxCertificateTtl: 5 minutes,
            target: type(uint256).max,
            effectiveEpoch: EPOCH_ID
        });
        configDigest = ArcalsHashing.hashWorkConfig(config);
        // Governance is the management multisig directly: no delay between deployment and launch.
        vm.prank(management);
        controller.registerWorkConfig(config);
        vm.prank(management);
        core.resumeMint();

        epochValidFrom = workGenesisTime;
        vm.warp(epochValidFrom - 15 minutes);
        bytes32 anchorBlockHash = keccak256("TEST_LOCAL_ANCHOR");
        ArcalsTypes.EpochCommitment memory commitment = ArcalsTypes.EpochCommitment({
            epochId: EPOCH_ID,
            configDigest: configDigest,
            epochKey: ArcalsHashing.deriveEpochKey(
                block.chainid, address(controller), EPOCH_ID, 12_345, anchorBlockHash
            ),
            validFrom: epochValidFrom,
            validUntil: epochValidFrom + 1 days,
            anchorBlockNumber: 12_345,
            anchorBlockHash: anchorBlockHash
        });
        vm.prank(epochPublisher);
        controller.registerEpoch(commitment);
        vm.warp(epochValidFrom);
    }

    function _signedMint(address minter, uint256 nonce, bytes32 unique)
        internal
        view
        returns (SignedMint memory signed)
    {
        signed.challenge = ArcalsTypes.Challenge({
            protocolVersion: 1,
            configDigest: configDigest,
            challengeId: keccak256(abi.encode("ARCALS_TEST_CHALLENGE", minter, nonce, unique)),
            epochId: EPOCH_ID,
            minter: minter,
            mintNonce: nonce,
            challengeInput: bytes32(0),
            mintFee: MINT_FEE,
            validAfter: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + 10 minutes),
            signerVersion: 1
        });
        signed.challenge.challengeInput = ArcalsHashing.computeChallengeInput(
            block.chainid, address(controller), signed.challenge
        );
        bytes32 domain = ArcalsHashing.domainSeparator(block.chainid, address(controller));
        bytes32 challengeDigest =
            ArcalsHashing.typedDataDigest(domain, ArcalsHashing.hashChallenge(signed.challenge));
        signed.issuerSignature = _sign(issuerPrivateKey, challengeDigest);

        signed.certificate = ArcalsTypes.WorkCertificate({
            protocolVersion: 1,
            challengeHash: ArcalsHashing.hashChallenge(signed.challenge),
            // Protocol nonces in this test never exceed the one-million cap.
            // forge-lint: disable-next-line(unsafe-typecast)
            workNonce: uint64(nonce + 1),
            randomxHash: keccak256(abi.encode("ARCALS_TEST_RESULT", minter, nonce, unique)),
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + 5 minutes),
            signerVersion: 1
        });
        signed.receiptHash = ArcalsHashing.typedDataDigest(
            domain, ArcalsHashing.hashWorkCertificate(signed.certificate)
        );
        signed.verifierSignature = _sign(verifierPrivateKey, signed.receiptHash);
    }

    function _sign(uint256 privateKey, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _mint(address minter) internal returns (uint256 id, SignedMint memory signed) {
        uint256 nonce = core.nextMintNonce(minter);
        signed = _signedMint(minter, nonce, bytes32(core.mintedCount() + 1));
        vm.deal(minter, minter.balance + MINT_FEE);
        vm.prank(minter);
        id = controller.mint{ value: MINT_FEE }(
            signed.challenge, signed.issuerSignature, signed.certificate, signed.verifierSignature
        );
    }

    /// @dev Moves issuance counters and the matching ARCL supply directly (no banked Arcals).
    function _setIssued(uint256 publicMinted, uint256 reserveMinted) internal {
        vm.store(address(core), bytes32(uint256(0)), bytes32(publicMinted));
        vm.store(address(core), bytes32(uint256(6)), bytes32(reserveMinted));
        uint256 supply = (publicMinted + reserveMinted) * UNIT;
        vm.store(address(base), bytes32(uint256(2)), bytes32(supply));
        vm.store(address(base), keccak256(abi.encode(address(vault), uint256(0))), bytes32(supply));
    }

    function _register(uint256 id) internal {
        mirror.registerContent(id, packedDigits[id], contentProofs[id]);
    }

    function _activate() internal {
        vm.prank(launchAuthority);
        vault.activateConversions();
    }

    function _assertConservation() internal view {
        uint256 minted = core.mintedCount() + core.reserveMintedCount();
        uint256 banked = vault.tail() - vault.head();
        assertEq(base.totalSupply(), minted * UNIT, "total supply");
        assertEq(base.balanceOf(address(vault)), (minted - banked) * UNIT, "reserve");
        assertEq(base.totalSupply() - base.balanceOf(address(vault)), banked * UNIT, "external");
        assertEq(vault.circulatingSupply(), banked * UNIT, "circulating supply view");
        assertEq(mirror.balanceOf(address(vault)), banked, "vault NFT balance");
        assertEq(vault.bankedCount(), banked, "queue count");
        assertFalse(core.protocolLocked(), "shared lock released");
        for (uint256 position = vault.head(); position < vault.tail(); ++position) {
            uint256 id = vault.queueAt(position);
            assertTrue(vault.isBanked(id), "queue membership");
            assertEq(mirror.ownerOf(id), address(vault), "queue ownership");
        }
    }
}

contract ArcalsContractsTest is ArcalsTestBase {
    function testFactoryWiresImmutableGraphAndRealProxyAdmin() public {
        assertTrue(factory.deploymentComplete());
        assertEq(proxyAdmin.owner(), management);
        assertEq(controller.governance(), management);
        assertEq(core.governance(), management);
        assertEq(mirror.governance(), management);
        assertEq(vault.governance(), management);
        assertEq(core.controller(), address(controller));
        assertEq(core.base(), address(base));
        assertEq(core.mirror(), address(mirror));
        assertEq(core.vault(), address(vault));
        assertEq(core.treasury(), address(treasury));
        assertEq(base.mirrorERC721(), address(mirror));
        assertEq(mirror.baseERC20(), address(base));
        assertEq(mirror.datasetRoot(), datasetRoot);
        assertEq(vault.launchAuthority(), launchAuthority);
        assertLt(address(core).code.length, 24_576);
        assertLt(address(base).code.length, 24_576);
        assertLt(address(mirror).code.length, 24_576);
        assertLt(address(vault).code.length, 24_576);
        assertLt(address(controller).code.length, 24_576);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(
            address(core),
            management,
            guardian,
            epochPublisher,
            workGenesisTime,
            issuer,
            verifier,
            1
        );
        _assertConservation();
    }

    function testFactoryIsOneUseAndDeploymentGasIsBounded() public {
        ArcalsDeploymentFactory.Expectations memory expected = _expectations();
        vm.expectRevert(ArcalsDeploymentFactory.InvalidDeploymentPlan.selector);
        factory.deploy(new bytes[](0), expected);

        ArcalsDeploymentFactory secondFactory = new ArcalsDeploymentFactory(address(this));
        bytes[] memory codes = ArcalsDeploymentPlan.creationCodes(secondFactory, expected);
        uint256 gasBefore = gasleft();
        address[8] memory deployed = secondFactory.deploy(codes, expected);
        uint256 deploymentGas = gasBefore - gasleft();
        emit log_named_uint("atomic child deployment gas", deploymentGas);
        assertLt(deploymentGas, 25_000_000);

        ArcalsCore secondCore = ArcalsCore(deployed[3]);
        ARCLBase secondBase = ARCLBase(deployed[4]);
        ArcalMirror secondMirror = ArcalMirror(deployed[5]);
        ArcalsVault secondVault = ArcalsVault(deployed[6]);
        assertEq(secondCore.mintedCount(), 0);
        assertEq(secondBase.totalSupply(), 0);
        assertEq(secondBase.balanceOf(address(secondVault)), 0);
        assertEq(secondMirror.balanceOf(address(secondVault)), 0);
        assertEq(secondVault.bankedCount(), 0);
        assertEq(secondVault.circulatingSupply(), 0);
        _assertConservation();
    }

    function testMintIsAtomicAndRecordsFeeNonceAndReceipt() public {
        address alice = makeAddr("alice");
        (uint256 id, SignedMint memory signed) = _mint(alice);
        assertEq(id, 1);
        assertEq(mirror.ownerOf(id), alice);
        assertEq(core.nextMintNonce(alice), 1);
        assertEq(core.issuedId(signed.receiptHash), id);
        assertEq(address(treasury).balance, MINT_FEE);
        assertEq(treasury.totalMintRevenue(), MINT_FEE);
        assertEq(base.balanceOf(address(vault)), UNIT);
        _assertConservation();
    }

    function testMintEncodedUsesTheSameValidationAndAssetPath() public {
        address alice = makeAddr("encoded-alice");
        address bob = makeAddr("encoded-bob");
        SignedMint memory signed = _signedMint(alice, 0, keccak256("encoded-mint"));
        bytes memory payload = abi.encode(
            signed.challenge, signed.issuerSignature, signed.certificate, signed.verifierSignature
        );
        vm.deal(alice, MINT_FEE);
        vm.prank(alice);
        uint256 id = controller.mintEncoded{ value: MINT_FEE }(payload);
        assertEq(id, 1);
        assertEq(mirror.ownerOf(id), alice);
        assertEq(core.issuedId(signed.receiptHash), id);
        assertEq(core.nextMintNonce(alice), 1);
        assertEq(address(treasury).balance, MINT_FEE);
        _assertConservation();

        SignedMint memory wrongMinter = _signedMint(bob, 0, keccak256("encoded-wrong-minter"));
        bytes memory wrongPayload = abi.encode(
            wrongMinter.challenge,
            wrongMinter.issuerSignature,
            wrongMinter.certificate,
            wrongMinter.verifierSignature
        );
        vm.deal(alice, MINT_FEE);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IArcalsErrors.WrongMinter.selector, alice, bob));
        controller.mintEncoded{ value: MINT_FEE }(wrongPayload);

        vm.prank(alice);
        vm.expectRevert();
        controller.mintEncoded{ value: MINT_FEE }(hex"1234");
        _assertConservation();
    }

    function testRejectedNftReceiverRollsBackWholeMint() public {
        MintForwarder forwarder = new MintForwarder();
        forwarder.setRejectNft(true);
        SignedMint memory signed = _signedMint(address(forwarder), 0, keccak256("reject"));
        bytes memory callData = abi.encodeCall(
            IMintController.mint,
            (signed.challenge, signed.issuerSignature, signed.certificate, signed.verifierSignature)
        );
        vm.deal(address(this), MINT_FEE);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "NFT_REJECTED"));
        forwarder.execute{ value: MINT_FEE }(address(controller), callData);
        assertEq(core.mintedCount(), 0);
        assertEq(address(treasury).balance, 0);
        assertEq(core.nextMintNonce(address(forwarder)), 0);
        assertEq(core.issuedId(signed.receiptHash), 0);
        _assertConservation();
    }

    function testMintRejectsWrongFeeSignatureExpiryAndReplay() public {
        address alice = makeAddr("alice-validation");
        SignedMint memory signed = _signedMint(alice, 0, keccak256("validation"));
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IArcalsErrors.WrongMintFee.selector, 1, MINT_FEE));
        controller.mint{ value: 1 }(
            signed.challenge, signed.issuerSignature, signed.certificate, signed.verifierSignature
        );

        ArcalsTypes.WorkCertificate memory wrongVersion = signed.certificate;
        wrongVersion.protocolVersion = 2;
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IArcalsErrors.UnsupportedProtocolVersion.selector, uint32(2))
        );
        controller.mint{ value: MINT_FEE }(
            signed.challenge, signed.issuerSignature, wrongVersion, signed.verifierSignature
        );
        signed.certificate.protocolVersion = 1;

        bytes memory badSignature = bytes.concat(signed.issuerSignature);
        badSignature[0] = bytes1(uint8(badSignature[0]) ^ 1);
        vm.prank(alice);
        vm.expectRevert(IArcalsErrors.InvalidSignature.selector);
        controller.mint{ value: MINT_FEE }(
            signed.challenge, badSignature, signed.certificate, signed.verifierSignature
        );

        vm.warp(signed.certificate.expiresAt);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IArcalsErrors.CertificateExpired.selector, signed.certificate.expiresAt
            )
        );
        controller.mint{ value: MINT_FEE }(
            signed.challenge, signed.issuerSignature, signed.certificate, signed.verifierSignature
        );

        vm.warp(epochValidFrom + 6 minutes);
        (uint256 id,) = _mint(alice);
        assertEq(id, 1);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IArcalsErrors.NonceConsumed.selector, alice, uint256(0))
        );
        controller.mint{ value: MINT_FEE }(
            signed.challenge, signed.issuerSignature, signed.certificate, signed.verifierSignature
        );
        _assertConservation();
    }

    function testMintRejectsMutatedProtocolBindingsBeforeIssuance() public {
        address alice = makeAddr("binding-alice");
        address bob = makeAddr("binding-bob");
        vm.deal(alice, 10 * MINT_FEE);
        vm.deal(bob, MINT_FEE);

        {
            SignedMint memory signed = _signedMint(alice, 0, keccak256("challenge-version"));
            signed.challenge.protocolVersion = 2;
            vm.prank(alice);
            vm.expectRevert(
                abi.encodeWithSelector(IArcalsErrors.UnsupportedProtocolVersion.selector, uint32(2))
            );
            controller.mint{ value: MINT_FEE }(
                signed.challenge,
                signed.issuerSignature,
                signed.certificate,
                signed.verifierSignature
            );
        }
        {
            SignedMint memory signed = _signedMint(alice, 0, keccak256("wrong-caller"));
            vm.prank(bob);
            vm.expectRevert(abi.encodeWithSelector(IArcalsErrors.WrongMinter.selector, bob, alice));
            controller.mint{ value: MINT_FEE }(
                signed.challenge,
                signed.issuerSignature,
                signed.certificate,
                signed.verifierSignature
            );
        }
        {
            SignedMint memory signed = _signedMint(alice, 0, keccak256("embedded-fee"));
            signed.challenge.mintFee = MINT_FEE + 1;
            vm.prank(alice);
            vm.expectRevert(
                abi.encodeWithSelector(IArcalsErrors.WrongMintFee.selector, MINT_FEE + 1, MINT_FEE)
            );
            controller.mint{ value: MINT_FEE }(
                signed.challenge,
                signed.issuerSignature,
                signed.certificate,
                signed.verifierSignature
            );
        }
        {
            SignedMint memory signed = _signedMint(alice, 0, keccak256("signer-version"));
            signed.challenge.signerVersion = 2;
            vm.prank(alice);
            vm.expectRevert(IArcalsErrors.InvalidSignature.selector);
            controller.mint{ value: MINT_FEE }(
                signed.challenge,
                signed.issuerSignature,
                signed.certificate,
                signed.verifierSignature
            );
        }
        {
            SignedMint memory signed = _signedMint(alice, 0, keccak256("unknown-config"));
            signed.challenge.configDigest = keccak256("UNKNOWN_CONFIG");
            vm.prank(alice);
            vm.expectRevert(
                abi.encodeWithSelector(IArcalsErrors.EpochUnavailable.selector, uint64(0))
            );
            controller.mint{ value: MINT_FEE }(
                signed.challenge,
                signed.issuerSignature,
                signed.certificate,
                signed.verifierSignature
            );
        }
        {
            SignedMint memory signed = _signedMint(alice, 0, keccak256("unknown-epoch"));
            signed.challenge.epochId = 99;
            vm.prank(alice);
            vm.expectRevert(
                abi.encodeWithSelector(IArcalsErrors.EpochUnavailable.selector, uint64(99))
            );
            controller.mint{ value: MINT_FEE }(
                signed.challenge,
                signed.issuerSignature,
                signed.certificate,
                signed.verifierSignature
            );
        }
        {
            SignedMint memory signed = _signedMint(alice, 0, keccak256("challenge-input"));
            signed.challenge.challengeInput = keccak256("WRONG_INPUT");
            vm.prank(alice);
            vm.expectRevert(IArcalsErrors.InvalidWork.selector);
            controller.mint{ value: MINT_FEE }(
                signed.challenge,
                signed.issuerSignature,
                signed.certificate,
                signed.verifierSignature
            );
        }
        {
            SignedMint memory signed = _signedMint(alice, 0, keccak256("certificate-binding"));
            signed.certificate.challengeHash = keccak256("WRONG_CHALLENGE");
            vm.prank(alice);
            vm.expectRevert(IArcalsErrors.InvalidWork.selector);
            controller.mint{ value: MINT_FEE }(
                signed.challenge,
                signed.issuerSignature,
                signed.certificate,
                signed.verifierSignature
            );
        }
        assertEq(core.mintedCount(), 0);
        _assertConservation();
    }

    function testWorkConfigAndEpochRegistrationRejectInvalidBoundaries() public {
        ArcalsTypes.WorkConfigV1 memory next = ArcalsTypes.WorkConfigV1({
            protocolVersion: 1,
            algorithmId: keccak256("ARCALS_RANDOMX_V2_SALT_V1"),
            parameterDigest: keccak256("TEST_LOCAL_PARAMETERS"),
            epochSeconds: 1 days,
            keyLeadSeconds: 15 minutes,
            maxChallengeTtl: 20 minutes,
            maxCertificateTtl: 5 minutes,
            target: type(uint256).max / 2,
            effectiveEpoch: 2
        });
        ArcalsTypes.WorkConfigV1 memory invalid = next;
        invalid.target = 0;
        vm.prank(management);
        vm.expectRevert(IArcalsErrors.InvalidWork.selector);
        controller.registerWorkConfig(invalid);
        invalid.target = type(uint256).max / 2;

        invalid = next;
        invalid.algorithmId = bytes32(0);
        vm.prank(management);
        vm.expectRevert(IArcalsErrors.InvalidWork.selector);
        controller.registerWorkConfig(invalid);
        invalid.algorithmId = keccak256("ARCALS_RANDOMX_V2_SALT_V1");

        invalid = next;
        invalid.maxChallengeTtl = 20 minutes + 1;
        vm.prank(management);
        vm.expectRevert(IArcalsErrors.InvalidWork.selector);
        controller.registerWorkConfig(invalid);
        invalid.maxChallengeTtl = 20 minutes;

        vm.prank(management);
        bytes32 nextDigest = controller.registerWorkConfig(next);
        vm.prank(management);
        vm.expectRevert(IArcalsErrors.InvalidWork.selector);
        controller.registerWorkConfig(next);

        uint64 nextValidFrom = workGenesisTime + 2 days;
        bytes32 anchorHash = keccak256("EPOCH_2_ANCHOR");
        ArcalsTypes.EpochCommitment memory commitment = ArcalsTypes.EpochCommitment({
            epochId: 2,
            configDigest: nextDigest,
            epochKey: ArcalsHashing.deriveEpochKey(
                block.chainid, address(controller), 2, 12_347, anchorHash
            ),
            validFrom: nextValidFrom,
            validUntil: nextValidFrom + 1 days,
            anchorBlockNumber: 12_347,
            anchorBlockHash: anchorHash
        });
        vm.warp(nextValidFrom - 15 minutes);

        ArcalsTypes.EpochCommitment memory invalidEpoch = commitment;
        invalidEpoch.configDigest = keccak256("UNKNOWN_EPOCH_CONFIG");
        vm.prank(epochPublisher);
        vm.expectRevert(abi.encodeWithSelector(IArcalsErrors.EpochUnavailable.selector, uint64(2)));
        controller.registerEpoch(invalidEpoch);
        invalidEpoch.configDigest = nextDigest;

        invalidEpoch = commitment;
        invalidEpoch.validUntil += 1;
        vm.prank(epochPublisher);
        vm.expectRevert(IArcalsErrors.InvalidWork.selector);
        controller.registerEpoch(invalidEpoch);
        invalidEpoch.validUntil -= 1;

        invalidEpoch = commitment;
        invalidEpoch.epochKey = keccak256("WRONG_EPOCH_KEY");
        vm.prank(epochPublisher);
        vm.expectRevert(IArcalsErrors.InvalidWork.selector);
        controller.registerEpoch(invalidEpoch);
        invalidEpoch.epochKey = ArcalsHashing.deriveEpochKey(
            block.chainid, address(controller), 2, 12_347, anchorHash
        );

        vm.prank(epochPublisher);
        controller.registerEpoch(commitment);
        vm.prank(epochPublisher);
        vm.expectRevert(IArcalsErrors.InvalidWork.selector);
        controller.registerEpoch(commitment);
        _assertConservation();
    }

    function testGuardianPauseIsImmediateAndOnlyGovernanceResumes() public {
        vm.prank(guardian);
        controller.pauseMint();
        assertTrue(core.mintPaused());
        SignedMint memory signed = _signedMint(makeAddr("paused-user"), 0, keccak256("paused"));
        vm.deal(signed.challenge.minter, MINT_FEE);
        vm.prank(signed.challenge.minter);
        vm.expectRevert(IArcalsErrors.MintIsPaused.selector);
        controller.mint{ value: MINT_FEE }(
            signed.challenge, signed.issuerSignature, signed.certificate, signed.verifierSignature
        );

        vm.expectRevert(abi.encodeWithSelector(IArcalsErrors.Unauthorized.selector, address(this)));
        core.resumeMint();
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(IArcalsErrors.Unauthorized.selector, guardian));
        core.resumeMint();
        vm.prank(management);
        core.resumeMint();
        assertFalse(core.mintPaused());
        _assertConservation();
    }

    function testTreasuryWithdrawsRevenueAndRejectingTargetRollsBack() public {
        _mint(makeAddr("treasury-minter"));
        RejectingReceiver rejecting = new RejectingReceiver();
        vm.prank(treasuryOwner);
        vm.expectRevert(
            abi.encodeWithSelector(
                RevenueTreasury.NativeTransferFailed.selector, address(rejecting), MINT_FEE
            )
        );
        treasury.withdraw(payable(address(rejecting)), MINT_FEE);
        assertEq(treasury.totalWithdrawn(), 0);
        assertEq(address(treasury).balance, MINT_FEE);

        address recipient = makeAddr("treasury-recipient");
        vm.prank(treasuryOwner);
        treasury.withdraw(payable(recipient), MINT_FEE);
        assertEq(recipient.balance, MINT_FEE);
        assertEq(treasury.totalWithdrawn(), MINT_FEE);
        assertEq(address(treasury).balance, 0);
        _assertConservation();
    }

    function testTreasuryCannotRenounceOwnershipAndCanStillRotateInTwoSteps() public {
        vm.prank(treasuryOwner);
        vm.expectRevert(RevenueTreasury.OwnershipRenunciationDisabled.selector);
        treasury.renounceOwnership();
        assertEq(treasury.owner(), treasuryOwner);

        address nextOwner = makeAddr("next-treasury-owner");
        vm.prank(treasuryOwner);
        treasury.transferOwnership(nextOwner);
        assertEq(treasury.owner(), treasuryOwner);
        assertEq(treasury.pendingOwner(), nextOwner);
        vm.prank(nextOwner);
        treasury.acceptOwnership();
        assertEq(treasury.owner(), nextOwner);
        assertEq(treasury.pendingOwner(), address(0));
        _assertConservation();
    }

    function testMirrorAdvertisesErc4906Interface() public view {
        assertTrue(mirror.supportsInterface(0x49064906));
        assertFalse(mirror.supportsInterface(0xffffffff));
    }

    function testContentRegistrationIsPermissionlessValidatedAndIdempotent() public {
        address alice = makeAddr("content-owner");
        _mint(alice);
        address relayer = makeAddr("content-relayer");
        vm.recordLogs();
        vm.prank(relayer);
        mirror.registerContent(1, packedDigits[1], contentProofs[1]);
        Vm.Log[] memory registrationLogs = vm.getRecordedLogs();
        assertEq(registrationLogs.length, 2);
        assertEq(registrationLogs[1].topics.length, 1, "ERC-4906 token id is not indexed");
        assertEq(registrationLogs[1].topics[0], keccak256("MetadataUpdate(uint256)"));
        assertEq(abi.decode(registrationLogs[1].data, (uint256)), 1);
        bytes32 hash = keccak256(packedDigits[1]);
        assertTrue(mirror.contentRegistered(1));
        assertEq(mirror.contentHash(1), hash);

        vm.recordLogs();
        vm.prank(makeAddr("second-relayer"));
        mirror.registerContent(1, packedDigits[1], contentProofs[1]);
        assertEq(vm.getRecordedLogs().length, 0);

        bytes memory badDigits = packedDigits[1];
        badDigits[0] = 0xfa;
        vm.expectRevert(
            abi.encodeWithSelector(IArcalsErrors.InvalidContentProof.selector, uint256(1))
        );
        mirror.registerContent(1, badDigits, contentProofs[1]);
        vm.expectRevert(
            abi.encodeWithSelector(IArcalsErrors.InvalidContentProof.selector, uint256(2))
        );
        mirror.registerContent(2, packedDigits[2], contentProofs[2]);
        _assertConservation();
    }

    function testDirectVaultTransfersAreRejectedButZeroArclTransferIsStandard() public {
        address alice = makeAddr("direct-owner");
        _mint(alice);
        vm.prank(alice);
        vm.expectRevert(IArcalsErrors.DirectVaultTransferForbidden.selector);
        mirror.transferFrom(alice, address(vault), 1);
        vm.prank(alice);
        vm.expectRevert(IArcalsErrors.DirectVaultTransferForbidden.selector);
        mirror.safeTransferFrom(alice, address(vault), 1);

        _register(1);
        _activate();
        vm.prank(alice);
        mirror.approve(address(vault), 1);
        vm.prank(alice);
        vault.liquify(1, alice, uint64(block.timestamp));
        vm.prank(alice);
        vm.expectRevert(IArcalsErrors.DirectVaultTransferForbidden.selector);
        // The call must revert, so no boolean return value exists to inspect.
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        base.transfer(address(vault), 1);
        vm.prank(alice);
        assertTrue(base.transfer(address(vault), 0));
        _assertConservation();
    }

    function testConversionGuardsRollbackWithoutMovingEitherAsset() public {
        address alice = makeAddr("conversion-guard-alice");
        address bob = makeAddr("conversion-guard-bob");
        _mint(alice);
        _mint(bob);
        _register(1);
        vm.prank(alice);
        mirror.approve(address(vault), 1);
        vm.prank(alice);
        vm.expectRevert(IArcalsErrors.ConversionsClosed.selector);
        vault.liquify(1, alice, uint64(block.timestamp));

        _activate();
        assertEq(vault.launchAuthority(), address(0));
        vm.prank(launchAuthority);
        vm.expectRevert(
            abi.encodeWithSelector(IArcalsErrors.Unauthorized.selector, launchAuthority)
        );
        vault.activateConversions();

        vm.prank(bob);
        mirror.approve(address(vault), 2);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IArcalsErrors.ContentNotRegistered.selector, uint256(2))
        );
        vault.liquify(2, bob, uint64(block.timestamp));
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IArcalsErrors.DeadlineExpired.selector, uint64(block.timestamp - 1)
            )
        );
        vault.liquify(1, alice, uint64(block.timestamp - 1));

        vm.prank(alice);
        vault.liquify(1, alice, uint64(block.timestamp));
        assertEq(base.balanceOf(alice), UNIT);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IArcalsErrors.InsufficientAllowance.selector, alice, uint256(0), UNIT
            )
        );
        vault.reform(alice, 1, uint64(block.timestamp));
        assertEq(base.balanceOf(alice), UNIT);
        assertEq(mirror.ownerOf(1), address(vault));

        vm.prank(alice);
        base.approve(address(vault), UNIT);
        vm.prank(alice);
        vault.reform(alice, 0, uint64(block.timestamp));
        vm.prank(alice);
        vm.expectRevert(IArcalsErrors.VaultEmpty.selector);
        vault.reform(alice, 0, uint64(block.timestamp));
        _assertConservation();
    }

    function testProtocolCustodyRecipientsAreRejectedBeforeAssetsMove() public {
        address alice = makeAddr("custody-recipient-alice");
        _mint(alice);
        _register(1);
        _activate();

        vm.prank(alice);
        mirror.approve(address(vault), 1);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IArcalsErrors.Unauthorized.selector, address(controller))
        );
        vault.liquify(1, address(controller), uint64(block.timestamp));
        assertEq(mirror.ownerOf(1), alice);
        assertEq(base.balanceOf(alice), 0);

        vm.prank(alice);
        vault.liquify(1, alice, uint64(block.timestamp));
        vm.prank(alice);
        base.approve(address(vault), UNIT);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IArcalsErrors.Unauthorized.selector, address(treasury))
        );
        vault.reform(address(treasury), 1, uint64(block.timestamp));
        assertEq(base.balanceOf(alice), UNIT);
        assertEq(mirror.ownerOf(1), address(vault));
        _assertConservation();
    }

    function testOrdinaryArclTransfersNeverMoveOrReissueNfts() public {
        address alice = makeAddr("arcl-transfer-alice");
        address bob = makeAddr("arcl-transfer-bob");
        _mint(alice);
        _mint(bob);
        _register(1);
        _register(2);
        _activate();
        vm.startPrank(alice);
        mirror.approve(address(vault), 1);
        vault.liquify(1, alice, uint64(block.timestamp));
        vm.stopPrank();
        vm.startPrank(bob);
        mirror.approve(address(vault), 2);
        vault.liquify(2, bob, uint64(block.timestamp));
        vm.stopPrank();

        uint256 fragment = 123 ether + 7;
        vm.prank(alice);
        assertTrue(base.transfer(bob, fragment));
        assertEq(base.balanceOf(alice), UNIT - fragment);
        assertEq(base.balanceOf(bob), UNIT + fragment);
        assertEq(mirror.ownerOf(1), address(vault));
        assertEq(mirror.ownerOf(2), address(vault));
        assertEq(core.mintedCount(), 2);
        assertEq(vault.bankedCount(), 2);
        _assertConservation();
    }

    function testEpochPublisherAndSignerRotationAreGovernanceOnly() public {
        address nextPublisher = makeAddr("next-epoch-publisher");
        address nextIssuer = makeAddr("next-issuer");
        address nextVerifier = makeAddr("next-verifier");
        vm.prank(makeAddr("unauthorized-publisher"));
        vm.expectRevert();
        controller.configureEpochPublisher(nextPublisher);

        vm.prank(makeAddr("unauthorized-signer-rotation"));
        vm.expectRevert();
        controller.configureSigners(nextIssuer, nextVerifier, uint64(2));

        vm.prank(management);
        controller.configureEpochPublisher(nextPublisher);
        vm.prank(management);
        controller.configureSigners(nextIssuer, nextVerifier, uint64(2));
        assertEq(controller.epochPublisher(), nextPublisher);
        assertEq(controller.issuerSigner(), nextIssuer);
        assertEq(controller.verifierSigner(), nextVerifier);
        assertEq(controller.signerVersion(), 2);

        uint64 nextEpochId = 3;
        uint64 nextStart = workGenesisTime + 3 days;
        vm.warp(nextStart - 15 minutes);
        bytes32 anchor = keccak256("NEXT_LOCAL_ANCHOR");
        ArcalsTypes.EpochCommitment memory nextEpoch = ArcalsTypes.EpochCommitment({
            epochId: nextEpochId,
            configDigest: configDigest,
            epochKey: ArcalsHashing.deriveEpochKey(
                block.chainid, address(controller), nextEpochId, 12_346, anchor
            ),
            validFrom: nextStart,
            validUntil: nextStart + 1 days,
            anchorBlockNumber: 12_346,
            anchorBlockHash: anchor
        });
        vm.prank(epochPublisher);
        vm.expectRevert(abi.encodeWithSelector(IArcalsErrors.Unauthorized.selector, epochPublisher));
        controller.registerEpoch(nextEpoch);
        vm.prank(nextPublisher);
        controller.registerEpoch(nextEpoch);
        (, bool exists) = controller.epoch(nextEpochId);
        assertTrue(exists);
        _assertConservation();
    }

    function testLiquifyAndReformUseOwnerAllowanceFifoAndRequeueAtTail() public {
        address alice = makeAddr("fifo-alice");
        address bob = makeAddr("fifo-bob");
        _mint(alice);
        _mint(bob);
        _register(1);
        _register(2);
        _activate();

        vm.prank(alice);
        mirror.approve(address(vault), 1);
        vm.prank(alice);
        vault.liquify(1, alice, uint64(block.timestamp));
        vm.prank(bob);
        mirror.approve(address(vault), 2);
        vm.prank(bob);
        vault.liquify(2, bob, uint64(block.timestamp));
        (uint256 headId, bool exists) = vault.nextBankedId();
        assertTrue(exists);
        assertEq(headId, 1);

        vm.prank(alice);
        base.approve(address(vault), UNIT);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IArcalsErrors.HeadChanged.selector, 2, 1));
        vault.reform(alice, 2, uint64(block.timestamp));
        assertEq(base.balanceOf(alice), UNIT);

        vm.prank(alice);
        assertEq(vault.reform(alice, 1, uint64(block.timestamp)), 1);
        assertEq(mirror.ownerOf(1), alice);
        (headId, exists) = vault.nextBankedId();
        assertTrue(exists);
        assertEq(headId, 2);

        vm.prank(alice);
        mirror.approve(address(vault), 1);
        vm.prank(alice);
        vault.liquify(1, alice, uint64(block.timestamp));
        assertEq(vault.queueAt(vault.tail() - 1), 1);
        _assertConservation();
    }

    function testOperatorCannotLiquifyAndStaleApprovalCannotTakeNewOwnersNft() public {
        address alice = makeAddr("approval-alice");
        address operator = makeAddr("approval-operator");
        address bob = makeAddr("approval-bob");
        _mint(alice);
        _register(1);
        _activate();
        vm.prank(alice);
        mirror.setApprovalForAll(operator, true);
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(IArcalsErrors.NotNftOwner.selector, 1, operator, alice)
        );
        vault.liquify(1, operator, uint64(block.timestamp));

        vm.prank(alice);
        mirror.approve(address(vault), 1);
        vm.prank(alice);
        mirror.transferFrom(alice, bob, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IArcalsErrors.NotNftOwner.selector, 1, alice, bob));
        vault.liquify(1, alice, uint64(block.timestamp));
        assertEq(mirror.getApproved(1), address(0));
        _assertConservation();
    }

    function testSharedLockStopsMintReceiverReentry() public {
        ReentrantMinter reentrant = new ReentrantMinter();
        SignedMint memory outer = _signedMint(address(reentrant), 0, keccak256("outer"));
        SignedMint memory nested = _signedMint(address(reentrant), 1, keccak256("nested"));
        bytes memory outerCall = _mintCall(outer);
        bytes memory nestedCall = _mintCall(nested);
        vm.deal(address(this), 2 * MINT_FEE);
        reentrant.execute{ value: 2 * MINT_FEE }(address(controller), outerCall, nestedCall);
        assertTrue(reentrant.attempted());
        assertFalse(reentrant.nestedSucceeded());
        assertEq(reentrant.nestedError(), IArcalsErrors.ProtocolReentrancy.selector);
        assertEq(core.mintedCount(), 1);
        assertEq(address(treasury).balance, MINT_FEE);
        _assertConservation();
    }

    function testSharedLockStopsReformReceiverReentryAndRejectorRollsBack() public {
        address alice = makeAddr("reform-alice");
        address bob = makeAddr("reform-bob");
        _mint(alice);
        _mint(bob);
        _register(1);
        _register(2);
        _activate();
        vm.startPrank(alice);
        mirror.approve(address(vault), 1);
        vault.liquify(1, alice, uint64(block.timestamp));
        vm.stopPrank();
        vm.startPrank(bob);
        mirror.approve(address(vault), 2);
        vault.liquify(2, bob, uint64(block.timestamp));
        vm.stopPrank();

        RejectingReceiver rejecting = new RejectingReceiver();
        vm.prank(alice);
        base.approve(address(vault), UNIT);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "NFT_REJECTED"));
        vault.reform(address(rejecting), 1, uint64(block.timestamp));
        assertEq(base.balanceOf(alice), UNIT);
        (uint256 id,) = vault.nextBankedId();
        assertEq(id, 1);

        ReentrantReformReceiver receiver = new ReentrantReformReceiver();
        vm.prank(bob);
        assertTrue(base.transfer(address(receiver), UNIT));
        receiver.approveArcl(base, address(vault), UNIT);
        receiver.configure(
            address(vault),
            abi.encodeCall(
                ArcalsVault.reform, (address(receiver), uint256(2), uint64(block.timestamp))
            )
        );
        vm.prank(alice);
        vault.reform(address(receiver), 1, uint64(block.timestamp));
        assertTrue(receiver.attempted());
        assertFalse(receiver.nestedSucceeded());
        assertEq(receiver.nestedError(), IArcalsErrors.ProtocolReentrancy.selector);
        assertEq(mirror.ownerOf(1), address(receiver));
        _assertConservation();
    }

    function testMaliciousGovernanceUpgradeCannotCrossCoreOrReserveBoundaries() public {
        address originalOwner = makeAddr("upgrade-original-owner");
        _mint(originalOwner);
        MintControllerV2 nextImplementation = new MintControllerV2();
        bytes memory upgrade = abi.encodeCall(
            ProxyAdmin.upgradeAndCall,
            (
                ITransparentUpgradeableProxy(address(controller)),
                address(nextImplementation),
                bytes("")
            )
        );
        vm.prank(makeAddr("not-governance"));
        (bool unauthorizedUpgrade,) = address(proxyAdmin).call(upgrade);
        assertFalse(unauthorizedUpgrade);
        vm.prank(management);
        (bool upgradedOk,) = address(proxyAdmin).call(upgrade);
        assertTrue(upgradedOk);
        MintControllerV2 upgraded = MintControllerV2(payable(address(controller)));
        assertEq(upgraded.implementationVersion(), 2);

        vm.expectRevert(abi.encodeWithSelector(IArcalsErrors.WrongMintFee.selector, 0, MINT_FEE));
        upgraded.bypassWork(makeAddr("upgrade-target"), 0, keccak256("bad-fee"));
        vm.deal(address(this), MINT_FEE);
        uint256 secondId = upgraded.bypassWork{ value: MINT_FEE }(
            makeAddr("upgrade-target"), 0, keccak256("bypass-work")
        );
        assertEq(secondId, 2);
        assertEq(mirror.ownerOf(1), originalOwner);
        assertEq(mirror.datasetRoot(), datasetRoot);

        vm.expectRevert(
            abi.encodeWithSelector(IArcalsErrors.Unauthorized.selector, address(controller))
        );
        upgraded.attemptReserveMint();
        vm.expectRevert(
            abi.encodeWithSelector(IArcalsErrors.Unauthorized.selector, address(controller))
        );
        upgraded.attemptVaultRelease(address(this));
        _assertConservation();
    }

    function testPublicMintStopsAtNineHundredNinetyThousand() public {
        assertEq(core.MAX_ARCALS(), 1_000_000);
        assertEq(core.PUBLIC_MAX_ARCALS(), 990_000);
        _setIssued(core.PUBLIC_MAX_ARCALS() - 1, 0);

        address finalMinter = makeAddr("final-minter");
        (uint256 id,) = _mint(finalMinter);
        assertEq(id, 990_000);
        assertEq(mirror.ownerOf(id), finalMinter);
        _assertConservation();

        SignedMint memory overflow = _signedMint(finalMinter, 1, keccak256("sold-out"));
        vm.deal(finalMinter, MINT_FEE);
        vm.prank(finalMinter);
        vm.expectRevert(IArcalsErrors.SoldOut.selector);
        controller.mint{ value: MINT_FEE }(
            overflow.challenge,
            overflow.issuerSignature,
            overflow.certificate,
            overflow.verifierSignature
        );
        _assertConservation();
    }

    function _mintCall(SignedMint memory signed) private pure returns (bytes memory) {
        return abi.encodeCall(
            IMintController.mint,
            (signed.challenge, signed.issuerSignature, signed.certificate, signed.verifierSignature)
        );
    }
}

contract ArcalsInvariantHandler is Test {
    ARCLBase public immutable base;
    ArcalMirror public immutable mirror;
    ArcalsVault public immutable vault;
    address[4] public actors;

    constructor(
        ARCLBase base_,
        ArcalMirror mirror_,
        ArcalsVault vault_,
        address[4] memory actors_
    ) {
        base = base_;
        mirror = mirror_;
        vault = vault_;
        actors = actors_;
    }

    function transferArcl(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 balance = base.balanceOf(from);
        uint256 amount = bound(amountSeed, 0, balance);
        vm.prank(from);
        assertTrue(base.transfer(to, amount));
    }

    function transferNft(uint256 idSeed, uint256 toSeed) external {
        uint256 id = idSeed % actors.length + 1;
        address owner = mirror.ownerOf(id);
        if (owner == address(vault)) return;
        address to = actors[toSeed % actors.length];
        vm.prank(owner);
        mirror.transferFrom(owner, to, id);
    }

    function changeNftApproval(uint256 idSeed, uint256 operatorSeed) external {
        uint256 id = idSeed % actors.length + 1;
        address owner = mirror.ownerOf(id);
        if (owner == address(vault)) return;
        vm.prank(owner);
        mirror.approve(actors[operatorSeed % actors.length], id);
    }

    function liquify(uint256 idSeed, uint256 recipientSeed) external {
        uint256 id = idSeed % actors.length + 1;
        address owner = mirror.ownerOf(id);
        if (owner == address(vault)) return;
        vm.startPrank(owner);
        mirror.approve(address(vault), id);
        vault.liquify(id, actors[recipientSeed % actors.length], uint64(block.timestamp));
        vm.stopPrank();
    }

    function reform(uint256 callerSeed, uint256 recipientSeed, bool protectHead) external {
        address caller = actors[callerSeed % actors.length];
        if (base.balanceOf(caller) < vault.unit()) return;
        (uint256 headId, bool exists) = vault.nextBankedId();
        if (!exists) return;
        vm.startPrank(caller);
        base.approve(address(vault), vault.unit());
        vault.reform(
            actors[recipientSeed % actors.length], protectHead ? headId : 0, uint64(block.timestamp)
        );
        vm.stopPrank();
    }

    function attemptDirectVaultTransfers(uint256 actorSeed, uint256 idSeed) external {
        address actor = actors[actorSeed % actors.length];
        if (base.balanceOf(actor) != 0) {
            vm.prank(actor);
            (bool tokenSuccess,) =
                address(base).call(abi.encodeCall(ARCLBase.transfer, (address(vault), uint256(1))));
            assertFalse(tokenSuccess, "nonzero direct ARCL transfer succeeded");
        }

        uint256 id = idSeed % actors.length + 1;
        address owner = mirror.ownerOf(id);
        if (owner != address(vault)) {
            vm.prank(owner);
            (bool nftSuccess,) = address(mirror)
                .call(abi.encodeCall(IERC721.transferFrom, (owner, address(vault), id)));
            assertFalse(nftSuccess, "direct NFT transfer succeeded");
        }
    }
}

contract ArcalsInvariantTest is ArcalsTestBase {
    ArcalsInvariantHandler internal handler;
    address[4] internal actors;

    function setUp() public override {
        super.setUp();
        for (uint256 index = 0; index < actors.length; ++index) {
            actors[index] = makeAddr(string.concat("invariant-actor-", vm.toString(index)));
            _mint(actors[index]);
            _register(index + 1);
        }
        _activate();
        for (uint256 id = 1; id <= 2; ++id) {
            address owner = mirror.ownerOf(id);
            vm.prank(owner);
            mirror.approve(address(vault), id);
            vm.prank(owner);
            vault.liquify(id, owner, uint64(block.timestamp));
        }
        handler = new ArcalsInvariantHandler(base, mirror, vault, actors);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.transferArcl.selector;
        selectors[1] = handler.transferNft.selector;
        selectors[2] = handler.changeNftApproval.selector;
        selectors[3] = handler.liquify.selector;
        selectors[4] = handler.reform.selector;
        selectors[5] = handler.attemptDirectVaultTransfers.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        _assertConservation();
    }

    function invariantConservationAndQueueRemainExact() public view {
        _assertConservation();
        assertTrue(vault.conversionOpen());
        assertEq(vault.launchAuthority(), address(0));
        assertEq(base.mirrorERC721(), address(mirror));
        assertEq(mirror.baseERC20(), address(base));

        for (uint256 id = 1; id <= actors.length; ++id) {
            address owner = mirror.ownerOf(id);
            assertEq(vault.isBanked(id), owner == address(vault), "banked owner equivalence");
        }
        for (uint256 left = vault.head(); left < vault.tail(); ++left) {
            for (uint256 right = left + 1; right < vault.tail(); ++right) {
                assertTrue(vault.queueAt(left) != vault.queueAt(right), "duplicate FIFO id");
            }
        }
    }
}
