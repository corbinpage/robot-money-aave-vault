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
|  BoringVault   |<---------|  SimpleVault      |<-- Manager EOA
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
2. **Manager calls `supplyToAave()`** to move the vault's idle USDC into Aave V3, earning yield
3. **Aave yield accrues** as the vault's aUSDC balance grows over time
4. **Manager calls `withdrawFromAave()`** when USDC liquidity is needed (e.g., for user withdrawals)
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
| `supplyToAave(amount)` | Approves Aave pool, then calls `Pool.supply(USDC, amount, vault, 0)` |
| `withdrawFromAave(amount)` | Calls `Pool.withdraw(USDC, amount, vault)` — reverts if Aave returns less than requested |
| `withdrawAllFromAave()` | Calls `Pool.withdraw(USDC, type(uint256).max, vault)` — withdraws entire Aave position |

**Why a scoped manager?** Even if the manager EOA is compromised, the attacker can only supply/withdraw USDC to/from Aave — they cannot approve arbitrary spenders, transfer tokens to arbitrary addresses, or make arbitrary calls through the vault.

## Access Control

```
Manager EOA
    |
    | supplyToAave(amount)
    | withdrawFromAave(amount)
    | withdrawAllFromAave()
    v
SimpleVaultManager     [OWNER_ROLE required on manager]
    |
    | vault.manage(usdc, approve...)
    | vault.manage(aavePool, supply/withdraw...)
    v
BoringVault            [VAULT_MANAGER_ROLE required on vault]
```

| Role | ID | Assigned To | Can Call |
|---|---|---|---|
| `VAULT_MANAGER_ROLE` | 1 | SimpleVaultManager | `vault.manage()` |
| `OWNER_ROLE` | 8 | Manager EOA | `supplyToAave`, `withdrawFromAave`, `withdrawAllFromAave` |

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
# Set environment variables
export OWNER=0x...
export MANAGER=0x...

# Deploy to Base
forge script script/DeployVault.s.sol --rpc-url base --broadcast
```

### Post-Deployment Steps

1. Deploy Teller and Accountant via Veda's [Arctic Architecture](https://github.com/Se7en-Seas/boring-vault) tooling
2. Configure the Teller to accept USDC deposits (no withdrawal queue)
3. Manager calls `supplyToAave()` to deploy vault USDC into Aave V3

## Comparison with ClawTogether

This vault is a simplified version of [ClawTogether Contracts](https://github.com/corbinpage/clawtogether-contracts). The key differences:

| Feature | Robot Money Aave Vault | ClawTogether |
|---|---|---|
| Aave supply/withdraw | Yes | Yes |
| Game rewards distribution | No | Yes |
| Custom fee splits | No | Yes (protocol/vault/winner) |
| GameMaster role | No | Yes |
| Contracts | 1 (SimpleVaultManager) | 2 (ScopedVaultProxy + GameRewardsDistributor) |

## License

MIT
