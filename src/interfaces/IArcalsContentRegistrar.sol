// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IArcalsErrors } from "./IArcalsErrors.sol";

interface IArcalsContentRegistrar is IArcalsErrors {
    function mirror() external view returns (address);

    /// @notice `payload` is exactly abi.encode(uint256 id, bytes packedDigits, bytes32[] proof).
    function registerEncoded(bytes calldata payload) external;
}
