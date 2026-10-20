"""Writes deployments/<network>.json from the forge broadcast file and exports ABIs for Python.

Usage: python scripts/export_deployment.py <chain_id> <network_name>
"""

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONTRACTS = ["InvoiceRegistry", "AgreementLedger"]


def main(chain_id: str, network: str) -> None:
    broadcast = json.loads((ROOT / f"contracts/broadcast/Deploy.s.sol/{chain_id}/run-latest.json").read_text())
    receipts = {r["transactionHash"]: r for r in broadcast["receipts"]}
    contracts, setup_txs = {}, []
    for tx in broadcast["transactions"]:
        receipt = receipts.get(tx["hash"], {})
        entry = {"tx_hash": tx["hash"], "block": int(receipt.get("blockNumber", "0x0"), 16)}
        if tx["transactionType"] == "CREATE":
            contracts[tx["contractName"]] = {"address": tx["contractAddress"], **entry}
        else:
            setup_txs.append({"function": tx.get("function") or "transfer", "to": tx["transaction"]["to"], **entry})

    out = {"network": network, "chain_id": int(chain_id), "contracts": contracts, "setup_transactions": setup_txs}
    (ROOT / "deployments").mkdir(exist_ok=True)
    (ROOT / f"deployments/{network}.json").write_text(json.dumps(out, indent=2) + "\n")

    for name in CONTRACTS:
        artifact = json.loads((ROOT / f"contracts/out/{name}.sol/{name}.json").read_text())
        (ROOT / f"services/ledger/abi/{name}.json").write_text(json.dumps(artifact["abi"], indent=2) + "\n")
    print(json.dumps(contracts, indent=2))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
