// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {BaseFixture} from "./BaseFixture.sol";

import {ILockAura} from "../src/interfaces/aura/ILockAura.sol";

import {AuraLockerModule} from "../src/AuraLockerModule.sol";

contract AuraLockerModuleTest is BaseFixture {
    function test_checkUpkeep_when_NotNewUnlock() public {
        // at present nothing to lock
        (bool requiresLocking, bytes memory execPayload) = auraLockerModule.checkUpkeep(bytes(""));
        assertFalse(requiresLocking);
        assertEq(execPayload, bytes("No AURA tokens are unlock!"));
    }

    function test_checkUpkeep_when_LockingIsRequired() public {
        // move into the future
        skip(16 weeks);
        (bool requiresLocking, bytes memory execPayload) = auraLockerModule.checkUpkeep(bytes(""));
        assertTrue(requiresLocking);
        assertEq(execPayload, abi.encodeWithSelector(AURA_LOCKER.processExpiredLocks.selector, true));
    }

    function test_revertWhen_ModuleNotEnabled() public {
        // `disableModule(address prevModule, address module)`
        vm.prank(address(SAFE));
        SAFE.disableModule(address(1), address(auraLockerModule));
        // assertFalse(SAFE.isModuleEnabled(address(auraLockerModule)));
    }

    function test_revertWhen_NothingToUnlock() public {}

    function testPerformUpkeepSuccess() public {}

    function testPerformUpkeep_revertWhen_NotKeeper() public {
        vm.prank(address(454545));
        vm.expectRevert(abi.encodeWithSelector(AuraLockerModule.NotKeeper.selector, address(454545)));
        auraLockerModule.performUpkeep(bytes(""));
    }
}
