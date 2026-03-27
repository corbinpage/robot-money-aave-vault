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

    uint8 constant VAULT_MANAGER_ROLE = 1;  // SimpleVaultManager -> vault.manage()
    uint8 constant OPERATOR_ROLE = 8;       // Manager EOA -> supply/withdraw
    uint8 constant ADMIN_ROLE = 9;          // Admin EOA -> pause, rescue

    function run() external {
        address deployer = msg.sender;

        // Required env vars -- revert if unset to prevent accidental deployer-as-owner
        address owner = vm.envAddress("OWNER");
        address operator = vm.envAddress("OPERATOR");

        vm.startBroadcast();

        // 1. Deploy RolesAuthority (deployer is initial owner for setup, transferred later)
        RolesAuthority rolesAuthority = new RolesAuthority(deployer, Authority(address(0)));
        console.log("RolesAuthority:", address(rolesAuthority));

        // 2. Deploy BoringVault (deployer is initial owner so we can setAuthority)
        BoringVault vault = new BoringVault(deployer, "Robot Money Aave Vault", "rmUSDC", 6);
        console.log("BoringVault:", address(vault));

        // 3. Set vault authority
        vault.setAuthority(rolesAuthority);

        // 4. Deploy SimpleVaultManager (no Auth owner -- access is purely role-based)
        SimpleVaultManager vaultManager = new SimpleVaultManager(
            rolesAuthority, vault, USDC, AAVE_V3_POOL
        );
        console.log("SimpleVaultManager:", address(vaultManager));

        // ========================= ROLE CONFIGURATION =========================

        // --- SimpleVaultManager gets VAULT_MANAGER_ROLE on the vault ---
        rolesAuthority.setUserRole(address(vaultManager), VAULT_MANAGER_ROLE, true);
        rolesAuthority.setRoleCapability(
            VAULT_MANAGER_ROLE,
            address(vault),
            bytes4(keccak256("manage(address,bytes,uint256)")),
            true
        );

        // --- Operator EOA gets OPERATOR_ROLE to call supplyToAave / withdrawFromAave ---
        rolesAuthority.setUserRole(operator, OPERATOR_ROLE, true);
        rolesAuthority.setRoleCapability(
            OPERATOR_ROLE,
            address(vaultManager),
            SimpleVaultManager.supplyToAave.selector,
            true
        );
        rolesAuthority.setRoleCapability(
            OPERATOR_ROLE,
            address(vaultManager),
            SimpleVaultManager.withdrawFromAave.selector,
            true
        );
        rolesAuthority.setRoleCapability(
            OPERATOR_ROLE,
            address(vaultManager),
            SimpleVaultManager.withdrawAllFromAave.selector,
            true
        );
        console.log("Operator role granted to:", operator);

        // --- Owner gets ADMIN_ROLE for pause and rescue ---
        rolesAuthority.setUserRole(owner, ADMIN_ROLE, true);
        rolesAuthority.setRoleCapability(
            ADMIN_ROLE,
            address(vaultManager),
            SimpleVaultManager.setPaused.selector,
            true
        );
        rolesAuthority.setRoleCapability(
            ADMIN_ROLE,
            address(vaultManager),
            SimpleVaultManager.rescueTokens.selector,
            true
        );
        console.log("Admin role granted to:", owner);

        // --- Transfer ownership from deployer to owner ---
        vault.transferOwnership(owner);
        rolesAuthority.transferOwnership(owner);

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment Summary ===");
        console.log("Owner:", owner);
        console.log("Operator:", operator);
        console.log("");
        console.log("Access chain: Operator EOA -> SimpleVaultManager -> BoringVault -> Aave");
        console.log("The operator can ONLY supply/withdraw USDC to/from Aave.");
        console.log("The admin can pause operations and rescue stuck tokens.");
        console.log("");
        console.log("Next steps:");
        console.log("1. Deploy Teller + Accountant via Veda Arctic Architecture");
        console.log("2. Configure Teller to accept USDC deposits");
        console.log("3. Operator calls supplyToAave() to deploy vault USDC into Aave");
    }
}
