// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IArcalsErrors } from "./IArcalsErrors.sol";

interface IArcalsVault is IArcalsErrors {
    event Liquified(
        uint256 indexed id, address indexed owner, address tokenRecipient, uint256 queuePosition
    );
    event Reformed(
        uint256 indexed id, address indexed tokenOwner, address nftRecipient, uint256 queuePosition
    );
    event ConversionsActivated(address indexed caller, uint64 timestamp);
    event LaunchAuthorityUpdated(
        address indexed previousLaunchAuthority, address indexed newLaunchAuthority
    );

    error ConversionsAlreadyActive();

    function activateConversions() external;
    function setLaunchAuthority(address newLaunchAuthority) external;
    function launchAuthority() external view returns (address);
    function governance() external view returns (address);
    function liquify(uint256 id, address tokenRecipient, uint64 deadline) external;
    function reform(address nftRecipient, uint256 expectedHeadId, uint64 deadline)
        external
        returns (uint256 id);
    function conversionOpen() external view returns (bool);
    function bankedCount() external view returns (uint256);
    function circulatingSupply() external view returns (uint256);
    function nextBankedId() external view returns (uint256 id, bool exists);
    function queueAt(uint256 position) external view returns (uint256 id);
    function isBanked(uint256 id) external view returns (bool);
    function unit() external pure returns (uint256);
}
