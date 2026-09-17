// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IArcalMirror } from "./interfaces/IArcalMirror.sol";
import { IArcalsContentRegistrar } from "./interfaces/IArcalsContentRegistrar.sol";

/// @notice Stateless scalar-ABI entry for permissionless Pi content registration.
/// @dev Some agent wallets (Circle CLI) cannot pass `bytes32[]` arguments. This contract takes one
///      `bytes` payload, decodes it and forwards to the immutable Mirror, so the user's own wallet
///      sends and pays for registration. It has no owner, storage, value handling or privileges;
///      the Mirror verifies the proof exactly as for a direct call.
contract ArcalsContentRegistrar is IArcalsContentRegistrar {
    address public immutable override mirror;

    constructor(address mirror_) {
        if (mirror_ == address(0)) revert ZeroAddress();
        mirror = mirror_;
    }

    function registerEncoded(bytes calldata payload) external override {
        (uint256 id, bytes memory packedDigits, bytes32[] memory proof) =
            abi.decode(payload, (uint256, bytes, bytes32[]));
        IArcalMirror(mirror).registerContent(id, packedDigits, proof);
    }
}
