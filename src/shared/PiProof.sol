// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

library PiProof {
    uint256 internal constant MAX_ARCALS = 1_000_000;
    uint256 internal constant PACKED_DIGITS_LENGTH = 180;
    uint256 internal constant TREE_HEIGHT = 20;
    uint256 internal constant TREE_LEAF_COUNT = 2 ** TREE_HEIGHT;

    error InvalidArcalId(uint256 id);
    error InvalidPackedDigits();
    error InvalidProofLength(uint256 actual);
    error InvalidPaddingIndex(uint256 index);

    function piRange(uint256 id) internal pure returns (uint256 startDigit, uint256 endDigit) {
        if (id == 0 || id > MAX_ARCALS) revert InvalidArcalId(id);
        return ((id - 1) * 360 + 1, id * 360);
    }

    function isValidPackedDigits(bytes memory packedDigits) internal pure returns (bool) {
        if (packedDigits.length != PACKED_DIGITS_LENGTH) return false;
        for (uint256 index = 0; index < packedDigits.length; ++index) {
            uint8 value = uint8(packedDigits[index]);
            if (value >> 4 > 9 || value & 0x0f > 9) return false;
        }
        return true;
    }

    function contentHash(bytes memory packedDigits) internal pure returns (bytes32) {
        if (!isValidPackedDigits(packedDigits)) revert InvalidPackedDigits();
        return keccak256(packedDigits);
    }

    function leaf(uint256 id, bytes32 canonicalContentHash) internal pure returns (bytes32) {
        if (id == 0 || id > MAX_ARCALS) revert InvalidArcalId(id);
        // id <= 1,000,000 is enforced above, so the uint32 cast is lossless.
        // forge-lint: disable-next-line(unsafe-typecast)
        return keccak256(abi.encodePacked(bytes1(0x00), bytes4(uint32(id)), canonicalContentHash));
    }

    function emptyLeaf(uint256 index) internal pure returns (bytes32) {
        if (index < MAX_ARCALS || index >= TREE_LEAF_COUNT) {
            revert InvalidPaddingIndex(index);
        }
        // index < 2**20 is enforced above, so the uint32 cast is lossless.
        // forge-lint: disable-next-line(unsafe-typecast)
        return keccak256(abi.encodePacked(bytes1(0x02), bytes4(uint32(index))));
    }

    function node(bytes32 left, bytes32 right) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(bytes1(0x01), left, right));
    }

    function rootFromProof(uint256 id, bytes32 canonicalContentHash, bytes32[] memory proof)
        internal
        pure
        returns (bytes32 current)
    {
        if (proof.length != TREE_HEIGHT) revert InvalidProofLength(proof.length);
        current = leaf(id, canonicalContentHash);
        uint256 index = id - 1;
        for (uint256 level = 0; level < TREE_HEIGHT; ++level) {
            current = index & 1 == 0 ? node(current, proof[level]) : node(proof[level], current);
            index >>= 1;
        }
    }

    function verify(
        uint256 id,
        bytes memory packedDigits,
        bytes32[] memory proof,
        bytes32 expectedRoot
    ) internal pure returns (bool) {
        if (!isValidPackedDigits(packedDigits)) return false;
        return rootFromProof(id, keccak256(packedDigits), proof) == expectedRoot;
    }
}
