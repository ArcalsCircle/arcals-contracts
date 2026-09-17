// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

import { ARCLBase } from "./ARCLBase.sol";
import { ArcalMirror } from "./ArcalMirror.sol";
import { ArcalsCore } from "./ArcalsCore.sol";
import { ArcalsVault } from "./ArcalsVault.sol";
import { MintController } from "./MintController.sol";
import { RevenueTreasury } from "./RevenueTreasury.sol";

/// @notice One-use, deployer-restricted CREATE factory for the circular immutable address graph.
/// @dev Governance is the management multisig directly: it owns the MintController ProxyAdmin
///      and is the `governance` of Controller, Core, Mirror and Vault. There is no timelock.
contract ArcalsDeploymentFactory {
    uint256 public constant CONTRACT_COUNT = 7;
    uint256 public constant ARC_MAINNET_CHAIN_ID = 5042;

    uint256 private constant CONTROLLER_IMPLEMENTATION_INDEX = 0;
    uint256 private constant CONTROLLER_PROXY_INDEX = 1;
    uint256 private constant CORE_INDEX = 2;
    uint256 private constant BASE_INDEX = 3;
    uint256 private constant MIRROR_INDEX = 4;
    uint256 private constant VAULT_INDEX = 5;
    uint256 private constant TREASURY_INDEX = 6;

    address public immutable deployer;
    bool public deploymentComplete;

    address public controllerImplementation;
    address public controllerProxy;
    address public proxyAdmin;
    address public core;
    address public base;
    address public mirror;
    address public vault;
    address public treasury;

    /// @notice keccak256 of the exact creation code (bytecode + constructor arguments) used for
    ///         each child, in CREATE order. Anyone can rebuild these from verified source with
    ///         ArcalsDeploymentPlan and compare; getters alone cannot prove what code runs.
    bytes32[7] public creationCodeHashes;

    struct Expectations {
        address managementMultisig;
        address guardian;
        address treasuryOwner;
        address launchAuthority;
        address epochPublisher;
        uint64 workGenesisTime;
        address issuerSigner;
        address verifierSigner;
        uint64 signerVersion;
        bytes32 datasetRoot;
        address reserveRecipient;
    }

    error InvalidDeploymentPlan();
    error ChildDeploymentFailed(uint256 index);
    error ChildAddressMismatch(uint256 index, address actual, address predicted);
    error DeploymentValidationFailed();

    event ChildDeployed(uint256 indexed index, address indexed child, bytes32 creationCodeHash);

    event ProtocolDeployed(
        address indexed core,
        address indexed controllerProxy,
        address indexed vault,
        address base,
        address mirror,
        address treasury,
        address proxyAdmin,
        address controllerImplementation
    );

    constructor(address deployer_) {
        if (deployer_ == address(0)) revert InvalidDeploymentPlan();
        deployer = deployer_;
    }

    function deploy(bytes[] calldata creationCodes, Expectations calldata expected)
        external
        returns (address[8] memory deployed)
    {
        _checkPlan(creationCodes, expected);
        if (block.chainid == ARC_MAINNET_CHAIN_ID) _requireContractRoles(expected);
        _deployChildren(creationCodes);
        _validate(expected);
        deploymentComplete = true;
        deployed = _deployedAddresses();
        emit ProtocolDeployed(
            core,
            controllerProxy,
            vault,
            base,
            mirror,
            treasury,
            proxyAdmin,
            controllerImplementation
        );
    }

    function predictChildAddress(uint256 nonce) public view returns (address) {
        return predictCreateAddress(address(this), nonce);
    }

    function predictCreateAddress(address creator, uint256 nonce) public pure returns (address) {
        if (nonce == 0 || nonce > 0x7f) revert InvalidDeploymentPlan();
        // nonce <= 0x7f is enforced above, so the uint8 cast is lossless.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint8 nonceByte = uint8(nonce);
        return address(
            uint160(uint256(keccak256(abi.encodePacked(hex"d694", creator, bytes1(nonceByte)))))
        );
    }

    function _checkPlan(bytes[] calldata creationCodes, Expectations calldata expected)
        internal
        view
    {
        if (msg.sender != deployer || deploymentComplete || creationCodes.length != CONTRACT_COUNT)
        {
            revert InvalidDeploymentPlan();
        }
        if (
            expected.managementMultisig == address(0) || expected.guardian == address(0)
                || expected.treasuryOwner == address(0) || expected.launchAuthority == address(0)
                || expected.epochPublisher == address(0) || expected.issuerSigner == address(0)
                || expected.verifierSigner == address(0) || expected.signerVersion == 0
                || expected.workGenesisTime == 0 || expected.datasetRoot == bytes32(0)
                || expected.reserveRecipient == address(0)
        ) revert InvalidDeploymentPlan();
    }

    /// @dev Production governance roles on Arc Mainnet must be contract accounts. This is a
    ///      guard against plain keys, not proof of a multisig threshold; owners and threshold
    ///      must still be verified off-chain.
    function _requireContractRoles(Expectations calldata expected) internal view {
        if (
            !_isContractAccount(expected.managementMultisig)
                || !_isContractAccount(expected.guardian)
                || !_isContractAccount(expected.treasuryOwner)
                || !_isContractAccount(expected.launchAuthority)
                || !_isContractAccount(expected.reserveRecipient)
        ) revert InvalidDeploymentPlan();
    }

    /// @dev EIP-7702 delegated EOAs carry 23 bytes of code starting with 0xef0100.
    function _isContractAccount(address account) internal view returns (bool) {
        bytes memory code = account.code;
        if (code.length == 0) return false;
        return !(code.length == 23 && code[0] == 0xef && code[1] == 0x01 && code[2] == 0x00);
    }

    function _deployChildren(bytes[] calldata creationCodes) internal {
        address[7] memory children;
        for (uint256 index = 0; index < CONTRACT_COUNT; ++index) {
            bytes memory creationCode = creationCodes[index];
            bytes32 codeHash = keccak256(creationCode);
            address child;
            assembly ("memory-safe") {
                child := create(0, add(creationCode, 0x20), mload(creationCode))
            }
            if (child == address(0)) revert ChildDeploymentFailed(index);
            address predicted = predictChildAddress(index + 1);
            if (child != predicted) revert ChildAddressMismatch(index, child, predicted);
            children[index] = child;
            creationCodeHashes[index] = codeHash;
            emit ChildDeployed(index, child, codeHash);
        }

        controllerImplementation = children[CONTROLLER_IMPLEMENTATION_INDEX];
        controllerProxy = children[CONTROLLER_PROXY_INDEX];
        core = children[CORE_INDEX];
        base = children[BASE_INDEX];
        mirror = children[MIRROR_INDEX];
        vault = children[VAULT_INDEX];
        treasury = children[TREASURY_INDEX];
        proxyAdmin = predictCreateAddress(controllerProxy, 1);
    }

    function _deployedAddresses() internal view returns (address[8] memory deployed) {
        deployed = [
            controllerImplementation,
            controllerProxy,
            proxyAdmin,
            core,
            base,
            mirror,
            vault,
            treasury
        ];
    }

    function _validate(Expectations calldata expected) internal view {
        address governance = expected.managementMultisig;
        address[7] memory required =
            [controllerImplementation, controllerProxy, core, base, mirror, vault, treasury];
        for (uint256 index = 0; index < required.length; ++index) {
            if (required[index].code.length == 0) revert DeploymentValidationFailed();
        }
        if (proxyAdmin.code.length == 0 || ProxyAdmin(proxyAdmin).owner() != governance) {
            revert DeploymentValidationFailed();
        }

        MintController controller = MintController(payable(controllerProxy));
        if (
            controller.core() != core || controller.governance() != governance
                || controller.guardian() != expected.guardian
                || controller.epochPublisher() != expected.epochPublisher
                || controller.workGenesisTime() != expected.workGenesisTime
                || controller.issuerSigner() != expected.issuerSigner
                || controller.verifierSigner() != expected.verifierSigner
                || controller.signerVersion() != expected.signerVersion
                || controller.workConfigCount() != 0
        ) revert DeploymentValidationFailed();

        ArcalsCore coreContract = ArcalsCore(core);
        if (
            coreContract.controller() != controllerProxy || coreContract.base() != base
                || coreContract.mirror() != mirror || coreContract.vault() != vault
                || coreContract.treasury() != treasury
                || coreContract.guardian() != expected.guardian
                || coreContract.governance() != governance || !coreContract.mintPaused()
                || coreContract.reserveRecipient() != expected.reserveRecipient
                || coreContract.reserveMintedCount() != 0 || coreContract.mintedCount() != 0
        ) revert DeploymentValidationFailed();

        if (
            ARCLBase(base).core() != core || ARCLBase(base).mirrorERC721() != mirror
                || ARCLBase(base).vault() != vault || ARCLBase(base).totalSupply() != 0
        ) revert DeploymentValidationFailed();
        ArcalMirror mirrorContract = ArcalMirror(mirror);
        if (
            mirrorContract.core() != core || mirrorContract.baseERC20() != base
                || mirrorContract.vault() != vault
                || mirrorContract.datasetRoot() != expected.datasetRoot
                || mirrorContract.governance() != governance
                || mirrorContract.metadataRenderer() != address(0)
        ) revert DeploymentValidationFailed();
        ArcalsVault vaultContract = ArcalsVault(vault);
        if (
            vaultContract.core() != core || vaultContract.base() != base
                || vaultContract.mirror() != mirror
                || vaultContract.launchAuthority() != expected.launchAuthority
                || vaultContract.governance() != governance || vaultContract.conversionOpen()
        ) revert DeploymentValidationFailed();
        if (
            RevenueTreasury(payable(treasury)).core() != core
                || RevenueTreasury(payable(treasury)).owner() != expected.treasuryOwner
        ) revert DeploymentValidationFailed();
    }
}
