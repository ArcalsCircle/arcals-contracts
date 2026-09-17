// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IARCLBase } from "./interfaces/IARCLBase.sol";

/// @notice Immutable fungible side of the Arcals two-form asset.
contract ARCLBase is ERC20, IARCLBase {
    uint256 public constant override unit = 360 ether;

    address public immutable core;
    address public immutable override mirrorERC721;
    address public immutable vault;

    constructor(address core_, address mirror_, address vault_) ERC20("Arcals", "ARCL") {
        if (core_ == address(0) || mirror_ == address(0) || vault_ == address(0)) {
            revert ZeroAddress();
        }
        core = core_;
        mirrorERC721 = mirror_;
        vault = vault_;
    }

    /// @notice Creates exactly one UNIT per issued Arcal, always into the Vault.
    function protocolMintReserve(uint256 count) external override {
        if (msg.sender != core) revert Unauthorized(msg.sender);
        _mint(vault, unit * count);
    }

    function vaultLockFrom(address owner) external override {
        if (msg.sender != vault) revert Unauthorized(msg.sender);
        uint256 approved = allowance(owner, vault);
        if (approved < unit) revert InsufficientAllowance(owner, approved, unit);
        _spendAllowance(owner, vault, unit);
        _transfer(owner, vault, unit);
    }

    function vaultRelease(address recipient) external override {
        if (msg.sender != vault) revert Unauthorized(msg.sender);
        if (recipient == address(0)) revert ZeroAddress();
        _transfer(vault, recipient, unit);
    }

    function transfer(address to, uint256 value) public override(ERC20, IERC20) returns (bool) {
        _rejectDirectVaultTransfer(to, value);
        return super.transfer(to, value);
    }

    function transferFrom(address from, address to, uint256 value)
        public
        override(ERC20, IERC20)
        returns (bool)
    {
        _rejectDirectVaultTransfer(to, value);
        return super.transferFrom(from, to, value);
    }

    function _rejectDirectVaultTransfer(address to, uint256 value) private view {
        if (to == vault && value != 0) revert DirectVaultTransferForbidden();
    }
}
