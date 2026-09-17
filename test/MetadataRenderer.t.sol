// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC4906 } from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import { Base64 } from "@openzeppelin/contracts/utils/Base64.sol";

import { ArcalsMetadataRenderer } from "../src/ArcalsMetadataRenderer.sol";
import { IArcalsErrors } from "../src/interfaces/IArcalsErrors.sol";
import { ArcalsTestBase } from "./ArcalsContracts.t.sol";

contract MetadataRendererTest is ArcalsTestBase {
    string private piFixture;
    ArcalsMetadataRenderer private renderer;
    string private constant IMAGE_BASE = "https://api.arcals.fun/v1/arcals/";

    function setUp() public override {
        piFixture = vm.readFile(
            string.concat(vm.projectRoot(), "/test/fixtures/pi/sparse-membership-v1.json")
        );
        super.setUp();
        renderer = new ArcalsMetadataRenderer(address(mirror), IMAGE_BASE);
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

    function _golden(string memory name) private view returns (string memory) {
        return vm.readFile(string.concat(vm.projectRoot(), "/test/fixtures/render/", name));
    }

    function testArtworkMatchesReferenceImplementationByteForByte() public {
        (uint256 first,) = _mint(makeAddr("first-minter"));
        _setIssued(500_000, core.RESERVE_COUNT() - 1);
        core.mintReserve(1);

        assertEq(renderer.imageSVG(1_000_000), _golden("unregistered-1000000.svg"));

        _register(first);
        _register(1_000_000);
        uint256 gasBefore = gasleft();
        string memory art = renderer.imageSVG(first);
        emit log_named_uint("imageSVG gas", gasBefore - gasleft());
        assertEq(art, _golden("arcal-1.svg"));
        assertEq(renderer.imageSVG(1_000_000), _golden("arcal-1000000.svg"));
    }

    function testMirrorServesRendererMetadataAndFallsBack() public {
        (uint256 id,) = _mint(makeAddr("minter"));
        _register(id);
        string memory builtin = mirror.tokenURI(id);

        address outsider = makeAddr("outsider");
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(IArcalsErrors.Unauthorized.selector, outsider));
        mirror.setMetadataRenderer(address(renderer));

        vm.expectEmit(true, true, true, true, address(mirror));
        emit IERC4906.BatchMetadataUpdate(1, 1_000_000);
        vm.prank(management);
        mirror.setMetadataRenderer(address(renderer));

        uint256 gasBefore = gasleft();
        string memory rendered = mirror.tokenURI(id);
        uint256 used = gasBefore - gasleft();
        emit log_named_uint("Mirror tokenURI gas with renderer", used);
        assertEq(rendered, renderer.tokenURI(id));
        assertGt(bytes(rendered).length, bytes(builtin).length);
        assertLt(used, 25_000_000, "tokenURI stays inside common eth_call gas caps");
        assertGt(bytes(mirror.contractURI()).length, 0);

        // A broken renderer never blanks the collection: the Mirror falls back to built-in art.
        vm.etch(address(renderer), hex"fe");
        assertEq(mirror.tokenURI(id), builtin);
    }

    function testUnregisteredArcalsPointToIdenticalOffchainArtwork() public {
        (uint256 id,) = _mint(makeAddr("minter"));
        assertEq(renderer.imageURI(id), "https://api.arcals.fun/v1/arcals/1/image.svg");
        _register(id);
        assertEq(
            renderer.imageURI(id),
            string.concat(
                "data:image/svg+xml;base64,", Base64.encode(bytes(_golden("arcal-1.svg")))
            )
        );

        // Without a base URL every Arcal stays fully on-chain.
        ArcalsMetadataRenderer onchainOnly = new ArcalsMetadataRenderer(address(mirror), "");
        _setIssued(500_000, core.RESERVE_COUNT() - 1);
        core.mintReserve(1);
        assertEq(
            onchainOnly.imageURI(1_000_000),
            string.concat(
                "data:image/svg+xml;base64,",
                Base64.encode(bytes(_golden("unregistered-1000000.svg")))
            )
        );
    }

    function testRendererRejectsZeroMirror() public {
        vm.expectRevert(IArcalsErrors.ZeroAddress.selector);
        new ArcalsMetadataRenderer(address(0), IMAGE_BASE);
    }
}
