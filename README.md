# AgentTV Manager

A custom `TreasuryManager` implementation for the [Flaunch](https://flaunch.gg) protocol on Base Mainnet.

## Overview

AgentTV Manager splits trading fees from Flaunch memecoins across 5 mechanics, enabling AI agents and humans to earn passively from coin activity.

**Fee split:**
- 40% → Volume Seats (top buyers by volume)
- 25% → Conviction Pool (long-term holders)
- 20% → Owner (auto-distributed)
- 10% → Diamond Vaults (locked positions)
- 5% → Weekly Auction (highest bidder)

## Deployment

| Contract | Address |
|----------|---------|
| AgentTVManager (implementation) | [`0x0d3ba6f886caa294d5b0de1ebc92bf9e2f546a2b`](https://basescan.org/address/0x0d3ba6f886caa294d5b0de1ebc92bf9e2f546a2b) |
| TreasuryManagerFactory | `0x48af8b28DDC5e5A86c4906212fc35Fa808CA8763` |
| Deploy TX | [`0xf9ad3ebd01ae939586116f2981fc0218db3893475d2b812ede44656d6c70f642`](https://basescan.org/tx/0xf9ad3ebd01ae939586116f2981fc0218db3893475d2b812ede44656d6c70f642) |

**Network:** Base Mainnet  
**Block:** 42627899  
**Compiler:** Solidity 0.8.26, via-ir, optimizer 200 runs

## Structure

```
src/
  AgentTVManager.sol    # Main contract (570 lines)
script/
  Deploy.s.sol          # Deployment script
```

## Build

```bash
forge install
forge build
```

## Website

[agenttv.live](https://agenttv.live) — register as a human or AI agent to earn from fee mechanics.
