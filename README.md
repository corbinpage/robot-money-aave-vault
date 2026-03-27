# Robot Money Aave Vault

A minimal DeFi vault built on [Veda's Boring Vault](https://github.com/Se7en-Seas/boring-vault) architecture, deployed on Base. The vault accepts USDC deposits and earns yield by supplying USDC to Aave V3.

## Architecture

```
+-----------------------------------------------------------------+
|                       RolesAuthority                             |
|                  (shared access control)                         |
+--------+---------------------------+----------------------------+
         |                           |
         v                           v
+----------------+          +-------------------+
|  BoringVault   |<---------|  SimpleVault      |<-- Operator EOA
|   (rmUSDC)     |          |     Manager       |
|                |          |                   |
| holds USDC     |  manage  | VAULT_MANAGER_ROLE|
| holds aUSDC    |<---------|  on vault         |
+----------------+          +-------------------+
        ^
        | deposit / withdraw
        |
+-------+--------------------------------------------------------+
|  Veda Arctic Architecture (deployed separately)                 |
|  +----------------------+  +------------------+                 |
|  | TellerWithMultiAsset |  |    Accountant    |                 |
|  |      Support         |  | WithRateProviders|                 |
|  +----------------------+  +------------------+                 |
+-----------------------------------------------------------------+
```

### How It Works

1. **Users deposit USDC** via the Veda Teller, receiving `rmUSDC` vault shares
2. **Operator calls `supplyToAave()`** to move the vault's idle USDC into Aave V3, earning yield
3. **Aave yield accrues** as the vault's aUSDC balance grows over time
4. **Operator calls `withdrawFromAave()`** when USDC liquidity is needed (e.g., for user withdrawals)
5. **Users withdraw** via the Teller, burning their `rmUSDC` shares for USDC

## Contracts

### `BoringVault` (Veda)

The core vault contract from Veda's Boring Vault. An ERC20 token (`rmUSDC`, 6 decimals) that also serves as the asset custodian. It can make arbitrary external calls via `manage()`, gated by `requiresAuth`.

- Not ERC-4626 — uses a custom `enter`/`exit` pattern for deposits and withdrawals
- The vault is intentionally "boring" — all logic lives in surrounding contracts

### `SimpleVaultManager` — [`src/SimpleVaultManager.sol`](src/SimpleVaultManager.sol)

A tightly scoped manager that holds `VAULT_MANAGER_ROLE` on the vault but only exposes three hardcoded operations:

| Function | What it does |
|---|---|
| `supplyToAave(amount)` | Approves Aave pool, calls `Pool.supply(USDC, amount, vault, 0)`, then resets approval to zero |
| `withdrawFromAave(amount)` | Calls `Pool.withdraw(USDC, amount, vault)` — reverts if Aave returns less than requested |
| `withdrawAllFromAave()` | Calls `Pool.withdraw(USDC, type(uint256).max, vault)` — withdraws entire Aave position, reverts if zero |

**Why a scoped manager?** Even if the operator EOA is compromised, the attacker can only supply/withdraw USDC to/from Aave — they cannot approve arbitrary spenders, transfer tokens to arbitrary addresses, or make arbitrary calls through the vault.

### Safety Features

- **No Auth owner bypass** — the SimpleVaultManager is deployed with `address(0)` as Auth owner, so all access goes through the RolesAuthority role system exclusively
- **Approval cleanup** — USDC approval to Aave is reset to zero after each supply, preventing lingering allowances
- **Pause mechanism** — admin can call `setPaused(true)` to halt all supply/withdraw operations in an emergency
- **Token rescue** — admin can recover ERC20 tokens accidentally sent to the manager contract via `rescueTokens()`
- **Zero-balance guard** — `withdrawAllFromAave()` reverts if the vault has no Aave position

## Access Control

```
Operator EOA
    |
    | supplyToAave(amount)
    | withdrawFromAave(amount)
    | withdrawAllFromAave()
    v
SimpleVaultManager     [OPERATOR_ROLE required]
    |
    | vault.manage(usdc, approve...)
    | vault.manage(aavePool, supply/withdraw...)
    v
BoringVault            [VAULT_MANAGER_ROLE required]
```

| Role | ID | Assigned To | Can Call |
|---|---|---|---|
| `VAULT_MANAGER_ROLE` | 1 | SimpleVaultManager | `vault.manage()` |
| `OPERATOR_ROLE` | 8 | Operator EOA | `supplyToAave`, `withdrawFromAave`, `withdrawAllFromAave` |
| `ADMIN_ROLE` | 9 | Admin EOA | `setPaused`, `rescueTokens` |

Operator and admin roles are separated — the operator cannot pause, and the admin cannot supply/withdraw. This limits blast radius if either key is compromised.

## Base Addresses

| Contract | Address |
|---|---|
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| aBasUSDC | `0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB` |
| Aave V3 Pool | `0xA238Dd80C259a72e81d7e4664a9801593F98d1c5` |

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

### Post-Deployment Steps

1. Deploy Teller and Accountant via Veda's [Arctic Architecture](https://github.com/Se7en-Seas/boring-vault) tooling
2. Configure the Teller to accept USDC deposits (no withdrawal queue)
3. Operator calls `supplyToAave()` to deploy vault USDC into Aave V3

## License

MIT
