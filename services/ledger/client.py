"""Ledger client: one interface, two backends selected by LEDGER_TARGET.

- evm: Base Sepolia (implemented).
- fisco: FISCO BCOS 3.x (interface only; not implemented, see docs/LEDGER.md).

CLI: python -m services.ledger.client ping
"""

from __future__ import annotations

import json
import sys
from abc import ABC, abstractmethod
from pathlib import Path

from services.common.config import REPO_ROOT, Settings, get_settings

ABI_DIR = Path(__file__).parent / "abi"
EVM_NETWORKS = {84532: "base-sepolia", 31337: "anvil"}


class LedgerClient(ABC):
    """Operations the coordinator needs from the ledger. Write methods are added in Phase 7."""

    target: str

    @abstractmethod
    def addresses(self) -> dict[str, str]: ...

    @abstractmethod
    def block_number(self) -> int: ...

    @abstractmethod
    def explorer_tx_url(self, tx_hash: str) -> str | None: ...


class EvmLedgerClient(LedgerClient):
    target = "evm"

    def __init__(self, settings: Settings):
        from web3 import Web3

        self.settings = settings
        self.network = EVM_NETWORKS.get(settings.chain_id, f"chain-{settings.chain_id}")
        deployment_file = REPO_ROOT / "deployments" / f"{self.network}.json"
        if not deployment_file.exists():
            raise FileNotFoundError(f"{deployment_file} not found; run `make deploy` first")
        self.deployment = json.loads(deployment_file.read_text())
        self.w3 = Web3(Web3.HTTPProvider(settings.rpc_url))
        if self.w3.eth.chain_id != settings.chain_id:
            raise RuntimeError(f"RPC chain id {self.w3.eth.chain_id} != CHAIN_ID {settings.chain_id}")
        self.registry = self._contract("InvoiceRegistry")
        self.ledger = self._contract("AgreementLedger")

    def _contract(self, name: str):
        abi = json.loads((ABI_DIR / f"{name}.json").read_text())
        address = self.w3.to_checksum_address(self.deployment["contracts"][name]["address"])
        return self.w3.eth.contract(address=address, abi=abi)

    def addresses(self) -> dict[str, str]:
        return {name: c["address"] for name, c in self.deployment["contracts"].items()}

    def block_number(self) -> int:
        return self.w3.eth.block_number

    def explorer_tx_url(self, tx_hash: str) -> str | None:
        if self.settings.chain_id == 84532:
            return f"https://sepolia.basescan.org/tx/{tx_hash}"
        return None


class FiscoLedgerClient(LedgerClient):
    """Placeholder for FISCO BCOS 3.x. Deliberately not implemented: we deploy to Base Sepolia."""

    target = "fisco"

    def __init__(self, settings: Settings):
        raise NotImplementedError("FISCO BCOS backend is not implemented; use LEDGER_TARGET=evm")

    def addresses(self) -> dict[str, str]:
        raise NotImplementedError

    def block_number(self) -> int:
        raise NotImplementedError

    def explorer_tx_url(self, tx_hash: str) -> str | None:
        raise NotImplementedError


def get_ledger_client(settings: Settings | None = None) -> LedgerClient:
    settings = settings or get_settings()
    backends = {"evm": EvmLedgerClient, "fisco": FiscoLedgerClient}
    return backends[settings.ledger_target](settings)


def main(argv: list[str]) -> int:
    if argv[:1] != ["ping"]:
        print("usage: python -m services.ledger.client ping")
        return 2
    client = get_ledger_client()
    registry = getattr(client, "registry", None)
    ledger = getattr(client, "ledger", None)
    print(f"target:   {client.target} ({getattr(client, 'network', '')})")
    for name, addr in client.addresses().items():
        print(f"{name}: {addr}")
    print(f"block:    {client.block_number()}")
    if registry is not None and ledger is not None:
        print(f"ledger.registry() -> {ledger.functions.registry().call()}")
        print(f"registry.nextInvoiceId() -> {registry.functions.nextInvoiceId().call()}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
