// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Replaceable presentation module. It can only change what wallets display; the
///         Mirror falls back to built-in metadata whenever a renderer reverts or returns "".
interface IArcalsMetadataRenderer {
    function tokenURI(uint256 id) external view returns (string memory);
    function contractURI() external view returns (string memory);
}
