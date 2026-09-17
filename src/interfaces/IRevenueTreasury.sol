// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IArcalsErrors } from "./IArcalsErrors.sol";

interface IRevenueTreasury is IArcalsErrors {
    event MintRevenue(uint256 indexed id, uint256 amountNative);
    event RevenueWithdrawn(address indexed to, uint256 amountNative);

    function depositMint(uint256 id) external payable;
    function withdraw(address payable to, uint256 amountNative) external;
    function owner() external view returns (address);
    function totalMintRevenue() external view returns (uint256);
    function totalWithdrawn() external view returns (uint256);
}
