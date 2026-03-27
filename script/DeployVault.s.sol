// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Script, console} from "@forge-std/Script.sol";
import {BoringVault} from "boring-vault/base/BoringVault.sol";
import {Authority} from "@solmate/auth/Auth.sol";
import {RolesAuthority} from "@solmate/auth/authorities/RolesAuthority.sol";
import {ERC20} from "@solmate/tokens/ERC20.sol";
import {TellerWithMultiAssetSupport} from "boring-vault/base/Roles/TellerWithMultiAssetSupport.sol";
import {AccountantWithRateProviders} from "boring-vault/base/Roles/AccountantWithRateProviders.sol";
import {DelayedWithdraw} from "boring-vault/base/Roles/DelayedWithdraw.sol";
import {SimpleVaultManager} from "../src/SimpleVaultManager.sol";

/// @title DeployVault
/// @notice Deploys the full Robot Money Aave Vault system on Base:
///         BoringVault + Accountant + Teller + DelayedWithdraw + SimpleVaultManager.
contract DeployVault is Script {
    // ========================= BASE ADDRESSES =========================

    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant AAVE_V3_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address constant WETH = 0x4200000000000000000000000000000000000006;

    // ========================= ROLE IDs =========================

    uint8 constant VAULT_MANAGER_ROLE = 1;   // SimpleVaultManager -> vault.manage()
    uint8 constant TELLER_ROLE = 2;          // Teller -> vault.enter()
    uint8 constant DELAYED_WITHDRAW_ROLE = 3;// DelayedWithdraw -> vault.exit()
    uint8 constant OPERATOR_ROLE = 8;        // Operator EOA -> supply/withdraw Aave
    uint8 constant ADMIN_ROLE = 9;           // Admin EOA -> pause, rescue, config

    // ========================= CONFIGURATION =========================

    uint32 constant WITHDRAW_DELAY = 1 days;
    uint32 constant COMPLETION_WINDOW = 7 days;
    uint16 constant WITHDRAW_FEE = 0;        // No fee on delayed withdrawals
    uint16 constant MAX_LOSS = 100;           // 1% max slippage on delayed withdrawals

    // Accountant config
    uint96 constant STARTING_EXCHANGE_RATE = 1e6;  // 1:1 for 6-decimal USDC
    uint16 constant ALLOWED_RATE_CHANGE_UPPER = 10_003; // 0.03% upper
    uint16 constant ALLOWED_RATE_CHANGE_LOWER = 9_997;  // 0.03% lower
    uint24 constant MIN_UPDATE_DELAY = 3600;             // 1 hour
    uint16 constant PLATFORM_FEE = 0;
    uint16 constant PERFORMANCE_FEE = 0;

    function run() external {
        address deployer = msg.sender;

        // Required env vars
        address owner = vm.envAddress("OWNER");
        address operator = vm.envAddress("OPERATOR");

        vm.startBroadcast();

        // 1. Deploy RolesAuthority
        RolesAuthority auth = new RolesAuthority(deployer, Authority(address(0)));
        console.log("RolesAuthority:", address(auth));

        // 2. Deploy BoringVault
        BoringVault vault = new BoringVault(deployer, "Robot Money Aave Vault", "rmUSDC", 6);
        console.log("BoringVault:", address(vault));
        vault.setAuthority(auth);

        // 3. Deploy AccountantWithRateProviders
        AccountantWithRateProviders accountant = new AccountantWithRateProviders(
            deployer,
            address(vault),
            owner,                         // payout address for fees
            STARTING_EXCHANGE_RATE,
            address(USDC),                 // base asset
            ALLOWED_RATE_CHANGE_UPPER,
            ALLOWED_RATE_CHANGE_LOWER,
            MIN_UPDATE_DELAY,
            PLATFORM_FEE,
            PERFORMANCE_FEE
        );
        console.log("Accountant:", address(accountant));

        // 4. Deploy TellerWithMultiAssetSupport
        TellerWithMultiAssetSupport teller = new TellerWithMultiAssetSupport(
            deployer,
            address(vault),
            address(accountant),
            WETH
        );
        console.log("Teller:", address(teller));

        // 5. Deploy DelayedWithdraw
        DelayedWithdraw delayedWithdraw = new DelayedWithdraw(
            deployer,
            address(vault),
            address(accountant),
            owner                          // fee address (not used with 0 fee)
        );
        console.log("DelayedWithdraw:", address(delayedWithdraw));

        // 6. Deploy SimpleVaultManager
        SimpleVaultManager vaultManager = new SimpleVaultManager(
            auth, vault, USDC, AAVE_V3_POOL
        );
        console.log("SimpleVaultManager:", address(vaultManager));

        // 7. Point all Veda contracts to the shared RolesAuthority
        //    (they deploy with Authority(address(0)) by default)
        teller.setAuthority(auth);
        accountant.setAuthority(auth);
        delayedWithdraw.setAuthority(auth);

        // ========================= VAULT PERMISSIONS =========================

        // SimpleVaultManager -> vault.manage()
        auth.setUserRole(address(vaultManager), VAULT_MANAGER_ROLE, true);
        auth.setRoleCapability(
            VAULT_MANAGER_ROLE,
            address(vault),
            bytes4(keccak256("manage(address,bytes,uint256)")),
            true
        );

        // Teller -> vault.enter() (for deposits)
        auth.setUserRole(address(teller), TELLER_ROLE, true);
        auth.setRoleCapability(
            TELLER_ROLE,
            address(vault),
            bytes4(keccak256("enter(address,address,uint256,address,uint256)")),
            true
        );

        // DelayedWithdraw -> vault.exit() (for completing withdrawals)
        auth.setUserRole(address(delayedWithdraw), DELAYED_WITHDRAW_ROLE, true);
        auth.setRoleCapability(
            DELAYED_WITHDRAW_ROLE,
            address(vault),
            bytes4(keccak256("exit(address,address,uint256,address,uint256)")),
            true
        );

        // ========================= OPERATOR PERMISSIONS =========================

        auth.setUserRole(operator, OPERATOR_ROLE, true);
        auth.setRoleCapability(
            OPERATOR_ROLE, address(vaultManager), SimpleVaultManager.supplyToAave.selector, true
        );
        auth.setRoleCapability(
            OPERATOR_ROLE, address(vaultManager), SimpleVaultManager.withdrawFromAave.selector, true
        );
        auth.setRoleCapability(
            OPERATOR_ROLE, address(vaultManager), SimpleVaultManager.withdrawAllFromAave.selector, true
        );

        // ========================= ADMIN PERMISSIONS =========================

        auth.setUserRole(owner, ADMIN_ROLE, true);

        // Admin on SimpleVaultManager
        auth.setRoleCapability(
            ADMIN_ROLE, address(vaultManager), SimpleVaultManager.setPaused.selector, true
        );
        auth.setRoleCapability(
            ADMIN_ROLE, address(vaultManager), SimpleVaultManager.rescueTokens.selector, true
        );

        // Admin on Teller (updateAssetData, setShareLockPeriod)
        auth.setRoleCapability(
            ADMIN_ROLE, address(teller), TellerWithMultiAssetSupport.updateAssetData.selector, true
        );

        // Admin on Accountant (updateExchangeRate)
        auth.setRoleCapability(
            ADMIN_ROLE,
            address(accountant),
            AccountantWithRateProviders.updateExchangeRate.selector,
            true
        );

        // Admin on DelayedWithdraw (setup, change delay, pause)
        auth.setRoleCapability(
            ADMIN_ROLE, address(delayedWithdraw), DelayedWithdraw.setupWithdrawAsset.selector, true
        );
        auth.setRoleCapability(
            ADMIN_ROLE, address(delayedWithdraw), DelayedWithdraw.changeWithdrawDelay.selector, true
        );
        auth.setRoleCapability(
            ADMIN_ROLE, address(delayedWithdraw), DelayedWithdraw.changeMaxLoss.selector, true
        );
        auth.setRoleCapability(
            ADMIN_ROLE, address(delayedWithdraw), DelayedWithdraw.pause.selector, true
        );
        auth.setRoleCapability(
            ADMIN_ROLE, address(delayedWithdraw), DelayedWithdraw.unpause.selector, true
        );

        // ========================= PUBLIC CAPABILITIES =========================
        // Anyone can call requestWithdraw, cancelWithdraw, completeWithdraw on DelayedWithdraw
        auth.setPublicCapability(
            address(delayedWithdraw), DelayedWithdraw.requestWithdraw.selector, true
        );
        auth.setPublicCapability(
            address(delayedWithdraw), DelayedWithdraw.cancelWithdraw.selector, true
        );
        auth.setPublicCapability(
            address(delayedWithdraw), DelayedWithdraw.completeWithdraw.selector, true
        );

        // Anyone can call deposit on Teller
        auth.setPublicCapability(address(teller), TellerWithMultiAssetSupport.deposit.selector, true);

        // ========================= ASSET CONFIGURATION =========================

        // Teller accepts USDC deposits (no withdraws -- use DelayedWithdraw instead)
        teller.updateAssetData(ERC20(USDC), true, false, 0);

        // Set Teller as vault's beforeTransferHook (enforces share lock periods)
        vault.setBeforeTransferHook(address(teller));

        // DelayedWithdraw: setup USDC with 1-day delay
        delayedWithdraw.setupWithdrawAsset(
            ERC20(USDC),
            WITHDRAW_DELAY,
            COMPLETION_WINDOW,
            WITHDRAW_FEE,
            MAX_LOSS
        );

        // Pull funds from vault on withdrawal completion (vs pre-funding)
        delayedWithdraw.setPullFundsFromVault(true);

        // ========================= TRANSFER OWNERSHIP =========================

        vault.transferOwnership(owner);
        teller.transferOwnership(owner);
        accountant.transferOwnership(owner);
        delayedWithdraw.transferOwnership(owner);
        auth.transferOwnership(owner);

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment Summary ===");
        console.log("Owner:", owner);
        console.log("Operator:", operator);
        console.log("");
        console.log("User flow:");
        console.log("  Deposit:  User -> Teller.deposit(USDC) -> vault mints rmUSDC shares");
        console.log("  Withdraw: User -> DelayedWithdraw.requestWithdraw() -> wait 1 day -> completeWithdraw()");
        console.log("");
        console.log("Operator flow:");
        console.log("  Supply:   Operator -> SimpleVaultManager.supplyToAave()");
        console.log("  Withdraw: Operator -> SimpleVaultManager.withdrawFromAave() (to service user withdrawals)");
    }
}
