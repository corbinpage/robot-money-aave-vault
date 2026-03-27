// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Test} from "@forge-std/Test.sol";
import {BoringVault} from "boring-vault/base/BoringVault.sol";
import {SimpleVaultManager} from "../src/SimpleVaultManager.sol";
import {Authority} from "@solmate/auth/Auth.sol";
import {RolesAuthority} from "@solmate/auth/authorities/RolesAuthority.sol";
import {ERC20} from "@solmate/tokens/ERC20.sol";
import {TellerWithMultiAssetSupport} from "boring-vault/base/Roles/TellerWithMultiAssetSupport.sol";
import {AccountantWithRateProviders} from "boring-vault/base/Roles/AccountantWithRateProviders.sol";
import {DelayedWithdraw} from "boring-vault/base/Roles/DelayedWithdraw.sol";

// ========================= MOCKS =========================

contract MockAToken is ERC20 {
    constructor() ERC20("Aave Base USDC", "aBasUSDC", 6) {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function burn(address from, uint256 amount) external { _burn(from, amount); }
}

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC", 6) {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockWETH is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH", 18) {}
}

contract MockAavePool {
    MockUSDC public usdc;
    MockAToken public aUsdc;
    constructor(MockUSDC _usdc, MockAToken _aUsdc) { usdc = _usdc; aUsdc = _aUsdc; }
    function supply(address, uint256 amount, address onBehalfOf, uint16) external {
        usdc.transferFrom(msg.sender, address(this), amount);
        aUsdc.mint(onBehalfOf, amount);
    }
    function withdraw(address, uint256 amount, address to) external returns (uint256) {
        uint256 bal = aUsdc.balanceOf(msg.sender);
        uint256 withdrawAmount = amount == type(uint256).max ? bal : amount;
        aUsdc.burn(msg.sender, withdrawAmount);
        usdc.mint(to, withdrawAmount);
        return withdrawAmount;
    }
}

// ========================= INTEGRATION TESTS =========================

/// @notice Full integration test: Teller deposits, Aave supply, DelayedWithdraw.
contract IntegrationTest is Test {
    BoringVault vault;
    RolesAuthority auth;
    AccountantWithRateProviders accountant;
    TellerWithMultiAssetSupport teller;
    DelayedWithdraw delayedWithdraw;
    SimpleVaultManager vaultManager;

    MockUSDC usdc;
    MockAToken aUsdc;
    MockWETH weth;
    MockAavePool aavePool;

    address admin = address(0xA);
    address operator = address(0xB);
    address alice = address(0xC);
    address bob = address(0xD);

    uint8 constant VAULT_MANAGER_ROLE = 1;
    uint8 constant TELLER_ROLE = 2;
    uint8 constant DELAYED_WITHDRAW_ROLE = 3;
    uint8 constant OPERATOR_ROLE = 8;
    uint8 constant ADMIN_ROLE = 9;

    uint32 constant WITHDRAW_DELAY = 1 days;
    uint32 constant COMPLETION_WINDOW = 7 days;

    function setUp() public {
        usdc = new MockUSDC();
        aUsdc = new MockAToken();
        weth = new MockWETH();
        aavePool = new MockAavePool(usdc, aUsdc);

        auth = new RolesAuthority(admin, Authority(address(0)));
        vault = new BoringVault(admin, "Robot Money Aave Vault", "rmUSDC", 6);

        vm.startPrank(admin);
        vault.setAuthority(auth);

        // Deploy Accountant (1:1 exchange rate, USDC base)
        accountant = new AccountantWithRateProviders(
            admin,
            address(vault),
            admin,           // payout
            1e6,             // 1:1 for 6-decimal USDC
            address(usdc),   // base asset
            10_003,          // upper bound
            9_997,           // lower bound
            3600,            // 1hr min update delay
            0,               // no platform fee
            0                // no performance fee
        );

        // Deploy Teller
        teller = new TellerWithMultiAssetSupport(
            admin,
            address(vault),
            address(accountant),
            address(weth)
        );

        // Deploy DelayedWithdraw
        delayedWithdraw = new DelayedWithdraw(
            admin,
            address(vault),
            address(accountant),
            admin            // fee address
        );

        // Deploy SimpleVaultManager
        vaultManager = new SimpleVaultManager(auth, vault, address(usdc), address(aavePool));

        // Point all Veda contracts to the shared RolesAuthority
        // (they deploy with Authority(address(0)) by default)
        teller.setAuthority(auth);
        accountant.setAuthority(auth);
        delayedWithdraw.setAuthority(auth);

        // ========================= PERMISSIONS =========================

        // SimpleVaultManager -> vault.manage()
        auth.setUserRole(address(vaultManager), VAULT_MANAGER_ROLE, true);
        auth.setRoleCapability(
            VAULT_MANAGER_ROLE, address(vault),
            bytes4(keccak256("manage(address,bytes,uint256)")), true
        );

        // Teller -> vault.enter()
        auth.setUserRole(address(teller), TELLER_ROLE, true);
        auth.setRoleCapability(
            TELLER_ROLE, address(vault),
            bytes4(keccak256("enter(address,address,uint256,address,uint256)")), true
        );

        // DelayedWithdraw -> vault.exit()
        auth.setUserRole(address(delayedWithdraw), DELAYED_WITHDRAW_ROLE, true);
        auth.setRoleCapability(
            DELAYED_WITHDRAW_ROLE, address(vault),
            bytes4(keccak256("exit(address,address,uint256,address,uint256)")), true
        );

        // Operator
        auth.setUserRole(operator, OPERATOR_ROLE, true);
        auth.setRoleCapability(OPERATOR_ROLE, address(vaultManager), SimpleVaultManager.supplyToAave.selector, true);
        auth.setRoleCapability(OPERATOR_ROLE, address(vaultManager), SimpleVaultManager.withdrawFromAave.selector, true);
        auth.setRoleCapability(OPERATOR_ROLE, address(vaultManager), SimpleVaultManager.withdrawAllFromAave.selector, true);

        // Admin
        auth.setUserRole(admin, ADMIN_ROLE, true);
        auth.setRoleCapability(ADMIN_ROLE, address(vaultManager), SimpleVaultManager.setPaused.selector, true);

        // Public: deposit, requestWithdraw, cancelWithdraw, completeWithdraw
        auth.setPublicCapability(address(teller), TellerWithMultiAssetSupport.deposit.selector, true);
        auth.setPublicCapability(address(delayedWithdraw), DelayedWithdraw.requestWithdraw.selector, true);
        auth.setPublicCapability(address(delayedWithdraw), DelayedWithdraw.cancelWithdraw.selector, true);
        auth.setPublicCapability(address(delayedWithdraw), DelayedWithdraw.completeWithdraw.selector, true);

        // Configure Teller: USDC deposits allowed, no direct withdrawals
        teller.updateAssetData(ERC20(address(usdc)), true, false, 0);

        // Set Teller as beforeTransferHook
        vault.setBeforeTransferHook(address(teller));

        // Configure DelayedWithdraw: USDC, 1-day delay, 7-day window, 0 fee, 1% maxLoss
        delayedWithdraw.setupWithdrawAsset(
            ERC20(address(usdc)), WITHDRAW_DELAY, COMPLETION_WINDOW, 0, 100
        );
        delayedWithdraw.setPullFundsFromVault(true);

        vm.stopPrank();

        // Give users some USDC
        usdc.mint(alice, 10_000e6);
        usdc.mint(bob, 5_000e6);
    }

    // ========================= DEPOSIT VIA TELLER =========================

    function test_deposit_viasTeller() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 1_000e6);
        uint256 shares = teller.deposit(ERC20(address(usdc)), 1_000e6, 0);
        vm.stopPrank();

        assertGt(shares, 0);
        assertEq(vault.balanceOf(alice), shares);
        assertEq(usdc.balanceOf(address(vault)), 1_000e6);
    }

    function test_deposit_multipleUsers() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 5_000e6);
        teller.deposit(ERC20(address(usdc)), 5_000e6, 0);
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(address(vault), 3_000e6);
        teller.deposit(ERC20(address(usdc)), 3_000e6, 0);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(vault)), 8_000e6);
        assertGt(vault.balanceOf(alice), 0);
        assertGt(vault.balanceOf(bob), 0);
    }

    // ========================= FULL LIFECYCLE =========================

    function test_fullLifecycle_deposit_supply_withdraw() public {
        // 1. Alice deposits 1000 USDC
        vm.startPrank(alice);
        usdc.approve(address(vault), 1_000e6);
        uint256 shares = teller.deposit(ERC20(address(usdc)), 1_000e6, 0);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(vault)), 1_000e6);

        // 2. Operator supplies vault USDC to Aave
        vm.prank(operator);
        vaultManager.supplyToAave(1_000e6);

        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(aUsdc.balanceOf(address(vault)), 1_000e6);

        // 3. Alice requests delayed withdrawal
        vm.startPrank(alice);
        vault.approve(address(delayedWithdraw), shares);
        delayedWithdraw.requestWithdraw(ERC20(address(usdc)), uint96(shares), 100, true);
        vm.stopPrank();

        // Shares now held by DelayedWithdraw
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(address(delayedWithdraw)), shares);

        // 4. Operator sees pending withdrawal, pulls USDC from Aave
        vm.prank(operator);
        vaultManager.withdrawFromAave(1_000e6);

        assertEq(usdc.balanceOf(address(vault)), 1_000e6);

        // 5. Wait 1 day for delay to pass
        vm.warp(block.timestamp + WITHDRAW_DELAY);

        // 6. Alice completes withdrawal
        vm.prank(alice);
        uint256 assetsOut = delayedWithdraw.completeWithdraw(ERC20(address(usdc)), alice);

        assertEq(assetsOut, 1_000e6);
        assertEq(usdc.balanceOf(alice), 10_000e6); // Got her original 10000 back
        assertEq(vault.balanceOf(address(delayedWithdraw)), 0);
    }

    // ========================= DELAYED WITHDRAW TIMING =========================

    function test_delayedWithdraw_revertsBeforeDelay() public {
        // Alice deposits
        vm.startPrank(alice);
        usdc.approve(address(vault), 1_000e6);
        uint256 shares = teller.deposit(ERC20(address(usdc)), 1_000e6, 0);

        // Request withdrawal
        vault.approve(address(delayedWithdraw), shares);
        delayedWithdraw.requestWithdraw(ERC20(address(usdc)), uint96(shares), 100, true);

        // Try to complete immediately -- should revert
        vm.expectRevert();
        delayedWithdraw.completeWithdraw(ERC20(address(usdc)), alice);
        vm.stopPrank();
    }

    function test_delayedWithdraw_cancelAndGetSharesBack() public {
        // Alice deposits
        vm.startPrank(alice);
        usdc.approve(address(vault), 1_000e6);
        uint256 shares = teller.deposit(ERC20(address(usdc)), 1_000e6, 0);

        // Request withdrawal
        vault.approve(address(delayedWithdraw), shares);
        delayedWithdraw.requestWithdraw(ERC20(address(usdc)), uint96(shares), 100, true);
        assertEq(vault.balanceOf(alice), 0);

        // Cancel
        delayedWithdraw.cancelWithdraw(ERC20(address(usdc)));
        vm.stopPrank();

        // Shares returned
        assertEq(vault.balanceOf(alice), shares);
    }

    function test_delayedWithdraw_thirdPartyComplete() public {
        // Alice deposits
        vm.startPrank(alice);
        usdc.approve(address(vault), 1_000e6);
        uint256 shares = teller.deposit(ERC20(address(usdc)), 1_000e6, 0);

        // Request withdrawal with allowThirdPartyToComplete = true
        vault.approve(address(delayedWithdraw), shares);
        delayedWithdraw.requestWithdraw(ERC20(address(usdc)), uint96(shares), 100, true);
        vm.stopPrank();

        // Wait for delay
        vm.warp(block.timestamp + WITHDRAW_DELAY);

        // Bob completes Alice's withdrawal
        vm.prank(bob);
        uint256 assetsOut = delayedWithdraw.completeWithdraw(ERC20(address(usdc)), alice);

        assertEq(assetsOut, 1_000e6);
        assertEq(usdc.balanceOf(alice), 10_000e6); // Alice gets USDC, not Bob
    }

    // ========================= OUTSTANDING DEBT =========================

    function test_viewOutstandingDebt() public {
        // Alice deposits
        vm.startPrank(alice);
        usdc.approve(address(vault), 1_000e6);
        uint256 shares = teller.deposit(ERC20(address(usdc)), 1_000e6, 0);

        // Request withdrawal
        vault.approve(address(delayedWithdraw), shares);
        delayedWithdraw.requestWithdraw(ERC20(address(usdc)), uint96(shares), 100, true);
        vm.stopPrank();

        // Outstanding debt should be ~1000 USDC
        uint256 debt = delayedWithdraw.viewOutstandingDebt(ERC20(address(usdc)));
        assertEq(debt, 1_000e6);
    }

    // ========================= OPERATOR WORKFLOW =========================

    function test_operator_servicesMultipleWithdrawals() public {
        // Both users deposit
        vm.startPrank(alice);
        usdc.approve(address(vault), 5_000e6);
        uint256 aliceShares = teller.deposit(ERC20(address(usdc)), 5_000e6, 0);
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(address(vault), 3_000e6);
        uint256 bobShares = teller.deposit(ERC20(address(usdc)), 3_000e6, 0);
        vm.stopPrank();

        // Operator supplies all to Aave
        vm.prank(operator);
        vaultManager.supplyToAave(8_000e6);

        // Both request withdrawal
        vm.startPrank(alice);
        vault.approve(address(delayedWithdraw), aliceShares);
        delayedWithdraw.requestWithdraw(ERC20(address(usdc)), uint96(aliceShares), 100, true);
        vm.stopPrank();

        vm.startPrank(bob);
        vault.approve(address(delayedWithdraw), bobShares);
        delayedWithdraw.requestWithdraw(ERC20(address(usdc)), uint96(bobShares), 100, true);
        vm.stopPrank();

        // Operator checks outstanding debt and pulls from Aave
        uint256 debt = delayedWithdraw.viewOutstandingDebt(ERC20(address(usdc)));
        assertEq(debt, 8_000e6);

        vm.prank(operator);
        vaultManager.withdrawAllFromAave();

        // Wait for delay
        vm.warp(block.timestamp + WITHDRAW_DELAY);

        // Both complete
        vm.prank(alice);
        delayedWithdraw.completeWithdraw(ERC20(address(usdc)), alice);
        assertEq(usdc.balanceOf(alice), 10_000e6); // 10000 original - 5000 deposited + 5000 back

        vm.prank(bob);
        delayedWithdraw.completeWithdraw(ERC20(address(usdc)), bob);
        assertEq(usdc.balanceOf(bob), 5_000e6); // 5000 original - 3000 deposited + 3000 back
    }
}
