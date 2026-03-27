// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {BoringVault} from "boring-vault/base/BoringVault.sol";
import {Auth, Authority} from "@solmate/auth/Auth.sol";
import {ERC20} from "@solmate/tokens/ERC20.sol";

/// @title SimpleVaultManager
/// @notice Tightly scoped manager for a BoringVault that only allows three
///         operations: supplying USDC to Aave V3, withdrawing USDC from
///         Aave V3, and rescuing tokens accidentally sent to this contract.
///         All vault interactions flow through vault.manage() and are
///         hardcoded to USDC and the vault's own address, preventing misuse.
contract SimpleVaultManager is Auth {
    // ========================= ERRORS =========================

    error SimpleVaultManager__ZeroAddress();
    error SimpleVaultManager__ZeroAmount();
    error SimpleVaultManager__ApproveFailed();
    error SimpleVaultManager__WithdrawReturnedLessThanRequested(uint256 requested, uint256 actual);
    error SimpleVaultManager__Paused();
    error SimpleVaultManager__NothingToWithdraw();
    error SimpleVaultManager__RescueFailed();

    // ========================= EVENTS =========================

    event SuppliedToAave(uint256 amount);
    event WithdrawnFromAave(uint256 amount);
    event PauseToggled(bool isPaused);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    // ========================= IMMUTABLES =========================

    BoringVault public immutable VAULT;
    address public immutable USDC;
    address public immutable AAVE_POOL;

    // ========================= STATE =========================

    /// @notice Pause flag -- when true, supply and withdraw operations are blocked.
    bool public isPaused;

    // ========================= MODIFIERS =========================

    modifier whenNotPaused() {
        if (isPaused) revert SimpleVaultManager__Paused();
        _;
    }

    // ========================= CONSTRUCTOR =========================

    /// @param _authority Shared RolesAuthority (sole access control -- no Auth owner bypass).
    /// @param _vault     The BoringVault this manager controls.
    /// @param _usdc      USDC token on Base.
    /// @param _aavePool  Aave V3 Pool on Base.
    constructor(
        Authority _authority,
        BoringVault _vault,
        address _usdc,
        address _aavePool
    ) Auth(address(0), _authority) {
        if (address(_vault) == address(0) || _usdc == address(0) || _aavePool == address(0)) {
            revert SimpleVaultManager__ZeroAddress();
        }
        VAULT = _vault;
        USDC = _usdc;
        AAVE_POOL = _aavePool;
    }

    // ========================= MANAGER OPERATIONS =========================

    /// @notice Approve the Aave pool to spend the vault's USDC, then supply
    ///         USDC into Aave V3 on behalf of the vault. Resets approval to
    ///         zero after supply to prevent lingering allowances.
    /// @dev Callable by OPERATOR_ROLE only.
    /// @param amount Amount of USDC to supply.
    function supplyToAave(uint256 amount) external requiresAuth whenNotPaused {
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

        // Step 3: Reset approval to zero to prevent lingering allowance
        VAULT.manage(
            USDC,
            abi.encodeWithSignature("approve(address,uint256)", AAVE_POOL, uint256(0)),
            0
        );

        emit SuppliedToAave(amount);
    }

    /// @notice Withdraw USDC from Aave V3 back to the vault.
    /// @dev Callable by OPERATOR_ROLE only.
    /// @param amount Amount of USDC to withdraw from Aave.
    /// @return actualAmount The amount actually withdrawn.
    function withdrawFromAave(uint256 amount) external requiresAuth whenNotPaused returns (uint256 actualAmount) {
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
    ///      Reverts if the vault has no Aave position.
    ///      Callable by OPERATOR_ROLE only.
    /// @return actualAmount The amount actually withdrawn.
    function withdrawAllFromAave() external requiresAuth whenNotPaused returns (uint256 actualAmount) {
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
        if (actualAmount == 0) revert SimpleVaultManager__NothingToWithdraw();

        emit WithdrawnFromAave(actualAmount);
    }

    // ========================= ADMIN =========================

    /// @notice Pause or unpause supply and withdraw operations.
    /// @dev Callable by ADMIN_ROLE only.
    function setPaused(bool _isPaused) external requiresAuth {
        isPaused = _isPaused;
        emit PauseToggled(_isPaused);
    }

    /// @notice Rescue ERC20 tokens accidentally sent to this contract.
    /// @dev Callable by ADMIN_ROLE only. Cannot be used to move vault funds
    ///      since the vault holds its own assets -- this contract should
    ///      never hold tokens under normal operation.
    /// @param token The ERC20 token to rescue.
    /// @param to    Recipient address.
    /// @param amount Amount to transfer.
    function rescueTokens(address token, address to, uint256 amount) external requiresAuth {
        if (to == address(0)) revert SimpleVaultManager__ZeroAddress();
        if (amount == 0) revert SimpleVaultManager__ZeroAmount();

        bool success = ERC20(token).transfer(to, amount);
        if (!success) revert SimpleVaultManager__RescueFailed();

        emit Rescued(token, to, amount);
    }
}
