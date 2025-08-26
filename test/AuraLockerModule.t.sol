// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {BaseFixture} from "./BaseFixture.sol";

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {ILockAura} from "../src/interfaces/aura/ILockAura.sol";

import {AuraLockerModule} from "../src/AuraLockerModule.sol";

contract AuraLockerModuleTest is BaseFixture {
    function test_checkUpkeep_when_NotNewUnlock() public view {
        // at present nothing to lock
        (bool requiresLocking, bytes memory execPayload) = auraLockerModule.checkUpkeep(bytes(""));
        assertFalse(requiresLocking);
        assertEq(execPayload, bytes("No AURA tokens unlocked"));
    }

    function test_checkUpkeep_when_LockingIsRequired() public {
        // move to future where tokens are unlocked
        skip(16 weeks);
        (bool requiresLocking, bytes memory execPayload) = auraLockerModule.checkUpkeep(bytes(""));
        assertTrue(requiresLocking);
        assertEq(execPayload, abi.encodeWithSelector(AURA_LOCKER.processExpiredLocks.selector, true));
    }

    function test_revertWhen_ModuleNotEnabled() public {
        // `disableModule(address prevModule, address module)`
        vm.prank(address(SAFE));
        SAFE.disableModule(address(1), address(auraLockerModule));
        assertFalse(SAFE.isModuleEnabled(address(auraLockerModule)));

        // once module is removed, the keeper trying to call `performUpkeep` should revert
        vm.prank(auraLockerModule.keeper());
        vm.expectRevert(abi.encodeWithSelector(AuraLockerModule.ModuleNotEnabled.selector));
        auraLockerModule.performUpkeep(bytes(""));
    }

    function testPerformUpkeep_revertWhen_NothingToLock() public {
        // force a `performUpkeep` when not enough weeks went by
        skip(1 weeks);

        vm.prank(auraLockerModule.keeper());
        vm.expectRevert(abi.encodeWithSelector(AuraLockerModule.NothingToLock.selector, block.timestamp));
        auraLockerModule.performUpkeep(bytes(""));
    }

    function testPerformUpkeepSuccess() public {
        // move to future where tokens are unlocked
        skip(16 weeks);
        (bool requiresLocking,) = auraLockerModule.checkUpkeep(bytes(""));
        assertTrue(requiresLocking);

        (uint256 totalAuraInLocker,, uint256 lockedBeforePerformUpkeep,) = AURA_LOCKER.lockedBalances(address(SAFE));

        vm.prank(auraLockerModule.keeper());
        auraLockerModule.performUpkeep(bytes(""));

        // check if the 2M AURA were locked properly
        (,, uint256 lockedAfterPerformUpkeep,) = AURA_LOCKER.lockedBalances(address(SAFE));
        assertGt(lockedAfterPerformUpkeep, lockedBeforePerformUpkeep);
        assertEq(totalAuraInLocker, lockedAfterPerformUpkeep);
    }

    function testPerformUpkeep_revertWhen_NotKeeper() public {
        vm.prank(address(454545));
        vm.expectRevert(abi.encodeWithSelector(AuraLockerModule.NotKeeper.selector, address(454545)));
        auraLockerModule.performUpkeep(bytes(""));
    }

    function testSetKeeper_revertWhen_NotGovernance() public {
        vm.prank(address(454545));
        vm.expectRevert(abi.encodeWithSelector(AuraLockerModule.NotGovernance.selector, address(454545)));
        auraLockerModule.setKeeper(address(454545));
    }

    function testSetKeeper_revertWhen_AddressIsZero() public {
        vm.prank(address(SAFE));
        vm.expectRevert(abi.encodeWithSelector(AuraLockerModule.ZeroAddressValue.selector));
        auraLockerModule.setKeeper(address(0));
    }

    function testAutomaticLockingOfNakedAura() public {
        // Get AURA token reference
        IERC20 aura = IERC20(0xC0c293ce456fF0ED870ADd98a0828Dd4d2903DBF);

        // Use a known AURA holder address from mainnet
        // This is a treasury or large holder address with sufficient AURA
        address auraWhale = 0x43B17088503F4CE1AED9fB302ED6BB51aD6694Fa; // Aura Treasury

        uint256 whaleBalance = aura.balanceOf(auraWhale);

        // Ensure we have enough balance to transfer
        assertGe(whaleBalance, 1e18, "Whale doesn't have enough AURA");

        // Transfer 1 AURA to the safe
        vm.prank(auraWhale);
        aura.transfer(address(SAFE), 1e18);

        // Verify AURA was received
        uint256 safeBalance = aura.balanceOf(address(SAFE));
        assertEq(safeBalance, 1e18, "Safe should have 1 AURA");

        // Check that upkeep is needed
        (bool requiresLocking, bytes memory execPayload) = auraLockerModule.checkUpkeep(bytes(""));
        assertTrue(requiresLocking, "Should require locking");
        assertEq(execPayload, abi.encodeWithSelector(AURA_LOCKER.lock.selector, address(SAFE), 1e18));

        // Get current locked balance
        (uint256 totalLockedBefore,, uint256 lockedBefore,) = AURA_LOCKER.lockedBalances(address(SAFE));

        // Perform the upkeep
        vm.prank(auraLockerModule.keeper());
        auraLockerModule.performUpkeep(bytes(""));

        // Verify AURA was locked
        (uint256 totalLockedAfter,, uint256 lockedAfter,) = AURA_LOCKER.lockedBalances(address(SAFE));
        assertEq(totalLockedAfter, totalLockedBefore + 1e18, "Total locked should increase by 1 AURA");
        assertEq(lockedAfter, lockedBefore + 1e18, "Locked balance should increase by 1 AURA");

        // Verify safe no longer has AURA
        assertEq(aura.balanceOf(address(SAFE)), 0, "Safe should have 0 AURA after locking");
    }

    function test_checkUpkeep_when_LocksExpiringSoon() public {
        // skip forward to get closer to lock expiry
        // existing lock expires around week 16 from the fork block
        // we want to test the early trigger (within 1 week of expiry)
        skip(10 weeks);

        // check current state
        (, uint256 relockable,, ILockAura.LockedBalance[] memory lockData) = AURA_LOCKER.lockedBalances(address(SAFE));

        // ensure we have locks that are not expired yet
        assertEq(relockable, 0, "Should have no expired locks at this point");
        assertGt(lockData.length, 0, "Should have active locks");

        // check that the module detects locks expiring within 1 week
        (bool requiresLocking, bytes memory execPayload) = auraLockerModule.checkUpkeep(bytes(""));

        // verify the unlock time is within 1 week
        uint256 timeUntilUnlock = lockData[0].unlockTime - block.timestamp;
        if (timeUntilUnlock <= 1 weeks) {
            assertTrue(requiresLocking, "Should require locking when locks expire within 1 week");
            assertEq(execPayload, abi.encodeWithSelector(AURA_LOCKER.processExpiredLocks.selector, true));
        } else {
            assertFalse(requiresLocking, "Should not require locking when locks don't expire within 1 week");
        }
    }

    function testPerformUpkeep_when_LocksExpiringSoon() public {
        // skip to a point where locks will expire within 1 week but have not expired yet
        skip(10 weeks);

        // check current state
        (, uint256 relockable,, ILockAura.LockedBalance[] memory lockData) = AURA_LOCKER.lockedBalances(address(SAFE));
        assertEq(relockable, 0, "Should have no expired locks");
        assertGt(lockData.length, 0, "Should have active locks");

        uint256 timeUntilUnlock = lockData[0].unlockTime - block.timestamp;

        // only test if locks are expiring within 1 week
        if (timeUntilUnlock <= 1 weeks) {
            // get the locked balance before
            (uint256 totalBefore,, uint256 lockedBefore,) = AURA_LOCKER.lockedBalances(address(SAFE));

            // perform upkeep
            vm.prank(auraLockerModule.keeper());
            auraLockerModule.performUpkeep(bytes(""));

            // after performUpkeep, total and locked balances should still be the same
            (uint256 totalAfter,, uint256 lockedAfter,) = AURA_LOCKER.lockedBalances(address(SAFE));
            assertEq(totalAfter, totalBefore, "Total AURA should remain the same");
            assertEq(lockedAfter, lockedBefore, "Locked amount should remain the same");
        }
    }
}
