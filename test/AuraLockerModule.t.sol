// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {BaseFixture} from "./BaseFixture.sol";

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
        address[] memory modules = SAFE.getModules();
        for (uint256 i = 0; i < modules.length; i++) {
            if (modules[i] == address(auraLockerModule)) assertFalse(true);
        }

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
}
