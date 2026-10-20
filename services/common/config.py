"""Runtime configuration loaded from environment variables / .env."""

from pathlib import Path
from typing import Literal

from pydantic_settings import BaseSettings, SettingsConfigDict

REPO_ROOT = Path(__file__).resolve().parents[2]


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=REPO_ROOT / ".env", extra="ignore")

    # Ledger
    ledger_target: Literal["fisco", "evm"] = "evm"
    rpc_url: str = "https://sepolia.base.org"
    chain_id: int = 84532
    admin_private_key: str = ""
    coordinator_private_key: str = ""

    # Human approvers (demo keys held server-side; documented known risk)
    supplier_signer_key: str = ""
    buyer_signer_key: str = ""

    # Bank sandbox
    bank_webhook_secret: str = ""

    # LLM
    anthropic_api_key: str = ""
    llm_model: str = ""
    llm_mode: Literal["offline", "online"] = "offline"

    # Optimizer
    allow_partial: bool = True


def get_settings() -> Settings:
    return Settings()
