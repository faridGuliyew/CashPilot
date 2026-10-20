from cashpilot.config import get_settings


def test_settings_load_with_offline_default(monkeypatch):
    monkeypatch.delenv("LLM_MODE", raising=False)
    settings = get_settings()
    assert settings.chain_id > 0
