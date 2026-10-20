from services.common.config import get_settings


def test_settings_default_to_offline(monkeypatch):
    monkeypatch.delenv("LLM_MODE", raising=False)
    monkeypatch.delenv("LEDGER_TARGET", raising=False)
    settings = get_settings()
    assert settings.ledger_target in ("fisco", "evm")
    assert settings.allow_partial in (True, False)
