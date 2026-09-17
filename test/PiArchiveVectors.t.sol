// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { ArcalsTestBase } from "./ArcalsContracts.t.sol";
import { IArcalsErrors } from "../src/interfaces/IArcalsErrors.sol";
import { PiProof } from "../src/shared/PiProof.sol";

contract PiArchiveVectorsTest is Test {
    string private fixture;

    function setUp() public {
        fixture = vm.readFile(
            string.concat(vm.projectRoot(), "/test/fixtures/pi/sparse-membership-v1.json")
        );
    }

    function testFirstMiddleAndFinalSparseVectorsShareOneDirectionalRoot() public view {
        bytes32 root = vm.parseJsonBytes32(fixture, ".root");
        assertFalse(vm.parseJsonBool(fixture, ".productionRoot"));
        _assertVector(0, root);
        _assertVector(1, root);
        _assertVector(2, root);
    }

    function _assertVector(uint256 index, bytes32 root) private view {
        string memory path = string.concat(".vectors[", vm.toString(index), "]");
        uint256 id = vm.parseUint(vm.parseJsonString(fixture, string.concat(path, ".id")));
        bytes memory packed = vm.parseJsonBytes(fixture, string.concat(path, ".packedDigits"));
        bytes32 contentHash = vm.parseJsonBytes32(fixture, string.concat(path, ".contentHash"));
        bytes32[] memory proof = vm.parseJsonBytes32Array(fixture, string.concat(path, ".proof"));
        assertEq(PiProof.contentHash(packed), contentHash);
        assertTrue(PiProof.verify(id, packed, proof, root));
        (uint256 startDigit, uint256 endDigit) = PiProof.piRange(id);
        assertEq(
            startDigit,
            vm.parseUint(vm.parseJsonString(fixture, string.concat(path, ".range.startDigit")))
        );
        assertEq(
            endDigit,
            vm.parseUint(vm.parseJsonString(fixture, string.concat(path, ".range.endDigit")))
        );
    }
}

contract PiArchiveMirrorIntegrationTest is ArcalsTestBase {
    string private piFixture;

    function setUp() public override {
        piFixture = vm.readFile(
            string.concat(vm.projectRoot(), "/test/fixtures/pi/sparse-membership-v1.json")
        );
        super.setUp();
    }

    function _buildContentFixture() internal override {
        datasetRoot = vm.parseJsonBytes32(piFixture, ".root");
        for (uint256 index = 0; index < 3; ++index) {
            string memory path = string.concat(".vectors[", vm.toString(index), "]");
            uint256 id = vm.parseUint(vm.parseJsonString(piFixture, string.concat(path, ".id")));
            packedDigits[id] = vm.parseJsonBytes(piFixture, string.concat(path, ".packedDigits"));
            contentProofs[id] = vm.parseJsonBytes32Array(piFixture, string.concat(path, ".proof"));
        }
    }

    function testSparseRootRegistersFirstMiddleAndFinalVectorsInMirror() public {
        // Issue the three vector IDs through their real paths: public #1 and #500,000, and the
        // final reserved #1,000,000. Content for an unissued ID is rejected.
        vm.expectRevert(abi.encodeWithSelector(IArcalsErrors.InvalidContentProof.selector, 1));
        mirror.registerContent(1, packedDigits[1], contentProofs[1]);
        (uint256 first,) = _mint(makeAddr("first-minter"));
        _setIssued(499_999, 0);
        (uint256 middle,) = _mint(makeAddr("middle-minter"));
        _setIssued(500_000, core.RESERVE_COUNT() - 1);
        (uint256 reserveFirst, uint256 last) = core.mintReserve(1);
        assertEq(first, 1);
        assertEq(middle, 500_000);
        assertEq(reserveFirst, 1_000_000);
        assertEq(last, 1_000_000);

        for (uint256 idIndex = 0; idIndex < 3; ++idIndex) {
            uint256 id = idIndex == 0 ? 1 : idIndex == 1 ? 500_000 : 1_000_000;
            assertEq(mirror.contentDigits(id).length, 0);
            mirror.registerContent(id, packedDigits[id], contentProofs[id]);
            assertTrue(mirror.contentRegistered(id));
            assertEq(mirror.contentHash(id), keccak256(packedDigits[id]));
            assertEq(mirror.contentDigits(id), packedDigits[id]);
        }

        bytes32[] memory badProof = contentProofs[500_000];
        badProof[0] = bytes32(uint256(badProof[0]) ^ 1);
        vm.expectRevert(
            abi.encodeWithSelector(IArcalsErrors.InvalidContentProof.selector, uint256(500_000))
        );
        mirror.registerContent(500_000, packedDigits[500_000], badProof);
        _assertConservation();
    }
}
