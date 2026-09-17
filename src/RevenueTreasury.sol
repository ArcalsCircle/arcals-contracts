// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { IRevenueTreasury } from "./interfaces/IRevenueTreasury.sol";

/// @notice Project revenue domain. It has no authority over the conversion reserve.
contract RevenueTreasury is Ownable2Step, ReentrancyGuard, IRevenueTreasury {
    uint256 public constant MINT_FEE_NATIVE = 0.1 ether;

    address public immutable core;
    uint256 public override totalMintRevenue;
    uint256 public override totalWithdrawn;

    error NativeTransferFailed(address to, uint256 amountNative);
    error OwnershipRenunciationDisabled();

    constructor(address core_, address initialOwner) Ownable(initialOwner) {
        if (core_ == address(0)) revert ZeroAddress();
        core = core_;
    }

    function owner() public view override(Ownable, IRevenueTreasury) returns (address) {
        return super.owner();
    }

    function renounceOwnership() public view override onlyOwner {
        revert OwnershipRenunciationDisabled();
    }

    function depositMint(uint256 id) external payable override {
        if (msg.sender != core) revert Unauthorized(msg.sender);
        if (msg.value != MINT_FEE_NATIVE) revert WrongMintFee(msg.value, MINT_FEE_NATIVE);
        totalMintRevenue += msg.value;
        emit MintRevenue(id, msg.value);
    }

    function withdraw(address payable to, uint256 amountNative)
        external
        override
        onlyOwner
        nonReentrant
    {
        if (to == address(0)) revert ZeroAddress();
        totalWithdrawn += amountNative;
        (bool success,) = to.call{ value: amountNative }("");
        if (!success) revert NativeTransferFailed(to, amountNative);
        emit RevenueWithdrawn(to, amountNative);
    }
}
