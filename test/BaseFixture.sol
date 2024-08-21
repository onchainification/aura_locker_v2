// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {IKeeperRegistryMaster} from "@chainlink/automation/interfaces/v2_1/IKeeperRegistryMaster.sol";
import {IKeeperRegistrar} from "../src/interfaces/chainlink/IKeeperRegistrar.sol";

import {IGnosisSafe} from "../src/interfaces/gnosis/IGnosisSafe.sol";
import {ILockAura} from "../src/interfaces/aura/ILockAura.sol";

import {AuraLockerModule} from "../src/AuraLockerModule.sol";

contract BaseFixture is Test {
    // @note it has already LINK funds
    // https://debank.com/profile/0x9ff471F9f98F42E5151C7855fD1b5aa906b1AF7e
    address constant BALANCER_ADMIN_CHAINLINK_UPKEEPS = 0x9ff471F9f98F42E5151C7855fD1b5aa906b1AF7e;

    IGnosisSafe public constant SAFE = IGnosisSafe(0x10A19e7eE7d7F8a52822f6817de8ea18204F2e4f);

    // https://docs.chain.link/resources/link-token-contracts?parent=automation#ethereum-mainnet
    IERC20 constant LINK = IERC20(0x514910771AF9Ca656af840dff83E8264EcF986CA);
    // https://docs.chain.link/chainlink-automation/overview/supported-networks#ethereum-mainnet
    IKeeperRegistryMaster constant CL_REGISTRY = IKeeperRegistryMaster(0x6593c7De001fC8542bB1703532EE1E5aA0D458fD);
    IKeeperRegistrar constant CL_REGISTRAR = IKeeperRegistrar(0x6B0B234fB2f380309D47A7E9391E29E9a179395a);

    ILockAura constant AURA_LOCKER = ILockAura(0x3Fa73f1E5d8A792C80F426fc8F84FBF7Ce9bBCAC);

    AuraLockerModule auraLockerModule;

    function setUp() public virtual {
        // block @ https://etherscan.io/block/20576471
        vm.createSelectFork("ethereum", 20576471);

        // deploy module
        auraLockerModule = new AuraLockerModule();

        // enable module
        vm.prank(address(SAFE));
        SAFE.enableModule(address(auraLockerModule));
        // assertTrue(SAFE.isModuleEnabled(address(auraLockerModule)));

        // register chainlink task
        vm.startPrank(BALANCER_ADMIN_CHAINLINK_UPKEEPS);
        LINK.approve(address(CL_REGISTRAR), 20e18);
        IKeeperRegistrar.RegistrationParams memory registrationParams = IKeeperRegistrar.RegistrationParams({
            name: "AuraLockerModule",
            encryptedEmail: "",
            upkeepContract: address(auraLockerModule),
            gasLimit: 2_000_000,
            adminAddress: BALANCER_ADMIN_CHAINLINK_UPKEEPS,
            triggerType: 0,
            checkData: "",
            triggerConfig: "",
            offchainConfig: "",
            amount: 20e18
        });
        uint256 upkeepId = CL_REGISTRAR.registerUpkeep(registrationParams);
        address keeper = CL_REGISTRY.getForwarder(upkeepId);
        assertNotEq(keeper, address(0));

        auraLockerModule.setKeeper(keeper);
        assertEq(auraLockerModule.keeper(), keeper);
        vm.stopPrank();

        _labelKeyContracts();
    }

    function _labelKeyContracts() internal {
        vm.label(address(AURA_LOCKER), "AURA_LOCKER");
        vm.label(address(auraLockerModule), "AURA_LOCKER_MODULE");
        vm.label(BALANCER_ADMIN_CHAINLINK_UPKEEPS, "BALANCER_ADMIN_CHAINLINK_UPKEEPS");
        vm.label(address(SAFE), "BALANCER_MULTISIG");
        vm.label(address(CL_REGISTRY), "CL_REGISTRY");
        vm.label(address(CL_REGISTRAR), "CL_REGISTRAR");
    }
}
