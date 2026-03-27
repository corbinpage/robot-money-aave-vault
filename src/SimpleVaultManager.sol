// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {BoringVault} from "boring-vault/base/BoringVault.sol";
import {Auth, Authority} from "@solmate/auth/Auth.sol";

/// @title SimpleVaultManager
/// @notice Tightly scoped manager for a BoringVault that only allows two
///         operations: supplying USDC to Aave V3 and withdrawing USDC from
///         Aave V3. All interactions flow through vault.manage() but are
///         hardcoded to USDC and the vault's own address, preventing misuse.
contract SimpleVaultManager is Auth {
    // ========================= ERRORS =========================

    error SimpleVaultManager__ZeroAddress();
    error SimpleVaultManager__ZeroAmount();
    error SimpleVaultManager__ApproveFailed();
    error SimpleVaultManager__WithdrawReturnedLessThanRequested(uint256 requested, uint256 actual);

    // ========================= EVENTS =========================

    event SuppliedToAave(uint256 amount);
    event WithdrawnFromAave(uint256 amount);

    // ========================= IMMUTABLES =========================

    BoringVault public immutable VAULT;
    address public immutable USDC;
    address public immutable AAVE_POOL;

    // ========================= CONSTRUCTOR =========================

    /// @param _owner     Owner address (for Auth).
    /// @param _authority Shared RolesAuthority.
    /// @param _vault     The BoringVault this manager controls.
    /// @param _usdc      USDC token on Base.
    /// @param _aavePool  Aave V3 Pool on Base.
    constructor(
        address _owner,
        Authority _authority,
        BoringVault _vault,
        address _usdc,
        address _aavePool
    ) Auth(_owner, _authority) {
        if (address(_vault) == address(0) || _usdc == address(0) || _aavePool == address(0)) {
            revert SimpleVaultManager__ZeroAddress();
        }
        VAULT = _vault;
        USDC = _usdc;
        AAVE_POOL = _aavePool;
    }

    // ========================= MANAGER OPERATIONS =========================

    /// @notice Approve the Aave pool to spend the vault's USDC, then supply
    ///         USDC into Aave V3 on behalf of the vault.
    /// @dev Callable by MANAGER_ROLE only.
    /// @param amount Amount of USDC to supply.
    function supplyToAave(uint256 amount) external requiresAuth {
        if (amount == 0) revert SimpleVaultManager__ZeroAmount();

        // Step 1: Approve the Aave pool to pull USDC from the vault
        bytes memory approveReturn = VAULT.manage(
            USDC,
            abi.encodeWithSignature("approve(address,uint256)", AAVE_POOL, amount),
            0
        );
        bool approved = abi.decode(approveReturn, (bool));
        if (!approved) revert SimpleVaultManager__ApproveFailed();

        // Step 2: Supply USDC to Aave on behalf of the vault
        VAULT.manage(
            AAVE_POOL,
            abi.encodeWithSignature(
                "supply(address,uint256,address,uint16)",
                USDC,
                amount,
                address(VAULT),
                uint16(0)
            ),
            0
        );

        emit SuppliedToAave(amount);
    }

    /// @notice Withdraw USDC from Aave V3 back to the vault.
    /// @dev Callable by MANAGER_ROLE only.
    /// @param amount Amount of USDC to withdraw from Aave.
    /// @return actualAmount The amount actually withdrawn.
    function withdrawFromAave(uint256 amount) external requiresAuth returns (uint256 actualAmount) {
        if (amount == 0) revert SimpleVaultManager__ZeroAmount();

        bytes memory returnData = VAULT.manage(
            AAVE_POOL,
            abi.encodeWithSignature(
                "withdraw(address,uint256,address)",
                USDC,
                amount,
                address(VAULT)
            ),
            0
        );

        actualAmount = abi.decode(returnData, (uint256));
        if (actualAmount < amount) {
            revert SimpleVaultManager__WithdrawReturnedLessThanRequested(amount, actualAmount);
        }

        emit WithdrawnFromAave(actualAmount);
    }

    /// @notice Withdraw the maximum available USDC from Aave V3 back to the vault.
    /// @dev Passes type(uint256).max to Aave which withdraws the full balance.
    ///      Callable by MANAGER_ROLE only.
    /// @return actualAmount The amount actually withdrawn.
    function withdrawAllFromAave() external requiresAuth returns (uint256 actualAmount) {
        bytes memory returnData = VAULT.manage(
            AAVE_POOL,
            abi.encodeWithSignature(
                "withdraw(address,uint256,address)",
                USDC,
                type(uint256).max,
                address(VAULT)
            ),
            0
        );

        actualAmount = abi.decode(returnData, (uint256));

        emit WithdrawnFromAave(actualAmount);
    }
}
