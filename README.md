# Robot Money Aave Vault

A minimal DeFi vault built on [Veda's Boring Vault](https://github.com/Se7en-Seas/boring-vault) architecture, deployed on Base. The vault accepts USDC deposits, earns yield by supplying USDC to Aave V3, and supports delayed withdrawals with a 1-day delay.

## Architecture

```
+------------------------------------------------------------------------+
|                          RolesAuthority                                 |
|                     (shared access control)                             |
+---+----------+----------+-----------+----------+-----------------------+
    |          |          |           |          |
    v          v          v           v          v
+--------+ +-------+ +--------+ +---------+ +---------+
|Boring  | |Account| |Teller  | |Delayed  | |Simple   |
|Vault   | |ant    | |        | |Withdraw | |Vault    |<-- Operator
|(rmUSDC)| |       | |        | |         | |Manager  |
+--------+ +-------+ +--------+ +---------+ +---------+
    ^          |          |           |          |
    |          |  enter() |   exit()  | manage() |
    +----------+----------+-----------+----------+
```

### How It Works

**Depositing:**
1. User approves USDC to the vault address
2. User calls `teller.deposit(USDC, amount, minimumShares)`
3. Teller calls `vault.enter()` — USDC transfers in, `rmUSDC` shares mint to user

**Earning Yield:**
1. Operator calls `vaultManager.supplyToAave(amount)` to move idle USDC into Aave V3
2. Aave yield accrues as the vault's aUSDC balance grows over time
3. Accountant's exchange rate is updated to reflect the new value

**Withdrawing (1-day delay):**
1. User approves vault shares to the DelayedWithdraw contract
2. User calls `delayedWithdraw.requestWithdraw(USDC, shares, maxLoss, allowThirdParty)`
3. Operator sees pending debt, calls `vaultManager.withdrawFromAave()` to get USDC back
4. After 1 day, user (or anyone if allowed) calls `delayedWithdraw.completeWithdraw(USDC, user)`
5. Shares burn, USDC transfers to user

## Contracts

### `BoringVault` (Veda)

ERC20 vault token (`rmUSDC`, 6 decimals) and asset custodian. All external calls go through `manage()`, gated by `requiresAuth`.

### `AccountantWithRateProviders` (Veda)

Tracks the exchange rate between USDC and vault shares. Used by the Teller for deposit pricing and by DelayedWithdraw for slippage protection.

### `TellerWithMultiAssetSupport` (Veda)

Handles user deposits. Configured to accept USDC deposits only (no direct withdrawals — those go through DelayedWithdraw). Also serves as the vault's `beforeTransferHook` for share lock enforcement.

### `DelayedWithdraw` (Veda) — [`lib/boring-vault/src/base/Roles/DelayedWithdraw.sol`](lib/boring-vault/src/base/Roles/DelayedWithdraw.sol)

Handles user withdrawals with a time delay. Configuration:

| Parameter | Value | Description |
|---|---|---|
| Withdraw delay | 1 day | Time user must wait after requesting |
| Completion window | 7 days | Window to complete after maturity |
| Withdraw fee | 0% | No fee on withdrawals |
| Max loss | 1% | Max exchange rate slippage allowed |
| Pull from vault | true | Pulls USDC from vault on completion (vs pre-funding) |

### `SimpleVaultManager` — [`src/SimpleVaultManager.sol`](src/SimpleVaultManager.sol)

Tightly scoped manager for Aave operations. Only exposes three hardcoded operations:

| Function | What it does |
|---|---|
| `supplyToAave(amount)` | Approves Aave pool, supplies USDC, resets approval to zero |
| `withdrawFromAave(amount)` | Withdraws USDC from Aave — reverts if Aave returns less than requested |
| `withdrawAllFromAave()` | Withdraws entire Aave position — reverts if nothing to withdraw |

Even if the operator EOA is compromised, the attacker can only supply/withdraw USDC to/from Aave.

### Safety Features

- **No Auth owner bypass** — SimpleVaultManager uses `address(0)` as Auth owner; all access is role-based
- **Approval cleanup** — USDC approval to Aave is reset to zero after each supply
- **Pause mechanism** — admin can halt all supply/withdraw operations
- **Token rescue** — admin can recover ERC20s accidentally sent to the manager contract
- **Slippage protection** — DelayedWithdraw checks exchange rate hasn't moved more than 1% between request and completion
- **Separated roles** — operator cannot pause, admin cannot supply/withdraw

## Access Control

```
User
  ├─ teller.deposit()              [PUBLIC]
  ├─ delayedWithdraw.requestWithdraw()  [PUBLIC]
  ├─ delayedWithdraw.cancelWithdraw()   [PUBLIC]
  └─ delayedWithdraw.completeWithdraw() [PUBLIC]

Operator EOA
  ├─ vaultManager.supplyToAave()        [OPERATOR_ROLE]
  ├─ vaultManager.withdrawFromAave()    [OPERATOR_ROLE]
  └─ vaultManager.withdrawAllFromAave() [OPERATOR_ROLE]

Admin EOA
  ├─ vaultManager.setPaused()           [ADMIN_ROLE]
  ├─ vaultManager.rescueTokens()        [ADMIN_ROLE]
  ├─ teller.updateAssetData()           [ADMIN_ROLE]
  ├─ accountant.updateExchangeRate()    [ADMIN_ROLE]
  ├─ delayedWithdraw.setupWithdrawAsset() [ADMIN_ROLE]
  ├─ delayedWithdraw.changeWithdrawDelay() [ADMIN_ROLE]
  ├─ delayedWithdraw.pause/unpause()    [ADMIN_ROLE]
  └─ delayedWithdraw.changeMaxLoss()    [ADMIN_ROLE]
```

| Role | ID | Assigned To | Purpose |
|---|---|---|---|
| `VAULT_MANAGER_ROLE` | 1 | SimpleVaultManager | `vault.manage()` |
| `TELLER_ROLE` | 2 | Teller | `vault.enter()` |
| `DELAYED_WITHDRAW_ROLE` | 3 | DelayedWithdraw | `vault.exit()` |
| `OPERATOR_ROLE` | 8 | Operator EOA | Aave supply/withdraw |
| `ADMIN_ROLE` | 9 | Admin EOA | Config, pause, rescue |

## Withdrawal Flow Diagram

```
User                    DelayedWithdraw           Operator            Vault/Aave
  │                          │                       │                    │
  ├─requestWithdraw()───────>│                       │                    │
  │  (shares lock)           │                       │                    │
  │                          ├─viewOutstandingDebt()──>                   │
  │                          │                       │                    │
  │                          │        withdrawFromAave()─────────────────>│
  │                          │                       │              (USDC returns)
  │                          │                       │                    │
  │  ~~~ 1 day passes ~~~   │                       │                    │
  │                          │                       │                    │
  ├─completeWithdraw()──────>│                       │                    │
  │                          ├─vault.exit()──────────────────────────────>│
  │                          │                       │        (burn shares, send USDC)
  │<──────── USDC ───────────┘                       │                    │
```

## Base Addresses

| Contract | Address |
|---|---|
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| aBasUSDC | `0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB` |
| Aave V3 Pool | `0xA238Dd80C259a72e81d7e4664a9801593F98d1c5` |
| WETH | `0x4200000000000000000000000000000000000006` |

## Development

### Build

```bash
forge build
```

### Test

```bash
forge test -vvv
```

### Deploy

```bash
# Required environment variables (deploy reverts if unset)
export OWNER=0x...
export OPERATOR=0x...

# Deploy to Base
forge script script/DeployVault.s.sol --rpc-url base --broadcast
```

### Post-Deployment Checklist

1. Verify all contracts on Basescan
2. Confirm RolesAuthority ownership transferred to OWNER
3. Operator calls `supplyToAave()` to deploy initial USDC into Aave
4. Admin updates exchange rate on Accountant as yield accrues
5. Monitor `delayedWithdraw.viewOutstandingDebt(USDC)` to service pending withdrawals

## License

MIT
