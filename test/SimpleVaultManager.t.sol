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
    function burn(address from, uint256 amount) external { _burn(from, amount); }
}

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC", 6) {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// @dev Mock Aave Pool that more accurately models real Aave V3 behavior.
///      supply: pulls USDC from caller, mints aUSDC to onBehalfOf.
///      withdraw: burns aUSDC directly from msg.sender (no transferFrom/approval needed),
///               mints USDC to recipient. This matches real Aave V3 where the Pool
///               has internal burn authority on aTokens.
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
        uint256 bal = aUsdc.balanceOf(msg.sender);
        uint256 withdrawAmount = amount == type(uint256).max ? bal : amount;
        // Real Aave burns aTokens directly -- no approval needed from the holder
        aUsdc.burn(msg.sender, withdrawAmount);
        usdc.mint(to, withdrawAmount);
        return withdrawAmount;
    }
}

// ========================= TESTS =========================

contract SimpleVaultManagerTest is Test {
    event SuppliedToAave(uint256 amount);
    event WithdrawnFromAave(uint256 amount);
    event PauseToggled(bool isPaused);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    BoringVault vault;
    RolesAuthority rolesAuthority;
    SimpleVaultManager vaultManager;
    MockUSDC usdc;
    MockAToken aUsdc;
    MockAavePool aavePool;

    address admin = address(0xA);
    address operator = address(0xB);

    uint8 constant VAULT_MANAGER_ROLE = 1;
    uint8 constant OPERATOR_ROLE = 8;
    uint8 constant ADMIN_ROLE = 9;

    function setUp() public {
        usdc = new MockUSDC();
        aUsdc = new MockAToken();
        aavePool = new MockAavePool(usdc, aUsdc);

        rolesAuthority = new RolesAuthority(admin, Authority(address(0)));
        vault = new BoringVault(admin, "Robot Money Aave Vault", "rmUSDC", 6);

        vm.prank(admin);
        vault.setAuthority(rolesAuthority);

        // No Auth owner -- access is purely role-based
        vaultManager = new SimpleVaultManager(
            rolesAuthority, vault, address(usdc), address(aavePool)
        );

        vm.startPrank(admin);

        // SimpleVaultManager gets VAULT_MANAGER_ROLE on vault
        rolesAuthority.setUserRole(address(vaultManager), VAULT_MANAGER_ROLE, true);
        rolesAuthority.setRoleCapability(
            VAULT_MANAGER_ROLE,
            address(vault),
            bytes4(keccak256("manage(address,bytes,uint256)")),
            true
        );

        // Operator gets OPERATOR_ROLE on vaultManager
        rolesAuthority.setUserRole(operator, OPERATOR_ROLE, true);
        rolesAuthority.setRoleCapability(
            OPERATOR_ROLE, address(vaultManager), SimpleVaultManager.supplyToAave.selector, true
        );
        rolesAuthority.setRoleCapability(
            OPERATOR_ROLE, address(vaultManager), SimpleVaultManager.withdrawFromAave.selector, true
        );
        rolesAuthority.setRoleCapability(
            OPERATOR_ROLE, address(vaultManager), SimpleVaultManager.withdrawAllFromAave.selector, true
        );

        // Admin gets ADMIN_ROLE for pause and rescue
        rolesAuthority.setUserRole(admin, ADMIN_ROLE, true);
        rolesAuthority.setRoleCapability(
            ADMIN_ROLE, address(vaultManager), SimpleVaultManager.setPaused.selector, true
        );
        rolesAuthority.setRoleCapability(
            ADMIN_ROLE, address(vaultManager), SimpleVaultManager.rescueTokens.selector, true
        );

        vm.stopPrank();

        // Seed vault with USDC (simulates user deposits via Teller)
        usdc.mint(address(vault), 10_000e6);
    }

    // ========================= SUPPLY =========================

    function test_supplyToAave() public {
        vm.prank(operator);
        vaultManager.supplyToAave(5_000e6);

        assertEq(aUsdc.balanceOf(address(vault)), 5_000e6);
        assertEq(usdc.balanceOf(address(vault)), 5_000e6);
    }

    function test_supplyToAave_fullBalance() public {
        vm.prank(operator);
        vaultManager.supplyToAave(10_000e6);

        assertEq(aUsdc.balanceOf(address(vault)), 10_000e6);
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    function test_supplyToAave_emitsEvent() public {
        vm.prank(operator);
        vm.expectEmit(true, true, true, true);
        emit SuppliedToAave(5_000e6);
        vaultManager.supplyToAave(5_000e6);
    }

    function test_supplyToAave_resetsApproval() public {
        vm.prank(operator);
        vaultManager.supplyToAave(5_000e6);

        // After supply, the vault's USDC allowance to the Aave pool should be zero
        assertEq(usdc.allowance(address(vault), address(aavePool)), 0);
    }

    // ========================= WITHDRAW =========================

    function test_withdrawFromAave() public {
        vm.prank(operator);
        vaultManager.supplyToAave(10_000e6);

        vm.prank(operator);
        uint256 actual = vaultManager.withdrawFromAave(3_000e6);

        assertEq(actual, 3_000e6);
        assertEq(usdc.balanceOf(address(vault)), 3_000e6);
        assertEq(aUsdc.balanceOf(address(vault)), 7_000e6);
    }

    function test_withdrawFromAave_emitsEvent() public {
        vm.prank(operator);
        vaultManager.supplyToAave(10_000e6);

        vm.prank(operator);
        vm.expectEmit(true, true, true, true);
        emit WithdrawnFromAave(3_000e6);
        vaultManager.withdrawFromAave(3_000e6);
    }

    function test_withdrawAllFromAave() public {
        vm.prank(operator);
        vaultManager.supplyToAave(10_000e6);

        vm.prank(operator);
        uint256 actual = vaultManager.withdrawAllFromAave();

        assertEq(actual, 10_000e6);
        assertEq(usdc.balanceOf(address(vault)), 10_000e6);
        assertEq(aUsdc.balanceOf(address(vault)), 0);
    }

    function test_withdrawAllFromAave_revertsOnZeroBalance() public {
        // No supply -- vault has no Aave position
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSignature("SimpleVaultManager__NothingToWithdraw()"));
        vaultManager.withdrawAllFromAave();
    }

    // ========================= ROUND TRIP =========================

    function test_roundTrip() public {
        // Supply all
        vm.prank(operator);
        vaultManager.supplyToAave(10_000e6);
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(aUsdc.balanceOf(address(vault)), 10_000e6);

        // Withdraw all -- no manual aToken approval needed (matches real Aave)
        vm.prank(operator);
        vaultManager.withdrawAllFromAave();
        assertEq(usdc.balanceOf(address(vault)), 10_000e6);
        assertEq(aUsdc.balanceOf(address(vault)), 0);
    }

    // ========================= PAUSE =========================

    function test_pause_blocksSupply() public {
        vm.prank(admin);
        vaultManager.setPaused(true);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSignature("SimpleVaultManager__Paused()"));
        vaultManager.supplyToAave(1_000e6);
    }

    function test_pause_blocksWithdraw() public {
        vm.prank(operator);
        vaultManager.supplyToAave(5_000e6);

        vm.prank(admin);
        vaultManager.setPaused(true);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSignature("SimpleVaultManager__Paused()"));
        vaultManager.withdrawFromAave(1_000e6);
    }

    function test_pause_blocksWithdrawAll() public {
        vm.prank(operator);
        vaultManager.supplyToAave(5_000e6);

        vm.prank(admin);
        vaultManager.setPaused(true);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSignature("SimpleVaultManager__Paused()"));
        vaultManager.withdrawAllFromAave();
    }

    function test_unpause_allowsOperations() public {
        vm.prank(admin);
        vaultManager.setPaused(true);

        vm.prank(admin);
        vaultManager.setPaused(false);

        vm.prank(operator);
        vaultManager.supplyToAave(1_000e6);
        assertEq(aUsdc.balanceOf(address(vault)), 1_000e6);
    }

    function test_pause_emitsEvent() public {
        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit PauseToggled(true);
        vaultManager.setPaused(true);
    }

    // ========================= RESCUE =========================

    function test_rescueTokens() public {
        // Accidentally send USDC to the manager contract
        usdc.mint(address(vaultManager), 500e6);

        vm.prank(admin);
        vaultManager.rescueTokens(address(usdc), admin, 500e6);

        assertEq(usdc.balanceOf(admin), 500e6);
        assertEq(usdc.balanceOf(address(vaultManager)), 0);
    }

    function test_rescueTokens_emitsEvent() public {
        usdc.mint(address(vaultManager), 100e6);

        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit Rescued(address(usdc), admin, 100e6);
        vaultManager.rescueTokens(address(usdc), admin, 100e6);
    }

    function test_revert_rescueUnauthorized() public {
        usdc.mint(address(vaultManager), 100e6);

        vm.prank(operator);
        vm.expectRevert("UNAUTHORIZED");
        vaultManager.rescueTokens(address(usdc), operator, 100e6);
    }

    function test_revert_rescueZeroAddress() public {
        usdc.mint(address(vaultManager), 100e6);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("SimpleVaultManager__ZeroAddress()"));
        vaultManager.rescueTokens(address(usdc), address(0), 100e6);
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

    function test_revert_unauthorizedPause() public {
        vm.prank(operator);
        vm.expectRevert("UNAUTHORIZED");
        vaultManager.setPaused(true);
    }

    function test_adminCannotSupply() public {
        // Admin role should NOT be able to call operator functions
        vm.prank(admin);
        vm.expectRevert("UNAUTHORIZED");
        vaultManager.supplyToAave(1_000e6);
    }

    function test_operatorCannotPause() public {
        vm.prank(operator);
        vm.expectRevert("UNAUTHORIZED");
        vaultManager.setPaused(true);
    }

    // ========================= INPUT VALIDATION =========================

    function test_revert_supplyZero() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSignature("SimpleVaultManager__ZeroAmount()"));
        vaultManager.supplyToAave(0);
    }

    function test_revert_withdrawZero() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSignature("SimpleVaultManager__ZeroAmount()"));
        vaultManager.withdrawFromAave(0);
    }

    // ========================= CONSTRUCTOR VALIDATION =========================

    function test_revert_zeroAddressVault() public {
        vm.expectRevert(abi.encodeWithSignature("SimpleVaultManager__ZeroAddress()"));
        new SimpleVaultManager(
            rolesAuthority, BoringVault(payable(address(0))), address(usdc), address(aavePool)
        );
    }

    function test_revert_zeroAddressUsdc() public {
        vm.expectRevert(abi.encodeWithSignature("SimpleVaultManager__ZeroAddress()"));
        new SimpleVaultManager(
            rolesAuthority, vault, address(0), address(aavePool)
        );
    }

    function test_revert_zeroAddressPool() public {
        vm.expectRevert(abi.encodeWithSignature("SimpleVaultManager__ZeroAddress()"));
        new SimpleVaultManager(
            rolesAuthority, vault, address(usdc), address(0)
        );
    }

    // ========================= FUZZ =========================

    function testFuzz_supplyAndWithdraw(uint256 supplyAmount, uint256 withdrawAmount) public {
        supplyAmount = bound(supplyAmount, 1, 10_000e6);
        withdrawAmount = bound(withdrawAmount, 1, supplyAmount);

        vm.prank(operator);
        vaultManager.supplyToAave(supplyAmount);

        vm.prank(operator);
        vaultManager.withdrawFromAave(withdrawAmount);

        assertEq(usdc.balanceOf(address(vault)), 10_000e6 - supplyAmount + withdrawAmount);
        assertEq(aUsdc.balanceOf(address(vault)), supplyAmount - withdrawAmount);
    }
}
