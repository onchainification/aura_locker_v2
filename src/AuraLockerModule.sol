// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {KeeperCompatibleInterface} from "@chainlink/automation/interfaces/KeeperCompatibleInterface.sol";

import {IGnosisSafe} from "./interfaces/gnosis/IGnosisSafe.sol";
import {ILockAura} from "./interfaces/aura/ILockAura.sol";

/// @title AuraLockerModule
/// @author Onchainification Labs
/// @notice The module handles the locking of AURA tokens for the multisig in a fully automated manner
contract AuraLockerModule is
    KeeperCompatibleInterface // 1 inherited component
{
    /*//////////////////////////////////////////////////////////////////////////
                                   CONSTANTS
    //////////////////////////////////////////////////////////////////////////*/
    address public constant BALANCER_MULTISIG = 0x10A19e7eE7d7F8a52822f6817de8ea18204F2e4f;
    IGnosisSafe public constant SAFE = IGnosisSafe(payable(BALANCER_MULTISIG));

    IERC20 public constant AURA = IERC20(0xC0c293ce456fF0ED870ADd98a0828Dd4d2903DBF);

    ILockAura public constant AURA_LOCKER = ILockAura(0x3Fa73f1E5d8A792C80F426fc8F84FBF7Ce9bBCAC);

    /*//////////////////////////////////////////////////////////////////////////
                                   PUBLIC STORAGE
    //////////////////////////////////////////////////////////////////////////*/

    address public keeper;

    /*//////////////////////////////////////////////////////////////////////////
                                       ERRORS
    //////////////////////////////////////////////////////////////////////////*/
    error NotKeeper(address agent);
    error NotGovernance(address agent);

    error ZeroAddressValue();

    error ModuleNotEnabled();

    error TxFromModuleFailed();

    error NothingToLock(uint256 timestamp);

    /*//////////////////////////////////////////////////////////////////////////
                                       EVENTS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Emitted when the admin sets a new keeper address
    /// @param admin The address of the admin
    /// @param oldKeeper The address of the old keeper
    /// @param newKeeper The address of the new keeper
    event SetKeeper(address indexed admin, address oldKeeper, address newKeeper);

    /*//////////////////////////////////////////////////////////////////////////
                                      MODIFIERS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Enforce that the function is called by the keeper only
    modifier onlyKeeper() {
        if (msg.sender != keeper) revert NotKeeper(msg.sender);
        _;
    }

    /// @notice Enforce that the function is called by governance only
    modifier onlyGovernance() {
        if (msg.sender != BALANCER_MULTISIG) revert NotGovernance(msg.sender);
        _;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  EXTERNAL METHODS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Assigns a new keeper address
    /// @param _keeper The address of the new keeper
    function setKeeper(address _keeper) external onlyGovernance {
        if (_keeper == address(0)) revert ZeroAddressValue();

        address oldKeeper = keeper;
        keeper = _keeper;

        emit SetKeeper(msg.sender, oldKeeper, keeper);
    }

    /// @notice Check if AURA holding are unlocked and lock them if needed
    /// @return requiresLocking True if there is a need to lock AURA tokens
    /// @return execPayload The payload of the locking transaction
    function checkUpkeep(bytes calldata /* checkData */ )
        external
        view
        override
        returns (bool requiresLocking, bytes memory execPayload)
    {
        if (!_isModuleEnabled()) return (false, bytes("AuraLocker module is not enabled"));

        (, uint256 unlockable,,) = AURA_LOCKER.lockedBalances(address(SAFE));

        if (unlockable > 0) {
            return (true, abi.encodeWithSelector(AURA_LOCKER.processExpiredLocks.selector, true));
        }

        return (false, bytes("No AURA tokens unlocked"));
    }

    /// @notice The actual execution of the action determined by the `checkUpkeep` method (AURA locking)
    function performUpkeep(bytes calldata /* _performData */ ) external override onlyKeeper {
        if (!_isModuleEnabled()) revert ModuleNotEnabled();

        (, uint256 unlockable,,) = AURA_LOCKER.lockedBalances(address(SAFE));
        if (unlockable == 0) revert NothingToLock(block.timestamp);

        // execute: `processExpiredLocks` via module
        if (
            !SAFE.execTransactionFromModule(
                address(AURA_LOCKER), 0, abi.encodeCall(ILockAura.processExpiredLocks, true), IGnosisSafe.Operation.Call
            )
        ) revert TxFromModuleFailed();
    }

    /// @dev The Gnosis Safe v1.1.1 does not yet have the `isModuleEnabled` method, so we need a workaround
    function _isModuleEnabled() internal view returns (bool) {
        address[] memory modules = SAFE.getModules();
        for (uint256 i = 0; i < modules.length; i++) {
            if (modules[i] == address(this)) return true;
        }
        return false;
    }
}
