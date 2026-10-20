# AuditFlow AI

Privacy-preserving multi-agent working capital optimization for SMEs. AI agents for a supplier and a buyer negotiate early payment of an invoice at a discount, each bound by its own private limits; a deterministic optimizer (BILNO) checks that the deal is good for both sides under risk limits — or refuses it. Both companies sign the exact terms, a bank sandbox executes the payment, and the agreement lifecycle is recorded on a shared ledger.

Built for WeBank Fintechathon 2026 (International Track, Topic E "SME Finance Copilot").

## Quick start

```bash
cp .env.example .env      # fill in testnet keys
make install              # Python venv + auditflow package
make build                # compile contracts (needs Foundry)
make test                 # forge test + pytest
```
