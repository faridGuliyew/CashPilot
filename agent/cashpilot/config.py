"""Runtime configuration loaded from environment variables / .env."""

from pathlib import Path
from typing import Literal

from pydantic_settings import BaseSettings, SettingsConfigDict

REPO_ROOT = Path(__file__).resolve().parents[2]


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=REPO_ROOT / ".env", extra="ignore")

    rpc_url: str = "https://sepolia.base.org"
    chain_id: int = 84532

    admin_private_key: str = ""
    agent_private_key: str = ""
    owner_private_key: str = ""
    buyer_a_private_key: str = ""
    buyer_b_private_key: str = ""
    lp_private_key: str = ""

    anthropic_api_key: str = ""
    llm_model: str = ""
    llm_mode: Literal["offline", "online"] = "offline"


def get_settings() -> Settings:
    return Settings()
