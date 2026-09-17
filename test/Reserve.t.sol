// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import { ArcalMirror } from "../src/ArcalMirror.sol";
import { ArcalsCore } from "../src/ArcalsCore.sol";
import { ArcalsDeploymentFactory } from "../src/ArcalsDeploymentFactory.sol";
import { ArcalsDeploymentPlan } from "../src/deployment/ArcalsDeploymentPlan.sol";
import { IArcalsCore } from "../src/interfaces/IArcalsCore.sol";
import { IArcalsErrors } from "../src/interfaces/IArcalsErrors.sol";
import { ArcalsTestBase } from "./ArcalsContracts.t.sol";

/// @dev Reserve recipient that tries to re-enter issuance while receiving an Arcal.
contract ReentrantReserveRecipient is IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        ArcalsCore(ArcalMirror(msg.sender).core()).mintReserve(1);
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract ReserveTest is ArcalsTestBase {
    function testReserveIssuesFinalIdsToFixedRecipientWithoutFeeOrWork() public {
        assertEq(core.reserveRecipient(), reserveRecipient);
        assertEq(core.RESERVE_FIRST_ID(), 990_001);
        assertEq(core.RESERVE_COUNT(), 10_000);
        uint256 revenueBefore = address(treasury).balance;

        address anyone = makeAddr("gas-payer");
        vm.expectEmit(true, true, true, true, address(core));
        emit IArcalsCore.ReserveIssued(990_001, 990_003, reserveRecipient, 3 * UNIT);
        vm.prank(anyone);
        (uint256 firstId, uint256 lastId) = core.mintReserve(3);

        assertEq(firstId, 990_001);
        assertEq(lastId, 990_003);
        for (uint256 id = firstId; id <= lastId; ++id) {
            assertEq(mirror.ownerOf(id), reserveRecipient);
        }
        assertEq(mirror.balanceOf(anyone), 0);
        assertEq(core.reserveMintedCount(), 3);
        assertEq(core.mintedCount(), 0);
        assertEq(address(treasury).balance, revenueBefore);
        assertEq(base.balanceOf(address(vault)), 3 * UNIT);
        _assertConservation();

        (uint256 publicId,) = _mint(makeAddr("public-minter"));
        assertEq(publicId, 1);
        _assertConservation();
    }

    function testReserveIgnoresMintPauseAndStopsAtTenThousand() public {
        vm.prank(guardian);
        core.pauseMint();
        _setIssued(0, core.RESERVE_COUNT() - 2);

        (uint256 firstId, uint256 lastId) = core.mintReserve(core.MAX_RESERVE_BATCH());
        assertEq(firstId, 999_999);
        assertEq(lastId, 1_000_000);
        assertEq(core.reserveMintedCount(), 10_000);
        _assertConservation();

        vm.expectRevert(IArcalsErrors.ReserveExhausted.selector);
        core.mintReserve(1);
    }

    function testReserveBatchBounds() public {
        uint256 maxBatch = core.MAX_RESERVE_BATCH();
        vm.expectRevert(abi.encodeWithSelector(IArcalsErrors.InvalidReserveBatch.selector, 0));
        core.mintReserve(0);
        vm.expectRevert(
            abi.encodeWithSelector(IArcalsErrors.InvalidReserveBatch.selector, maxBatch + 1)
        );
        core.mintReserve(maxBatch + 1);

        uint256 gasBefore = gasleft();
        core.mintReserve(maxBatch);
        uint256 used = gasBefore - gasleft();
        emit log_named_uint("reserve batch gas (500)", used);
        assertLt(used, 30_000_000, "a full batch fits well inside one block");
        _assertConservation();
    }

    function testPublicSoldOutDoesNotBlockReserve() public {
        _setIssued(core.PUBLIC_MAX_ARCALS(), 0);
        (uint256 firstId,) = core.mintReserve(1);
        assertEq(firstId, 990_001);
        _assertConservation();
    }

    function testReserveRecipientCannotReenterIssuance() public {
        vm.etch(reserveRecipient, type(ReentrantReserveRecipient).runtimeCode);
        vm.expectRevert(IArcalsErrors.ProtocolReentrancy.selector);
        core.mintReserve(1);
        assertEq(core.reserveMintedCount(), 0);
    }

    function testFactoryRejectsMissingReserveRecipient() public {
        ArcalsDeploymentFactory other = new ArcalsDeploymentFactory(address(this));
        ArcalsDeploymentFactory.Expectations memory expected = _expectations();
        expected.reserveRecipient = address(0);
        bytes[] memory codes = ArcalsDeploymentPlan.creationCodes(other, expected);
        vm.expectRevert(ArcalsDeploymentFactory.InvalidDeploymentPlan.selector);
        other.deploy(codes, expected);
    }

    function testContentDigitsRoundTripAndStayEmptyBeforeRegistration() public {
        (uint256 id,) = _mint(makeAddr("content-minter"));
        assertEq(mirror.contentDigits(id).length, 0);
        _register(id);
        assertEq(mirror.contentDigits(id), packedDigits[id]);
    }
}
