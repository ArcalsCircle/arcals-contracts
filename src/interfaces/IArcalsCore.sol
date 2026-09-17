// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IArcalsErrors } from "./IArcalsErrors.sol";

interface IArcalsCore is IArcalsErrors {
    event Issued(
        uint256 indexed id,
        address indexed minter,
        bytes32 indexed receiptHash,
        uint256 mintNonce,
        uint256 feeNative,
        uint256 arclUnit
    );
    event MintPaused(address indexed caller);
    event MintResumed(address indexed caller);
    event GuardianUpdated(address indexed previousGuardian, address indexed newGuardian);
    /// @notice The reserved IDs firstId..lastId were issued to the fixed reserve recipient, each
    ///         with exactly one UNIT of ARCL created in the Vault. No fee and no work apply.
    event ReserveIssued(
        uint256 indexed firstId,
        uint256 indexed lastId,
        address indexed recipient,
        uint256 arclAmount
    );

    function issue(address minter, uint256 mintNonce, bytes32 receiptHash)
        external
        payable
        returns (uint256 id);
    function nextMintNonce(address minter) external view returns (uint256);
    function issuedId(bytes32 receiptHash) external view returns (uint256);
    /// @notice Arcals issued through public Mint (IDs 1..mintedCount).
    function mintedCount() external view returns (uint256);
    /// @notice Reserved Arcals issued so far (IDs RESERVE_FIRST_ID..RESERVE_FIRST_ID+count-1).
    function reserveMintedCount() external view returns (uint256);
    function reserveRecipient() external view returns (address);
    function mintReserve(uint256 count) external returns (uint256 firstId, uint256 lastId);
    function mintPaused() external view returns (bool);
    function pauseMint() external;
    function resumeMint() external;
    function setGuardian(address newGuardian) external;
    function guardian() external view returns (address);
    function governance() external view returns (address);
    function enterConversion() external;
    function exitConversion() external;
    function MAX_ARCALS() external view returns (uint256);
    function PUBLIC_MAX_ARCALS() external view returns (uint256);
    function RESERVE_FIRST_ID() external view returns (uint256);
    function RESERVE_COUNT() external view returns (uint256);
    function MAX_RESERVE_BATCH() external view returns (uint256);
    function MINT_FEE_NATIVE() external view returns (uint256);
    function UNIT() external view returns (uint256);
    function controller() external view returns (address);
    function base() external view returns (address);
    function mirror() external view returns (address);
    function vault() external view returns (address);
    function treasury() external view returns (address);
}
