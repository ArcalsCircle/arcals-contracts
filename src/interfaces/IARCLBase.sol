// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IArcalsErrors } from "./IArcalsErrors.sol";

interface IARCLBase is IERC20, IArcalsErrors {
    function mirrorERC721() external view returns (address);
    function unit() external pure returns (uint256);
    function protocolMintReserve(uint256 count) external;
    function vaultLockFrom(address owner) external;
    function vaultRelease(address recipient) external;
}
