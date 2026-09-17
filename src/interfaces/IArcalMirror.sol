// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {
    IERC721Metadata
} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import { IERC4906 } from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import { IArcalsErrors } from "./IArcalsErrors.sol";

interface IArcalMirror is IERC721Metadata, IERC4906, IArcalsErrors {
    event ContentRegistered(uint256 indexed id, bytes32 indexed contentHash, bytes packedDigits);
    event MetadataRendererUpdated(address indexed previousRenderer, address indexed newRenderer);
    event DefaultRoyaltyUpdated(address indexed receiver, uint96 royaltyBps);
    /// @notice ERC-7572 collection metadata refresh signal.
    event ContractURIUpdated();

    function baseERC20() external view returns (address);
    function protocolMint(address owner, uint256 id) external;
    function protocolMintBatch(address owner, uint256 firstId, uint256 count) external;
    function vaultBankFrom(address owner, uint256 id) external;
    function vaultReleaseTo(address recipient, uint256 id) external;
    function registerContent(uint256 id, bytes calldata packedDigits, bytes32[] calldata proof)
        external;
    function contentRegistered(uint256 id) external view returns (bool);
    function contentHash(uint256 id) external view returns (bytes32);
    /// @notice The registered 180-byte packed digits of an Arcal, or empty before registration.
    function contentDigits(uint256 id) external view returns (bytes memory);
    function piRange(uint256 id) external pure returns (uint256 startDigit, uint256 endDigit);
    function datasetRoot() external view returns (bytes32);

    /// @notice ERC-2981 royalty information (the Mirror advertises 0x2a55205a).
    function royaltyInfo(uint256 tokenId, uint256 salePrice)
        external
        view
        returns (address receiver, uint256 royaltyAmount);
    function contractURI() external view returns (string memory);
    function metadataRenderer() external view returns (address);
    function setMetadataRenderer(address renderer) external;
    function setDefaultRoyalty(address receiver, uint96 royaltyBps) external;
    function deleteDefaultRoyalty() external;
}
