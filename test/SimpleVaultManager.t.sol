// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Test} from "@forge-std/Test.sol";
import {BoringVault} from "boring-vault/base/BoringVault.sol";
import {SimpleVaultManager} from "../src/SimpleVaultManager.sol";
import {Authority} from "@solmate/auth/Auth.sol";
import {RolesAuthority} from "@solmate/auth/authorities/RolesAuthority.sol";
import {ERC20} from "@solmate/tokens/ERC20.sol";

// ========================= MOCKS =========================

contract MockAToken is ERC20 {
    constructor() ERC20("Aave Base USDC", "aBasUSDC", 6) {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC", 6) {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// @dev Mock Aave Pool: supply burns USDC from caller and mints aUSDC to onBehalfOf.
///      withdraw burns aUSDC from caller and mints USDC to recipient.
contract MockAavePool {
    MockUSDC public usdc;
    MockAToken public aUsdc;

    constructor(MockUSDC _usdc, MockAToken _aUsdc) {
        usdc = _usdc;
        aUsdc = _aUsdc;
    }

    function supply(address, uint256 amount, address onBehalfOf, uint16) external {
        usdc.transferFrom(msg.sender, address(this), amount);
        aUsdc.mint(onBehalfOf, amount);
    }

    function withdraw(address, uint256 amount, address to) external returns (uint256) {
        // If max, withdraw all
        uint256 bal = aUsdc.balanceOf(msg.sender);
        uint256 withdrawAmount = amount == type(uint256).max ? bal : amount;
        aUsdc.transferFrom(msg.sender, address(0xdead), withdrawAmount);
        usdc.mint(to, withdrawAmount);
        return withdrawAmount;
    }
}

// ========================= TESTS =========================

contract SimpleVaultManagerTest is Test {
    event SuppliedToAave(uint256 amount);
    event WithdrawnFromAave(uint256 amount);

    BoringVault vault;
    RolesAuthority rolesAuthority;
    SimpleVaultManager vaultManager;
    MockUSDC usdc;
    MockAToken aUsdc;
    MockAavePool aavePool;

    address owner = address(0xA);
    address manager = address(0xB);

    uint8 constant VAULT_MANAGER_ROLE = 1;
    uint8 constant OWNER_ROLE = 8;

    function setUp() public {
        usdc = new MockUSDC();
        aUsdc = new MockAToken();
        aavePool = new MockAavePool(usdc, aUsdc);

        rolesAuthority = new RolesAuthority(owner, Authority(address(0)));
        vault = new BoringVault(owner, "Robot Money Aave Vault", "rmUSDC", 6);

        vm.prank(owner);
        vault.setAuthority(rolesAuthority);

        vaultManager = new SimpleVaultManager(
            owner, rolesAuthority, vault, address(usdc), address(aavePool)
        );

        vm.startPrank(owner);

        // SimpleVaultManager gets VAULT_MANAGER_ROLE on vault
        rolesAuthority.setUserRole(address(vaultManager), VAULT_MANAGER_ROLE, true);
        rolesAuthority.setRoleCapability(
            VAULT_MANAGER_ROLE,
            address(vault),
            bytes4(keccak256("manage(address,bytes,uint256)")),
            true
        );

        // Manager EOA gets OWNER_ROLE on vaultManager
        rolesAuthority.setUserRole(manager, OWNER_ROLE, true);
        rolesAuthority.setRoleCapability(
            OWNER_ROLE, address(vaultManager), SimpleVaultManager.supplyToAave.selector, true
        );
        rolesAuthority.setRoleCapability(
            OWNER_ROLE, address(vaultManager), SimpleVaultManager.withdrawFromAave.selector, true
        );
        rolesAuthority.setRoleCapability(
            OWNER_ROLE, address(vaultManager), SimpleVaultManager.withdrawAllFromAave.selector, true
        );

        vm.stopPrank();

        // Seed vault with USDC (simulates user deposits via Teller)
        usdc.mint(address(vault), 10_000e6);
    }

    // ========================= SUPPLY =========================

    function test_supplyToAave() public {
        vm.prank(manager);
        vaultManager.supplyToAave(5_000e6);

        assertEq(aUsdc.balanceOf(address(vault)), 5_000e6);
        assertEq(usdc.balanceOf(address(vault)), 5_000e6);
    }

    function test_supplyToAave_fullBalance() public {
        vm.prank(manager);
        vaultManager.supplyToAave(10_000e6);

        assertEq(aUsdc.balanceOf(address(vault)), 10_000e6);
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    function test_supplyToAave_emitsEvent() public {
        vm.prank(manager);
        vm.expectEmit(true, true, true, true);
        emit SuppliedToAave(5_000e6);
        vaultManager.supplyToAave(5_000e6);
    }

    // ========================= WITHDRAW =========================

    function test_withdrawFromAave() public {
        vm.prank(manager);
        vaultManager.supplyToAave(10_000e6);

        // Approve aUSDC for the pool to burn
        vm.prank(address(vault));
        aUsdc.approve(address(aavePool), type(uint256).max);

        vm.prank(manager);
        uint256 actual = vaultManager.withdrawFromAave(3_000e6);

        assertEq(actual, 3_000e6);
        assertEq(usdc.balanceOf(address(vault)), 3_000e6);
        assertEq(aUsdc.balanceOf(address(vault)), 7_000e6);
    }

    function test_withdrawFromAave_emitsEvent() public {
        vm.prank(manager);
        vaultManager.supplyToAave(10_000e6);

        vm.prank(address(vault));
        aUsdc.approve(address(aavePool), type(uint256).max);

        vm.prank(manager);
        vm.expectEmit(true, true, true, true);
        emit WithdrawnFromAave(3_000e6);
        vaultManager.withdrawFromAave(3_000e6);
    }

    function test_withdrawAllFromAave() public {
        vm.prank(manager);
        vaultManager.supplyToAave(10_000e6);

        vm.prank(address(vault));
        aUsdc.approve(address(aavePool), type(uint256).max);

        vm.prank(manager);
        uint256 actual = vaultManager.withdrawAllFromAave();

        assertEq(actual, 10_000e6);
        assertEq(usdc.balanceOf(address(vault)), 10_000e6);
        assertEq(aUsdc.balanceOf(address(vault)), 0);
    }

    // ========================= SUPPLY THEN WITHDRAW ROUND TRIP =========================

    function test_roundTrip() public {
        // Supply all
        vm.prank(manager);
        vaultManager.supplyToAave(10_000e6);
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(aUsdc.balanceOf(address(vault)), 10_000e6);

        // Approve for withdraw
        vm.prank(address(vault));
        aUsdc.approve(address(aavePool), type(uint256).max);

        // Withdraw all
        vm.prank(manager);
        vaultManager.withdrawAllFromAave();
        assertEq(usdc.balanceOf(address(vault)), 10_000e6);
        assertEq(aUsdc.balanceOf(address(vault)), 0);
    }

    // ========================= ACCESS CONTROL =========================

    function test_revert_unauthorizedSupply() public {
        vm.prank(address(0xBAD));
        vm.expectRevert("UNAUTHORIZED");
        vaultManager.supplyToAave(1_000e6);
    }

    function test_revert_unauthorizedWithdraw() public {
        vm.prank(address(0xBAD));
        vm.expectRevert("UNAUTHORIZED");
        vaultManager.withdrawFromAave(1_000e6);
    }

    function test_revert_unauthorizedWithdrawAll() public {
        vm.prank(address(0xBAD));
        vm.expectRevert("UNAUTHORIZED");
        vaultManager.withdrawAllFromAave();
    }

    // ========================= INPUT VALIDATION =========================

    function test_revert_supplyZero() public {
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSignature("SimpleVaultManager__ZeroAmount()"));
        vaultManager.supplyToAave(0);
    }

    function test_revert_withdrawZero() public {
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSignature("SimpleVaultManager__ZeroAmount()"));
        vaultManager.withdrawFromAave(0);
    }

    // ========================= CONSTRUCTOR VALIDATION =========================

    function test_revert_zeroAddressVault() public {
        vm.expectRevert(abi.encodeWithSignature("SimpleVaultManager__ZeroAddress()"));
        new SimpleVaultManager(
            owner, rolesAuthority, BoringVault(payable(address(0))), address(usdc), address(aavePool)
        );
    }

    function test_revert_zeroAddressUsdc() public {
        vm.expectRevert(abi.encodeWithSignature("SimpleVaultManager__ZeroAddress()"));
        new SimpleVaultManager(
            owner, rolesAuthority, vault, address(0), address(aavePool)
        );
    }

    function test_revert_zeroAddressPool() public {
        vm.expectRevert(abi.encodeWithSignature("SimpleVaultManager__ZeroAddress()"));
        new SimpleVaultManager(
            owner, rolesAuthority, vault, address(usdc), address(0)
        );
    }
}
