// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ArcalsTestBase } from "./ArcalsContracts.t.sol";
import { ArcalsContentRegistrar } from "../src/ArcalsContentRegistrar.sol";
import { IArcalsErrors } from "../src/interfaces/IArcalsErrors.sol";

contract ContentRegistrarTest is ArcalsTestBase {
    ArcalsContentRegistrar internal registrar;

    function setUp() public override {
        super.setUp();
        registrar = new ArcalsContentRegistrar(address(mirror));
    }

    function _payload(uint256 id) internal view returns (bytes memory) {
        return abi.encode(id, packedDigits[id], contentProofs[id]);
    }

    function testAnyWalletRegistersThroughScalarPayloadAndPaysItsOwnGas() public {
        (uint256 id,) = _mint(makeAddr("holder"));
        address payer = makeAddr("circle-sca-like-payer");
        vm.prank(payer);
        registrar.registerEncoded(_payload(id));
        assertTrue(mirror.contentRegistered(id));
        assertEq(mirror.contentHash(id), keccak256(packedDigits[id]));
        assertEq(mirror.ownerOf(id), makeAddr("holder"), "registration never moves the NFT");
        assertEq(address(registrar).balance, 0);

        // Idempotent like the Mirror itself.
        registrar.registerEncoded(_payload(id));
        assertTrue(mirror.contentRegistered(id));
        _assertConservation();
    }

    function testRegistrarCannotBypassMirrorProofChecks() public {
        (uint256 id,) = _mint(makeAddr("holder"));
        bytes32[] memory badProof = contentProofs[id];
        badProof[0] = keccak256("wrong sibling");
        vm.expectRevert(abi.encodeWithSelector(IArcalsErrors.InvalidContentProof.selector, id));
        registrar.registerEncoded(abi.encode(id, packedDigits[id], badProof));

        vm.expectRevert(abi.encodeWithSelector(IArcalsErrors.InvalidContentProof.selector, 2));
        registrar.registerEncoded(_payload(2));

        vm.expectRevert();
        registrar.registerEncoded(hex"1234");
        assertFalse(mirror.contentRegistered(id));
    }

    function testRegistrarRejectsZeroMirror() public {
        vm.expectRevert(IArcalsErrors.ZeroAddress.selector);
        new ArcalsContentRegistrar(address(0));
    }

    function testForwardingOverheadIsSmall() public {
        (uint256 direct,) = _mint(makeAddr("direct"));
        (uint256 routed,) = _mint(makeAddr("routed"));
        uint256 before = gasleft();
        mirror.registerContent(direct, packedDigits[direct], contentProofs[direct]);
        uint256 directGas = before - gasleft();
        before = gasleft();
        registrar.registerEncoded(_payload(routed));
        uint256 routedGas = before - gasleft();
        emit log_named_uint("direct registerContent gas", directGas);
        emit log_named_uint("registrar registerEncoded gas", routedGas);
        assertLt(routedGas, directGas + 15_000);
    }
}
