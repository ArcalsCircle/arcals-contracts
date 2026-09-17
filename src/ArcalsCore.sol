// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IARCLBase } from "./interfaces/IARCLBase.sol";
import { IArcalMirror } from "./interfaces/IArcalMirror.sol";
import { IArcalsCore } from "./interfaces/IArcalsCore.sol";
import { IRevenueTreasury } from "./interfaces/IRevenueTreasury.sol";

/// @notice Immutable issuance kernel and shared issuance/conversion lock.
contract ArcalsCore is IArcalsCore {
    uint256 public constant override MAX_ARCALS = 1_000_000;
    uint256 public constant override MINT_FEE_NATIVE = 0.1 ether;
    uint256 public constant override UNIT = 360 ether;
    /// @notice Public Mint issues IDs 1..990,000. The final 10,000 IDs are reserved.
    uint256 public constant override PUBLIC_MAX_ARCALS = 990_000;
    uint256 public constant override RESERVE_FIRST_ID = 990_001;
    uint256 public constant override RESERVE_COUNT = 10_000;
    uint256 public constant override MAX_RESERVE_BATCH = 500;

    address public immutable override controller;
    address public immutable override base;
    address public immutable override mirror;
    address public immutable override vault;
    address public immutable override treasury;
    address public immutable override governance;
    /// @notice Fixed at deployment; reserved Arcals can only ever be issued to this address.
    address public immutable override reserveRecipient;

    uint256 public override mintedCount;
    bool public override mintPaused = true;
    mapping(address minter => uint256 nonce) public override nextMintNonce;
    mapping(bytes32 receiptHash => uint256 id) public override issuedId;

    uint256 private _protocolLock;
    /// @notice Pause-only role. Rotatable by governance (the management multisig) so a compromised
    ///         guardian cannot keep new Mint paused forever. Declared last to keep the
    ///         original storage layout.
    address public override guardian;
    uint256 public override reserveMintedCount;

    constructor(
        address controller_,
        address base_,
        address mirror_,
        address vault_,
        address treasury_,
        address guardian_,
        address governance_,
        address reserveRecipient_
    ) {
        if (
            controller_ == address(0) || base_ == address(0) || mirror_ == address(0)
                || vault_ == address(0) || treasury_ == address(0) || guardian_ == address(0)
                || governance_ == address(0) || reserveRecipient_ == address(0)
        ) revert ZeroAddress();
        if (
            reserveRecipient_ == address(this) || reserveRecipient_ == controller_
                || reserveRecipient_ == base_ || reserveRecipient_ == mirror_
                || reserveRecipient_ == vault_ || reserveRecipient_ == treasury_
        ) revert Unauthorized(reserveRecipient_);
        controller = controller_;
        base = base_;
        mirror = mirror_;
        vault = vault_;
        treasury = treasury_;
        guardian = guardian_;
        governance = governance_;
        reserveRecipient = reserveRecipient_;
    }

    function issue(address minter, uint256 mintNonce, bytes32 receiptHash)
        external
        payable
        override
        returns (uint256 id)
    {
        if (msg.sender != controller) revert Unauthorized(msg.sender);
        if (_protocolLock != 0) revert ProtocolReentrancy();
        if (mintPaused) revert MintIsPaused();
        if (msg.value != MINT_FEE_NATIVE) revert WrongMintFee(msg.value, MINT_FEE_NATIVE);
        if (_isProtocolAddress(minter)) revert Unauthorized(minter);
        if (mintedCount == PUBLIC_MAX_ARCALS) revert SoldOut();

        uint256 expectedNonce = nextMintNonce[minter];
        if (mintNonce != expectedNonce) revert NonceConsumed(minter, mintNonce);
        uint256 priorId = issuedId[receiptHash];
        if (receiptHash == bytes32(0) || priorId != 0) {
            revert ReceiptConsumed(receiptHash, priorId);
        }

        _protocolLock = 1;
        id = mintedCount + 1;
        mintedCount = id;
        nextMintNonce[minter] = expectedNonce + 1;
        issuedId[receiptHash] = id;

        IARCLBase(base).protocolMintReserve(1);
        IRevenueTreasury(treasury).depositMint{ value: msg.value }(id);
        IArcalMirror(mirror).protocolMint(minter, id);

        emit Issued(id, minter, receiptHash, mintNonce, msg.value, UNIT);
        _protocolLock = 0;
    }

    /// @notice Issues the next reserved Arcals to the fixed reserve recipient. Anyone may pay the
    ///         Gas: the recipient, IDs and total count are fixed, so calling it only advances
    ///         issuance that is already committed. Independent of Mint pause and fee.
    function mintReserve(uint256 count)
        external
        override
        returns (uint256 firstId, uint256 lastId)
    {
        if (_protocolLock != 0) {
            revert ProtocolReentrancy();
        }
        uint256 issued = reserveMintedCount;
        uint256 remaining = RESERVE_COUNT - issued;
        if (remaining == 0) revert ReserveExhausted();
        if (count == 0 || count > MAX_RESERVE_BATCH) revert InvalidReserveBatch(count);
        if (count > remaining) count = remaining;

        _protocolLock = 1;
        firstId = RESERVE_FIRST_ID + issued;
        lastId = firstId + count - 1;
        reserveMintedCount = issued + count;

        IARCLBase(base).protocolMintReserve(count);
        IArcalMirror(mirror).protocolMintBatch(reserveRecipient, firstId, count);

        emit ReserveIssued(firstId, lastId, reserveRecipient, count * UNIT);
        _protocolLock = 0;
    }

    function pauseMint() external override {
        if (msg.sender != guardian && msg.sender != controller) revert Unauthorized(msg.sender);
        if (!mintPaused) {
            mintPaused = true;
            emit MintPaused(msg.sender);
        }
    }

    function resumeMint() external override {
        if (msg.sender != governance) revert Unauthorized(msg.sender);
        if (mintPaused) {
            mintPaused = false;
            emit MintResumed(msg.sender);
        }
    }

    function setGuardian(address newGuardian) external override {
        if (msg.sender != governance) revert Unauthorized(msg.sender);
        if (newGuardian == address(0)) revert ZeroAddress();
        address previousGuardian = guardian;
        guardian = newGuardian;
        emit GuardianUpdated(previousGuardian, newGuardian);
    }

    function enterConversion() external override {
        if (msg.sender != vault) revert Unauthorized(msg.sender);
        if (_protocolLock != 0) revert ProtocolReentrancy();
        _protocolLock = 1;
    }

    function exitConversion() external override {
        if (msg.sender != vault) revert Unauthorized(msg.sender);
        if (_protocolLock != 1) revert ProtocolReentrancy();
        _protocolLock = 0;
    }

    function protocolLocked() external view returns (bool) {
        return _protocolLock != 0;
    }

    function _isProtocolAddress(address account) private view returns (bool) {
        return account == address(0) || account == address(this) || account == controller
            || account == base || account == mirror || account == vault || account == treasury;
    }
}
