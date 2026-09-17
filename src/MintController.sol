// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import { IArcalsCore } from "./interfaces/IArcalsCore.sol";
import { IMintController } from "./interfaces/IMintController.sol";
import { ArcalsHashing } from "./shared/ArcalsHashing.sol";
import { ArcalsTypes } from "./shared/ArcalsTypes.sol";

/// @notice Upgradeable work-verification entry point. Asset rules remain in immutable Core.
contract MintController is Initializable, IMintController {
    uint32 public constant PROTOCOL_VERSION = 1;
    uint64 public constant EPOCH_SECONDS = 1 days;
    uint64 public constant KEY_LEAD_SECONDS = 15 minutes;
    uint64 public constant MAX_CHALLENGE_TTL = 20 minutes;
    uint64 public constant MAX_CERTIFICATE_TTL = 5 minutes;
    /// @dev A work config may be announced at most this many epochs ahead of the current one.
    uint64 public constant MAX_CONFIG_HORIZON_EPOCHS = 30;

    address public override core;
    address public override governance;
    /// @dev Initial guardian recorded at initialization. Pause authority is read from Core so
    ///      a single governance Core.setGuardian rotation revokes both pause entry points.
    address private _initialGuardian;
    address public override epochPublisher;
    uint64 public override workGenesisTime;
    address public override issuerSigner;
    address public override verifierSigner;
    uint64 public override signerVersion;

    struct WorkConfigRecord {
        ArcalsTypes.WorkConfigV1 config;
        bool exists;
    }

    struct EpochRecord {
        ArcalsTypes.EpochCommitment commitment;
        bool exists;
    }

    mapping(bytes32 digest => WorkConfigRecord record) private _workConfigs;
    mapping(uint64 epochId => EpochRecord record) private _epochs;
    /// @dev Work configs in strictly increasing effectiveEpoch order. Appended after all
    ///      earlier storage so existing proxy layouts stay compatible.
    bytes32[] private _configHistory;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address core_,
        address governance_,
        address guardian_,
        address epochPublisher_,
        uint64 workGenesisTime_,
        address issuerSigner_,
        address verifierSigner_,
        uint64 signerVersion_
    ) external initializer {
        if (
            core_ == address(0) || governance_ == address(0) || guardian_ == address(0)
                || epochPublisher_ == address(0) || issuerSigner_ == address(0)
                || verifierSigner_ == address(0)
        ) revert ZeroAddress();
        if (signerVersion_ == 0 || workGenesisTime_ == 0) revert InvalidWork();
        core = core_;
        governance = governance_;
        _initialGuardian = guardian_;
        epochPublisher = epochPublisher_;
        workGenesisTime = workGenesisTime_;
        issuerSigner = issuerSigner_;
        verifierSigner = verifierSigner_;
        signerVersion = signerVersion_;
        emit SignersConfigured(issuerSigner_, verifierSigner_, signerVersion_);
        emit EpochPublisherConfigured(epochPublisher_);
    }

    function mint(
        ArcalsTypes.Challenge calldata challenge,
        bytes calldata issuerSignature,
        ArcalsTypes.WorkCertificate calldata certificate,
        bytes calldata verifierSignature
    ) external payable override returns (uint256 id) {
        return _mint(challenge, issuerSignature, certificate, verifierSignature);
    }

    function mintEncoded(bytes calldata payload) external payable override returns (uint256 id) {
        (
            ArcalsTypes.Challenge memory challenge,
            bytes memory issuerSignature,
            ArcalsTypes.WorkCertificate memory certificate,
            bytes memory verifierSignature
        ) = abi.decode(payload, (ArcalsTypes.Challenge, bytes, ArcalsTypes.WorkCertificate, bytes));
        return _mint(challenge, issuerSignature, certificate, verifierSignature);
    }

    function _mint(
        ArcalsTypes.Challenge memory challenge,
        bytes memory issuerSignature,
        ArcalsTypes.WorkCertificate memory certificate,
        bytes memory verifierSignature
    ) private returns (uint256 id) {
        bytes32 receiptHash = _validateMint(
            challenge, issuerSignature, certificate, verifierSignature, msg.value
        );
        id = IArcalsCore(core).issue{ value: msg.value }(
            challenge.minter, challenge.mintNonce, receiptHash
        );
        emit WorkAccepted(
            receiptHash,
            challenge.challengeId,
            challenge.epochId,
            challenge.signerVersion,
            challenge.configDigest
        );
    }

    function _validateMint(
        ArcalsTypes.Challenge memory challenge,
        bytes memory issuerSignature,
        ArcalsTypes.WorkCertificate memory certificate,
        bytes memory verifierSignature,
        uint256 suppliedValue
    ) private view returns (bytes32 receiptHash) {
        if (suppliedValue != IArcalsCore(core).MINT_FEE_NATIVE()) {
            revert WrongMintFee(suppliedValue, IArcalsCore(core).MINT_FEE_NATIVE());
        }
        if (IArcalsCore(core).mintPaused()) revert MintIsPaused();
        if (challenge.protocolVersion != PROTOCOL_VERSION) {
            revert UnsupportedProtocolVersion(challenge.protocolVersion);
        }
        if (certificate.protocolVersion != PROTOCOL_VERSION) {
            revert UnsupportedProtocolVersion(certificate.protocolVersion);
        }
        if (msg.sender != challenge.minter) revert WrongMinter(msg.sender, challenge.minter);
        if (challenge.mintFee != suppliedValue) {
            revert WrongMintFee(challenge.mintFee, suppliedValue);
        }
        if (challenge.signerVersion != signerVersion || certificate.signerVersion != signerVersion) revert InvalidSignature();
        if (IArcalsCore(core).nextMintNonce(challenge.minter) != challenge.mintNonce) {
            revert NonceConsumed(challenge.minter, challenge.mintNonce);
        }

        WorkConfigRecord storage configRecord = _workConfigs[challenge.configDigest];
        if (!configRecord.exists) revert EpochUnavailable(challenge.epochId);
        EpochRecord storage epochRecord = _epochs[challenge.epochId];
        if (!epochRecord.exists) revert EpochUnavailable(challenge.epochId);
        ArcalsTypes.EpochCommitment storage epochCommitment = epochRecord.commitment;
        if (epochCommitment.configDigest != challenge.configDigest) revert InvalidWork();
        if (
            block.timestamp < epochCommitment.validFrom
                || block.timestamp >= epochCommitment.validUntil
        ) {
            revert EpochExpired(challenge.epochId);
        }

        ArcalsTypes.WorkConfigV1 storage config = configRecord.config;
        _validateChallenge(challenge, config, epochCommitment, issuerSignature);
        bytes32 challengeHash = ArcalsHashing.hashChallenge(challenge);
        _validateCertificate(
            certificate, challengeHash, challenge, config, epochCommitment, verifierSignature
        );

        receiptHash = ArcalsHashing.typedDataDigest(
            ArcalsHashing.domainSeparator(block.chainid, address(this)),
            ArcalsHashing.hashWorkCertificate(certificate)
        );
        uint256 consumedId = IArcalsCore(core).issuedId(receiptHash);
        if (consumedId != 0) revert ReceiptConsumed(receiptHash, consumedId);
    }

    function pauseMint() external override {
        if (msg.sender != IArcalsCore(core).guardian()) revert Unauthorized(msg.sender);
        IArcalsCore(core).pauseMint();
    }

    function configureSigners(address issuerSigner_, address verifierSigner_, uint64 signerVersion_)
        external
        override
        onlyGovernance
    {
        if (issuerSigner_ == address(0) || verifierSigner_ == address(0)) revert ZeroAddress();
        if (signerVersion_ <= signerVersion) revert InvalidWork();
        issuerSigner = issuerSigner_;
        verifierSigner = verifierSigner_;
        signerVersion = signerVersion_;
        emit SignersConfigured(issuerSigner_, verifierSigner_, signerVersion_);
    }

    /// @notice The pause guardian. Before Core exists (during factory construction) this is the
    ///         initialization value; afterwards it is always Core's governance-rotatable guardian.
    function guardian() external view override returns (address) {
        return core.code.length == 0 ? _initialGuardian : IArcalsCore(core).guardian();
    }

    function configureEpochPublisher(address epochPublisher_) external override onlyGovernance {
        if (epochPublisher_ == address(0)) revert ZeroAddress();
        epochPublisher = epochPublisher_;
        emit EpochPublisherConfigured(epochPublisher_);
    }

    function registerWorkConfig(ArcalsTypes.WorkConfigV1 calldata config)
        external
        override
        onlyGovernance
        returns (bytes32 configDigest)
    {
        if (
            config.protocolVersion != PROTOCOL_VERSION || config.epochSeconds != EPOCH_SECONDS
                || config.keyLeadSeconds != KEY_LEAD_SECONDS || config.maxChallengeTtl == 0
                || config.maxChallengeTtl > MAX_CHALLENGE_TTL || config.maxCertificateTtl == 0
                || config.maxCertificateTtl > MAX_CERTIFICATE_TTL || config.target == 0
                || config.algorithmId == bytes32(0) || config.parameterDigest == bytes32(0)
        ) revert InvalidWork();
        configDigest = ArcalsHashing.hashWorkConfig(config);
        if (_workConfigs[configDigest].exists) revert InvalidWork();
        uint256 effectiveFrom =
            uint256(workGenesisTime) + uint256(config.effectiveEpoch) * uint256(EPOCH_SECONDS);
        uint256 currentEpoch = block.timestamp <= workGenesisTime
            ? 0
            : (block.timestamp - workGenesisTime) / uint256(EPOCH_SECONDS);
        if (
            effectiveFrom + uint256(EPOCH_SECONDS) > type(uint64).max
                || uint256(config.effectiveEpoch) > currentEpoch + MAX_CONFIG_HORIZON_EPOCHS
        ) revert InvalidWork();

        uint256 historyLength = _configHistory.length;
        if (historyLength != 0) {
            // Later configs only take effect at a future epoch boundary, announced at least one
            // full epoch before that epoch starts, so published epochs never change rules.
            if (effectiveFrom < block.timestamp + uint256(EPOCH_SECONDS)) revert InvalidWork();
            uint64 latestEffectiveEpoch =
                _workConfigs[_configHistory[historyLength - 1]].config.effectiveEpoch;
            if (config.effectiveEpoch < latestEffectiveEpoch) revert InvalidWork();
            if (config.effectiveEpoch == latestEffectiveEpoch) {
                // Replacing a still-pending config for the same epoch. The lead-time check above
                // guarantees no epoch at or after it can have been registered yet.
                _configHistory.pop();
            }
        }
        _workConfigs[configDigest] = WorkConfigRecord({ config: config, exists: true });
        _configHistory.push(configDigest);
        emit WorkConfigRegistered(configDigest, config.effectiveEpoch);
    }

    function registerEpoch(ArcalsTypes.EpochCommitment calldata commitment) external override {
        if (msg.sender != epochPublisher) revert Unauthorized(msg.sender);
        if (_epochs[commitment.epochId].exists) revert InvalidWork();
        WorkConfigRecord storage configRecord = _workConfigs[commitment.configDigest];
        if (!configRecord.exists) revert EpochUnavailable(commitment.epochId);
        (bytes32 activeDigest, bool hasActive) = _activeConfigDigest(commitment.epochId);
        if (!hasActive || activeDigest != commitment.configDigest) revert InvalidWork();
        ArcalsTypes.WorkConfigV1 storage config = configRecord.config;
        uint256 expectedValidFrom =
            uint256(workGenesisTime) + uint256(commitment.epochId) * uint256(config.epochSeconds);
        if (
            expectedValidFrom > type(uint64).max || commitment.validFrom != expectedValidFrom
                || commitment.validFrom < config.keyLeadSeconds
                || commitment.validUntil != commitment.validFrom + config.epochSeconds
                || block.timestamp < commitment.validFrom - config.keyLeadSeconds
                || block.timestamp >= commitment.validUntil
        ) revert InvalidWork();
        bytes32 expectedKey = ArcalsHashing.deriveEpochKey(
            block.chainid,
            address(this),
            commitment.epochId,
            commitment.anchorBlockNumber,
            commitment.anchorBlockHash
        );
        if (commitment.epochKey != expectedKey) revert InvalidWork();

        _epochs[commitment.epochId] = EpochRecord({ commitment: commitment, exists: true });
        emit EpochRegistered(
            commitment.epochId,
            commitment.configDigest,
            commitment.epochKey,
            commitment.validFrom,
            commitment.validUntil,
            commitment.anchorBlockNumber,
            commitment.anchorBlockHash
        );
    }

    /// @notice The only config an epoch may bind: the latest one with effectiveEpoch <= epochId.
    function activeWorkConfigDigest(uint64 epochId)
        external
        view
        override
        returns (bytes32 configDigest, bool exists)
    {
        return _activeConfigDigest(epochId);
    }

    function workConfigCount() external view override returns (uint256) {
        return _configHistory.length;
    }

    function _activeConfigDigest(uint64 epochId)
        private
        view
        returns (bytes32 configDigest, bool exists)
    {
        for (uint256 index = _configHistory.length; index != 0; --index) {
            bytes32 digest = _configHistory[index - 1];
            if (_workConfigs[digest].config.effectiveEpoch <= epochId) return (digest, true);
        }
        return (bytes32(0), false);
    }

    function workConfig(bytes32 configDigest)
        external
        view
        override
        returns (ArcalsTypes.WorkConfigV1 memory config, bool exists)
    {
        WorkConfigRecord storage record = _workConfigs[configDigest];
        return (record.config, record.exists);
    }

    function epoch(uint64 epochId)
        external
        view
        override
        returns (ArcalsTypes.EpochCommitment memory commitment, bool exists)
    {
        EpochRecord storage record = _epochs[epochId];
        return (record.commitment, record.exists);
    }

    modifier onlyGovernance() {
        if (msg.sender != governance) revert Unauthorized(msg.sender);
        _;
    }

    function _validateChallenge(
        ArcalsTypes.Challenge memory challenge,
        ArcalsTypes.WorkConfigV1 storage config,
        ArcalsTypes.EpochCommitment storage commitment,
        bytes memory signature
    ) private view {
        if (
            challenge.validAfter < commitment.validFrom
                || challenge.expiresAt > commitment.validUntil
                || challenge.expiresAt <= challenge.validAfter
                || challenge.expiresAt - challenge.validAfter > config.maxChallengeTtl
        ) {
            revert ChallengeExpired(challenge.expiresAt);
        }
        if (block.timestamp < challenge.validAfter || block.timestamp >= challenge.expiresAt) {
            revert ChallengeExpired(challenge.expiresAt);
        }
        if (
            challenge.challengeInput
                != ArcalsHashing.computeChallengeInput(block.chainid, address(this), challenge)
        ) revert InvalidWork();
        bytes32 digest = ArcalsHashing.typedDataDigest(
            ArcalsHashing.domainSeparator(block.chainid, address(this)),
            ArcalsHashing.hashChallenge(challenge)
        );
        if (!_isSignatureFrom(digest, signature, issuerSigner)) revert InvalidSignature();
    }

    function _validateCertificate(
        ArcalsTypes.WorkCertificate memory certificate,
        bytes32 challengeHash,
        ArcalsTypes.Challenge memory challenge,
        ArcalsTypes.WorkConfigV1 storage config,
        ArcalsTypes.EpochCommitment storage commitment,
        bytes memory signature
    ) private view {
        if (certificate.challengeHash != challengeHash) revert InvalidWork();
        if (
            certificate.issuedAt < challenge.validAfter || certificate.issuedAt > block.timestamp
                || certificate.expiresAt <= certificate.issuedAt
                || certificate.expiresAt - certificate.issuedAt > config.maxCertificateTtl
                || certificate.expiresAt > challenge.expiresAt
                || certificate.expiresAt > commitment.validUntil
        ) revert CertificateExpired(certificate.expiresAt);
        if (block.timestamp >= certificate.expiresAt) {
            revert CertificateExpired(certificate.expiresAt);
        }
        if (uint256(certificate.randomxHash) > config.target) revert InvalidWork();
        bytes32 digest = ArcalsHashing.typedDataDigest(
            ArcalsHashing.domainSeparator(block.chainid, address(this)),
            ArcalsHashing.hashWorkCertificate(certificate)
        );
        if (!_isSignatureFrom(digest, signature, verifierSigner)) revert InvalidSignature();
    }

    function _isSignatureFrom(bytes32 digest, bytes memory signature, address expectedSigner)
        private
        pure
        returns (bool)
    {
        (address recovered, ECDSA.RecoverError error,) = ECDSA.tryRecover(digest, signature);
        return error == ECDSA.RecoverError.NoError && recovered == expectedSigner;
    }
}
