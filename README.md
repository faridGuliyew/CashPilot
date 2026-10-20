# CashPilot

AI invoice-factoring and cash-flow copilot for SMEs: forecasts cash shortfalls, picks the cheapest way to cover them, and finances buyer-confirmed invoices on-chain — with the owner's signature always required to move money.

Built for WeBank Fintechathon 2026 (International Track, Topic E "SME Finance Copilot").

## Quick start

```bash
cp .env.example .env      # fill in testnet keys
make install              # Python venv + agent package
make build                # compile contracts (needs Foundry)
make test                 # forge test + pytest
```
