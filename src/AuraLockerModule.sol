// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {KeeperCompatibleInterface} from "@chainlink/automation/interfaces/KeeperCompatibleInterface.sol";

import {ISafe} from "./interfaces/gnosis/ISafe.sol";
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
    address public constant BALANCER_GOV_SAFE = 0x9a5BDF08a6969A4bDb7724beE3c6d8964BDc0B28;
    ISafe public constant SAFE = ISafe(payable(BALANCER_GOV_SAFE));

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
        if (msg.sender != BALANCER_GOV_SAFE) revert NotGovernance(msg.sender);
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
        if (!SAFE.isModuleEnabled(address(this))) return (false, bytes("AuraLocker module is not enabled"));

        (, uint256 relockable,, ILockAura.LockedBalance[] memory lockData) = AURA_LOCKER.lockedBalances(address(SAFE));
        if (relockable > 0) {
            return (true, abi.encodeWithSelector(AURA_LOCKER.processExpiredLocks.selector, true));
        }

        // Check if any locks are expiring within the next week
        uint256 len = lockData.length;
        if (len > 0) {
            uint256 timestamp = block.timestamp;
            for (uint256 i = 0; i < len; i++) {
                if (timestamp + 1 weeks >= lockData[i].unlockTime) {
                    return (true, abi.encodeWithSelector(AURA_LOCKER.processExpiredLocks.selector, true));
                }
            }
        }

        uint256 auraBalance = AURA.balanceOf(address(SAFE));
        if (auraBalance > 0) {
            return (true, abi.encodeWithSelector(AURA_LOCKER.lock.selector, address(SAFE), auraBalance));
        }

        return (false, bytes("No AURA tokens unlocked"));
    }

    /// @notice The actual execution of the action determined by the `checkUpkeep` method (AURA locking)
    function performUpkeep(bytes calldata /* _performData */ ) external override onlyKeeper {
        // Check if the module is enabled
        if (SAFE.isModuleEnabled(address(this)) == false) {
            revert ModuleNotEnabled();
        }

        // Check if there are any expired locks
        (, uint256 relockable,, ILockAura.LockedBalance[] memory lockData) = AURA_LOCKER.lockedBalances(address(SAFE));
        bool shouldRelock = relockable > 0;

        // Check if there are locks expiring soon
        if (!shouldRelock && lockData.length > 0) {
            uint256 timestamp = block.timestamp;
            for (uint256 i = 0; i < lockData.length; i++) {
                if (timestamp + 1 weeks >= lockData[i].unlockTime) {
                    shouldRelock = true;
                    break;
                }
            }
        }

        if (shouldRelock) {
            // execute: `processExpiredLocks` via module
            bool processExpiredLocksSucceeded = SAFE.execTransactionFromModule(
                address(AURA_LOCKER), 0, abi.encodeCall(ILockAura.processExpiredLocks, true), ISafe.Operation.Call
            );
            if (processExpiredLocksSucceeded == false) {
                revert TxFromModuleFailed();
            }
        }

        // Lock AURA tokens if there are any
        uint256 auraBalance = AURA.balanceOf(address(SAFE));
        if (auraBalance > 0) {
            // execute: `approve` via module
            bool approveCallSucceeded = SAFE.execTransactionFromModule(
                address(AURA),
                0,
                abi.encodeCall(IERC20.approve, (address(AURA_LOCKER), auraBalance)),
                ISafe.Operation.Call
            );
            if (approveCallSucceeded == false) {
                revert TxFromModuleFailed();
            }
            // execute: `lock` via module
            bool lockCallSucceeded = SAFE.execTransactionFromModule(
                address(AURA_LOCKER),
                0,
                abi.encodeCall(ILockAura.lock, (address(SAFE), auraBalance)),
                ISafe.Operation.Call
            );
            if (lockCallSucceeded == false) {
                revert TxFromModuleFailed();
            }
        }

        if (!shouldRelock && auraBalance == 0) {
            revert NothingToLock(block.timestamp);
        }
    }
}
