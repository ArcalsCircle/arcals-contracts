// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IArcalsErrors {
    error Unauthorized(address caller);
    error ZeroAddress();
    error UnsupportedProtocolVersion(uint32 actual);
    error WrongMintFee(uint256 actual, uint256 expected);
    error WrongMinter(address caller, address minter);
    error MintIsPaused();
    error SoldOut();
    error NonceConsumed(address minter, uint256 nonce);
    error ReceiptConsumed(bytes32 receiptHash, uint256 issuedId);
    error InvalidSignature();
    error InvalidWork();
    error EpochUnavailable(uint64 epochId);
    error EpochExpired(uint64 epochId);
    error ChallengeExpired(uint64 expiresAt);
    error CertificateExpired(uint64 expiresAt);
    error ContentNotRegistered(uint256 id);
    error InvalidContentProof(uint256 id);
    error NotNftOwner(uint256 id, address caller, address owner);
    error ConversionsClosed();
    error VaultEmpty();
    error HeadChanged(uint256 expected, uint256 actual);
    error DeadlineExpired(uint64 deadline);
    error InsufficientAllowance(address owner, uint256 actual, uint256 required);
    error DirectVaultTransferForbidden();
    error ProtocolReentrancy();
    error ReserveExhausted();
    error InvalidReserveBatch(uint256 count);
}
