// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { ERC721Utils } from "@openzeppelin/contracts/token/ERC721/utils/ERC721Utils.sol";
import { ERC2981 } from "@openzeppelin/contracts/token/common/ERC2981.sol";
import { IERC165 } from "@openzeppelin/contracts/interfaces/IERC165.sol";
import {
    IERC721Metadata
} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import { Base64 } from "@openzeppelin/contracts/utils/Base64.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";

import { IArcalMirror } from "./interfaces/IArcalMirror.sol";
import { IArcalsCore } from "./interfaces/IArcalsCore.sol";
import { IArcalsMetadataRenderer } from "./interfaces/IArcalsMetadataRenderer.sol";
import { PiProof } from "./shared/PiProof.sol";

/// @notice Immutable NFT side and canonical Pi content registry.
/// @dev Asset rules are immutable. Only presentation (renderer) and ERC-2981 royalty
///      information are governed by the management multisig, and neither is read by any
///      transfer, Mint, content or conversion path.
contract ArcalMirror is ERC721, ERC2981, IArcalMirror {
    using Strings for uint256;

    bytes4 private constant ERC4906_INTERFACE_ID = 0x49064906;
    uint96 public constant MAX_ROYALTY_BPS = 1000;
    /// @dev Gas always kept back from the renderer so built-in metadata can still be built.
    uint256 public constant RENDER_FALLBACK_GAS = 1_000_000;
    /// @dev Larger renderer responses are treated as failures instead of being copied.
    uint256 public constant MAX_RENDER_RETURN_BYTES = 256_000;

    address public immutable core;
    address public immutable override baseERC20;
    address public immutable vault;
    address public immutable governance;
    bytes32 public immutable override datasetRoot;

    mapping(uint256 id => bool registered) public override contentRegistered;
    mapping(uint256 id => bytes32 hash) public override contentHash;
    /// @dev The 180 packed digit bytes in six words (the last word holds 20 bytes, left-aligned),
    ///      kept so renderers can draw the digits without event history.
    mapping(uint256 id => bytes32[6] words) private _digitWords;
    address public override metadataRenderer;

    error RoyaltyTooHigh(uint96 royaltyBps, uint96 maxRoyaltyBps);

    constructor(
        address core_,
        address base_,
        address vault_,
        bytes32 datasetRoot_,
        address governance_
    ) ERC721("Arcals", "ARCAL") {
        if (
            core_ == address(0) || base_ == address(0) || vault_ == address(0)
                || governance_ == address(0)
        ) {
            revert ZeroAddress();
        }
        if (datasetRoot_ == bytes32(0)) revert InvalidContentProof(0);
        core = core_;
        baseERC20 = base_;
        vault = vault_;
        datasetRoot = datasetRoot_;
        governance = governance_;
    }

    modifier onlyGovernance() {
        if (msg.sender != governance) revert Unauthorized(msg.sender);
        _;
    }

    function protocolMint(address owner, uint256 id) external override {
        if (msg.sender != core) revert Unauthorized(msg.sender);
        _safeMint(owner, id);
    }

    function protocolMintBatch(address owner, uint256 firstId, uint256 count) external override {
        if (msg.sender != core) revert Unauthorized(msg.sender);
        for (uint256 id = firstId; id < firstId + count; ++id) {
            _safeMint(owner, id);
        }
    }

    function vaultBankFrom(address owner, uint256 id) external override {
        if (msg.sender != vault) revert Unauthorized(msg.sender);
        address actualOwner = ownerOf(id);
        if (actualOwner != owner) revert NotNftOwner(id, owner, actualOwner);
        _checkAuthorized(owner, vault, id);
        _transfer(owner, vault, id);
        ERC721Utils.checkOnERC721Received(vault, owner, vault, id, "");
        emit MetadataUpdate(id);
    }

    function vaultReleaseTo(address recipient, uint256 id) external override {
        if (msg.sender != vault) revert Unauthorized(msg.sender);
        _safeTransfer(vault, recipient, id);
        emit MetadataUpdate(id);
    }

    function registerContent(uint256 id, bytes calldata packedDigits, bytes32[] calldata proof)
        external
        override
    {
        // Arcals are never burned, so an owner exists exactly for issued public and reserved IDs.
        if (_ownerOf(id) == address(0)) revert InvalidContentProof(id);
        if (!PiProof.isValidPackedDigits(packedDigits) || proof.length != 20) {
            revert InvalidContentProof(id);
        }

        bytes32 canonicalHash = keccak256(packedDigits);
        if (PiProof.rootFromProof(id, canonicalHash, proof) != datasetRoot) {
            revert InvalidContentProof(id);
        }
        if (contentRegistered[id]) return;

        contentRegistered[id] = true;
        contentHash[id] = canonicalHash;
        bytes32[6] storage words = _digitWords[id];
        for (uint256 index = 0; index < 6; ++index) {
            words[index] = bytes32(packedDigits[index * 32:index == 5 ? 180 : (index + 1) * 32]);
        }
        emit ContentRegistered(id, canonicalHash, packedDigits);
        emit MetadataUpdate(id);
    }

    function contentDigits(uint256 id) external view override returns (bytes memory packed) {
        if (!contentRegistered[id]) return "";
        packed = new bytes(180);
        bytes32[6] storage words = _digitWords[id];
        for (uint256 index = 0; index < 6; ++index) {
            bytes32 word = words[index];
            uint256 length = index == 5 ? 20 : 32;
            for (uint256 offset = 0; offset < length; ++offset) {
                packed[index * 32 + offset] = word[offset];
            }
        }
    }

    function piRange(uint256 id)
        external
        pure
        override
        returns (uint256 startDigit, uint256 endDigit)
    {
        return PiProof.piRange(id);
    }

    function setMetadataRenderer(address renderer) external override onlyGovernance {
        if (renderer != address(0) && renderer.code.length == 0) revert Unauthorized(renderer);
        address previousRenderer = metadataRenderer;
        metadataRenderer = renderer;
        emit MetadataRendererUpdated(previousRenderer, renderer);
        emit BatchMetadataUpdate(1, PiProof.MAX_ARCALS);
        emit ContractURIUpdated();
    }

    function setDefaultRoyalty(address receiver, uint96 royaltyBps)
        external
        override
        onlyGovernance
    {
        if (royaltyBps > MAX_ROYALTY_BPS) {
            revert RoyaltyTooHigh(royaltyBps, MAX_ROYALTY_BPS);
        }
        if (receiver == address(0)) revert ZeroAddress();
        if (
            receiver == address(this) || receiver == core || receiver == baseERC20
                || receiver == vault || receiver == IArcalsCore(core).controller()
                || receiver == IArcalsCore(core).treasury()
        ) revert Unauthorized(receiver);
        _setDefaultRoyalty(receiver, royaltyBps);
        emit DefaultRoyaltyUpdated(receiver, royaltyBps);
    }

    function deleteDefaultRoyalty() external override onlyGovernance {
        _deleteDefaultRoyalty();
        emit DefaultRoyaltyUpdated(address(0), 0);
    }

    function royaltyInfo(uint256 tokenId, uint256 salePrice)
        public
        view
        override(ERC2981, IArcalMirror)
        returns (address receiver, uint256 royaltyAmount)
    {
        return super.royaltyInfo(tokenId, salePrice);
    }

    function tokenURI(uint256 id)
        public
        view
        override(ERC721, IERC721Metadata)
        returns (string memory)
    {
        _requireOwned(id);
        (bool rendered, string memory uri) =
            _renderWith(abi.encodeCall(IArcalsMetadataRenderer.tokenURI, (id)));
        return rendered ? uri : _builtinTokenURI(id);
    }

    function contractURI() external view override returns (string memory) {
        (bool rendered, string memory uri) =
            _renderWith(abi.encodeCall(IArcalsMetadataRenderer.contractURI, ()));
        if (rendered) return uri;
        return _jsonDataURI(
            string.concat(
                '{"name":"Arcals","description":"',
                _DESCRIPTION,
                '","image":"',
                _svgDataURI("1 Arcal = 360 ARCL"),
                '"}'
            )
        );
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC2981, IERC165)
        returns (bool)
    {
        return interfaceId == ERC4906_INTERFACE_ID || ERC721.supportsInterface(interfaceId)
            || ERC2981.supportsInterface(interfaceId);
    }

    string private constant _DESCRIPTION =
        "Arcals: 1,000,000 Pi inscriptions. Arcal #n is the 360 consecutive decimal digits of Pi at positions (n-1)*360+1 to n*360. One Arcal and 360 ARCL are two forms of the same share. No rarity is defined by the protocol.";

    /// @dev Bounded, non-reverting renderer call. Any revert, gas exhaustion, oversized or
    ///      malformed ABI string, or empty string yields (false, "") so callers fall back.
    function _renderWith(bytes memory callData)
        private
        view
        returns (bool rendered, string memory uri)
    {
        address renderer = metadataRenderer;
        uint256 available = gasleft();
        if (renderer == address(0) || available <= RENDER_FALLBACK_GAS) return (false, "");

        bool success;
        uint256 size;
        uint256 offset;
        uint256 length;
        assembly ("memory-safe") {
            success := staticcall(
                sub(available, RENDER_FALLBACK_GAS),
                renderer,
                add(callData, 0x20),
                mload(callData),
                0,
                0
            )
            size := returndatasize()
            if and(success, iszero(lt(size, 96))) {
                // Read only the ABI head into scratch space before trusting anything.
                returndatacopy(0, 0, 0x40)
                offset := mload(0)
                length := mload(0x20)
            }
        }
        if (
            !success || size < 96 || size > MAX_RENDER_RETURN_BYTES || offset != 0x20 || length == 0
                || length > size - 64
        ) return (false, "");

        bytes memory text = new bytes(length);
        assembly ("memory-safe") {
            returndatacopy(add(text, 0x20), 0x40, length)
        }
        return (true, string(text));
    }

    /// @dev Only the fixed Pi coordinates are traits. Mutable state and the per-token content
    ///      hash are plain fields so marketplaces do not derive rarity from them.
    function _builtinTokenURI(uint256 id) private view returns (string memory) {
        (uint256 startDigit, uint256 endDigit) = PiProof.piRange(id);
        bool registered = contentRegistered[id];
        return _jsonDataURI(
            string.concat(
                string.concat(
                    '{"name":"Arcal #',
                    id.toString(),
                    '","description":"',
                    _DESCRIPTION,
                    '","image":"',
                    _svgDataURI(
                        string.concat(
                            unicode"π ", startDigit.toString(), unicode" – ", endDigit.toString()
                        )
                    ),
                    '"'
                ),
                string.concat(
                    ',"pi_digit_start":',
                    startDigit.toString(),
                    ',"pi_digit_end":',
                    endDigit.toString(),
                    ',"content_registered":',
                    registered ? "true" : "false",
                    ',"content_hash":"',
                    registered ? uint256(contentHash[id]).toHexString(32) : "",
                    '","in_vault":',
                    _ownerOf(id) == vault ? "true" : "false"
                ),
                ',"attributes":[{"trait_type":"Pi digit start","display_type":"number","value":',
                startDigit.toString(),
                '},{"trait_type":"Pi digit end","display_type":"number","value":',
                endDigit.toString(),
                "}]}"
            )
        );
    }

    function _svgDataURI(string memory caption) private pure returns (string memory) {
        return string.concat(
            "data:image/svg+xml;base64,",
            Base64.encode(
                bytes(
                    string.concat(
                        "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 1000 1000'>",
                        "<rect width='1000' height='1000' fill='#030405'/>",
                        "<circle cx='500' cy='470' r='462' fill='none' stroke='#dfe8f1' stroke-width='2'/>",
                        "<text x='500' y='968' text-anchor='middle' font-family='monospace' font-size='24' letter-spacing='3' fill='#8f9cad'>",
                        caption,
                        "</text></svg>"
                    )
                )
            )
        );
    }

    function _jsonDataURI(string memory json) private pure returns (string memory) {
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    function _update(address to, uint256 tokenId, address auth)
        internal
        override
        returns (address previousOwner)
    {
        if (to == vault && msg.sender != vault) revert DirectVaultTransferForbidden();
        return super._update(to, tokenId, auth);
    }
}
