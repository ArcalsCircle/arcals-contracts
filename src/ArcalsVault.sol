// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import { IARCLBase } from "./interfaces/IARCLBase.sol";
import { IArcalMirror } from "./interfaces/IArcalMirror.sol";
import { IArcalsCore } from "./interfaces/IArcalsCore.sol";
import { IArcalsVault } from "./interfaces/IArcalsVault.sol";

/// @notice Immutable reserve and O(1) FIFO conversion queue.
contract ArcalsVault is IERC721Receiver, IArcalsVault {
    uint256 public constant override unit = 360 ether;

    address public immutable core;
    address public immutable base;
    address public immutable mirror;
    address public immutable override governance;

    bool public override conversionOpen;
    address public override launchAuthority;
    uint256 public head;
    uint256 public tail;

    mapping(uint256 position => uint256 id) private _queue;
    mapping(uint256 id => bool banked) public override isBanked;
    bool private _acceptingBankTransfer;

    constructor(
        address core_,
        address base_,
        address mirror_,
        address launchAuthority_,
        address governance_
    ) {
        if (
            core_ == address(0) || base_ == address(0) || mirror_ == address(0)
                || launchAuthority_ == address(0) || governance_ == address(0)
        ) revert ZeroAddress();
        core = core_;
        base = base_;
        mirror = mirror_;
        launchAuthority = launchAuthority_;
        governance = governance_;
    }

    /// @notice Replaces a lost or compromised launch authority before activation.
    ///         Activation stays one-way; after it this role no longer exists.
    function setLaunchAuthority(address newLaunchAuthority) external override {
        if (msg.sender != governance) revert Unauthorized(msg.sender);
        if (conversionOpen) revert ConversionsAlreadyActive();
        if (newLaunchAuthority == address(0)) revert ZeroAddress();
        address previousLaunchAuthority = launchAuthority;
        launchAuthority = newLaunchAuthority;
        emit LaunchAuthorityUpdated(previousLaunchAuthority, newLaunchAuthority);
    }

    function activateConversions() external override {
        if (msg.sender != launchAuthority) revert Unauthorized(msg.sender);
        conversionOpen = true;
        launchAuthority = address(0);
        emit ConversionsActivated(msg.sender, uint64(block.timestamp));
    }

    function liquify(uint256 id, address tokenRecipient, uint64 deadline) external override {
        _checkOpenAndDeadline(deadline);
        _checkRecipient(tokenRecipient);

        address owner = IArcalMirror(mirror).ownerOf(id);
        if (owner != msg.sender) revert NotNftOwner(id, msg.sender, owner);
        if (!IArcalMirror(mirror).contentRegistered(id)) revert ContentNotRegistered(id);

        IArcalsCore(core).enterConversion();
        _acceptingBankTransfer = true;
        IArcalMirror(mirror).vaultBankFrom(owner, id);
        _acceptingBankTransfer = false;

        uint256 queuePosition = tail;
        _queue[queuePosition] = id;
        tail = queuePosition + 1;
        isBanked[id] = true;
        IARCLBase(base).vaultRelease(tokenRecipient);
        emit Liquified(id, owner, tokenRecipient, queuePosition);
        IArcalsCore(core).exitConversion();
    }

    function reform(address nftRecipient, uint256 expectedHeadId, uint64 deadline)
        external
        override
        returns (uint256 id)
    {
        _checkOpenAndDeadline(deadline);
        _checkRecipient(nftRecipient);
        if (head == tail) revert VaultEmpty();

        uint256 queuePosition = head;
        id = _queue[queuePosition];
        if (expectedHeadId != 0 && expectedHeadId != id) {
            revert HeadChanged(expectedHeadId, id);
        }

        IArcalsCore(core).enterConversion();
        IARCLBase(base).vaultLockFrom(msg.sender);
        delete _queue[queuePosition];
        head = queuePosition + 1;
        isBanked[id] = false;
        IArcalMirror(mirror).vaultReleaseTo(nftRecipient, id);
        emit Reformed(id, msg.sender, nftRecipient, queuePosition);
        IArcalsCore(core).exitConversion();
    }

    function bankedCount() external view override returns (uint256) {
        return tail - head;
    }

    function circulatingSupply() external view override returns (uint256) {
        IARCLBase token = IARCLBase(base);
        return token.totalSupply() - token.balanceOf(address(this));
    }

    function nextBankedId() external view override returns (uint256 id, bool exists) {
        if (head == tail) return (0, false);
        return (_queue[head], true);
    }

    function queueAt(uint256 position) external view override returns (uint256 id) {
        if (position < head || position >= tail) revert VaultEmpty();
        return _queue[position];
    }

    function onERC721Received(address, address, uint256, bytes calldata)
        external
        view
        override
        returns (bytes4)
    {
        if (msg.sender != mirror || !_acceptingBankTransfer) {
            revert DirectVaultTransferForbidden();
        }
        return IERC721Receiver.onERC721Received.selector;
    }

    function _checkOpenAndDeadline(uint64 deadline) private view {
        if (!conversionOpen) revert ConversionsClosed();
        if (block.timestamp > deadline) revert DeadlineExpired(deadline);
    }

    function _checkRecipient(address recipient) private view {
        if (recipient == address(0)) revert ZeroAddress();
        IArcalsCore coreContract = IArcalsCore(core);
        if (
            recipient == address(this) || recipient == core || recipient == base
                || recipient == mirror || recipient == coreContract.controller()
                || recipient == coreContract.treasury()
        ) revert Unauthorized(recipient);
    }
}
