# Ledger target

**Used: EVM — Base Sepolia testnet (`LEDGER_TARGET=evm`, chain id 84532).**

FISCO BCOS 3.x was the preferred target but was **not attempted** in this phase: the team decided to deploy
directly to Base Sepolia to protect the deadline. A FISCO attempt may be made at the end, limited to 3 failed
attempts. Until a FISCO deployment actually works, nothing in this repo claims FISCO BCOS support.

- Contracts: `InvoiceRegistry`, `AgreementLedger` (`contracts/src/`), deployed by `contracts/script/Deploy.s.sol`.
- Addresses + deploy tx hashes: `deployments/base-sepolia.json`.
- Python client: `services/ledger/client.py` — `LedgerClient` interface with `EvmLedgerClient` (implemented) and
  `FiscoLedgerClient` (stub that raises `NotImplementedError`).
- Check: `python -m services.ledger.client ping`.
