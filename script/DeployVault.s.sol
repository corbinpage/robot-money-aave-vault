// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Script, console} from "@forge-std/Script.sol";
import {BoringVault} from "boring-vault/base/BoringVault.sol";
import {Authority} from "@solmate/auth/Auth.sol";
import {RolesAuthority} from "@solmate/auth/authorities/RolesAuthority.sol";
import {SimpleVaultManager} from "../src/SimpleVaultManager.sol";

/// @title DeployVault
/// @notice Deploys the BoringVault + SimpleVaultManager system on Base.
///         The Teller and Accountant are expected to be deployed separately
///         via Veda's standard Arctic Architecture tooling.
contract DeployVault is Script {
    // ========================= BASE ADDRESSES =========================

    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant AAVE_V3_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;

    // ========================= ROLE IDs =========================

    uint8 constant VAULT_MANAGER_ROLE = 1;
    uint8 constant OWNER_ROLE = 8;

    function run() external {
        address deployer = msg.sender;

        address owner = vm.envOr("OWNER", deployer);
        address manager = vm.envOr("MANAGER", deployer);

        vm.startBroadcast();

        // 1. Deploy RolesAuthority
        RolesAuthority rolesAuthority = new RolesAuthority(deployer, Authority(address(0)));
        console.log("RolesAuthority:", address(rolesAuthority));

        // 2. Deploy BoringVault
        BoringVault vault = new BoringVault(deployer, "Robot Money Aave Vault", "rmUSDC", 6);
        console.log("BoringVault:", address(vault));

        // 3. Set vault authority
        vault.setAuthority(rolesAuthority);

        // 4. Deploy SimpleVaultManager
        SimpleVaultManager vaultManager = new SimpleVaultManager(
            owner, rolesAuthority, vault, USDC, AAVE_V3_POOL
        );
        console.log("SimpleVaultManager:", address(vaultManager));

        // ========================= ROLE CONFIGURATION =========================

        // --- SimpleVaultManager gets VAULT_MANAGER_ROLE on the vault ---
        // This allows it to call vault.manage()
        rolesAuthority.setUserRole(address(vaultManager), VAULT_MANAGER_ROLE, true);
        rolesAuthority.setRoleCapability(
            VAULT_MANAGER_ROLE,
            address(vault),
            bytes4(keccak256("manage(address,bytes,uint256)")),
            true
        );

        // --- Manager EOA gets OWNER_ROLE to call supplyToAave / withdrawFromAave ---
        rolesAuthority.setUserRole(manager, OWNER_ROLE, true);
        rolesAuthority.setRoleCapability(
            OWNER_ROLE,
            address(vaultManager),
            SimpleVaultManager.supplyToAave.selector,
            true
        );
        rolesAuthority.setRoleCapability(
            OWNER_ROLE,
            address(vaultManager),
            SimpleVaultManager.withdrawFromAave.selector,
            true
        );
        rolesAuthority.setRoleCapability(
            OWNER_ROLE,
            address(vaultManager),
            SimpleVaultManager.withdrawAllFromAave.selector,
            true
        );
        console.log("Manager role granted to:", manager);

        // --- Transfer ownership from deployer to owner ---
        vault.transferOwnership(owner);
        rolesAuthority.transferOwnership(owner);

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment Summary ===");
        console.log("Owner:", owner);
        console.log("Manager:", manager);
        console.log("");
        console.log("Access chain: Manager EOA -> SimpleVaultManager -> BoringVault -> Aave");
        console.log("The manager can ONLY supply/withdraw USDC to/from Aave.");
        console.log("");
        console.log("Next steps:");
        console.log("1. Deploy Teller + Accountant via Veda Arctic Architecture");
        console.log("2. Configure Teller to accept USDC deposits");
        console.log("3. Manager calls supplyToAave() to deploy vault USDC into Aave");
    }
}
