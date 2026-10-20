import ast
from datetime import date
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from engine.stress import compare, simulate
from services.buyer import data as buyer_data
from services.buyer import policy
from services.supplier import data as supplier_data

ROOT = Path(__file__).resolve().parents[1]
AS_OF = date(2026, 10, 20)


@pytest.fixture
def alpha(tmp_path):
    return supplier_data.connect(tmp_path / "alpha.db", as_of=AS_OF)


@pytest.fixture
def beta(tmp_path):
    return buyer_data.connect(tmp_path / "beta.db", as_of=AS_OF)


def test_seed_crisis_on_payroll_day(alpha):
    r = simulate(supplier_data.load_profile(alpha), "normal")
    assert r.first_critical_day == 10  # payroll in 10 days
    assert r.first_critical_date == "2026-10-30"
    assert r.p_breach > 0.5


def test_early_payment_inflow_fixes_crisis(alpha):
    profile = supplier_data.load_profile(alpha)
    before, after = simulate(profile, "normal"), simulate(profile.with_flow(0, 58_800), "normal")
    assert after.p_breach <= 0.05
    view = compare(before, after)
    assert view["p_breach_change"] < -0.9 and view["first_critical_day_after"] is None


def test_stress_scenarios_are_ordered(alpha):
    profile = supplier_data.load_profile(alpha).with_flow(0, 58_800)
    p = {s: simulate(profile, s).p_breach for s in ("normal", "late_payments", "stress")}
    assert p["normal"] <= p["late_payments"] <= p["stress"]


def test_disputed_and_unconfirmed_never_eligible(alpha):
    by_customer = {r["customer"]: r for r in supplier_data.receivables(alpha)}
    assert not by_customer["Delta Hotel"]["eligible"]
    assert "invoice is disputed" in by_customer["Delta Hotel"]["reasons"]
    assert not by_customer["Epsilon Trade"]["eligible"]  # forged: no buyer confirmation
    eligible = {r["customer"] for r in supplier_data.eligible_invoices(alpha)}
    assert eligible == {"Beta Markets", "Gamma Cafe"}
    labels = {r.label for r in supplier_data.load_profile(alpha).receivables}
    assert "ALF-2026-0133" not in labels and "ALF-2026-0160" not in labels


def test_settled_invoice_not_eligible(alpha):
    alpha.execute("UPDATE receivables SET status='settled' WHERE customer='Gamma Cafe'")
    assert {r["customer"] for r in supplier_data.eligible_invoices(alpha)} == {"Beta Markets"}


def test_reproducible_with_fixed_seed(alpha):
    profile = supplier_data.load_profile(alpha)
    a, b = simulate(profile, "stress", seed=7), simulate(profile, "stress", seed=7)
    assert a.p_breach == b.p_breach and a.p50 == b.p50
    assert simulate(profile, "stress", seed=8).p5 != a.p5


def test_buyer_evaluate_reveals_only_feasibility_and_bucket(beta):
    out = policy.evaluate(beta, "ALF-2026-0142", 60_000, 0.02)
    assert set(out) == {"feasible", "gain_bucket"}
    assert out == {"feasible": True, "gain_bucket": 3}  # gain ~330 TL (plan sanity example)


def test_buyer_evaluate_rejects_over_limit_and_unprofitable(beta):
    assert not policy.evaluate(beta, "ALF-2026-0142", 100_000, 0.001)["feasible"]  # gain < 0
    beta.execute("UPDATE company SET max_early_cash = 50000")
    assert not policy.evaluate(beta, "ALF-2026-0142", 60_000, 0.02)["feasible"]  # 58,800 > 50,000
    assert not policy.evaluate(beta, "UNKNOWN", 60_000, 0.02)["feasible"]


def test_buyer_evaluate_respects_reserve(beta):
    beta.execute("UPDATE company SET reserve = 440000")
    assert policy.evaluate(beta, "ALF-2026-0142", 60_000, 0.02) == {"feasible": False, "gain_bucket": 0}


def test_workspace_apis(tmp_path, monkeypatch):
    monkeypatch.setenv("SUPPLIER_DB", str(tmp_path / "s.db"))
    monkeypatch.setenv("BUYER_DB", str(tmp_path / "b.db"))
    import importlib

    from services.buyer import app as buyer_app
    from services.supplier import app as supplier_app

    s = TestClient(importlib.reload(supplier_app).app)
    assert s.get("/forecast").json()["p_breach"] > 0.5
    assert len(s.get("/eligible-invoices").json()) == 2
    assert s.get("/forecast/what-if", params={"inflow_today": 58_800}).json()["p_breach_after"] <= 0.05
    assert s.get("/forecast", params={"scenario": "bogus"}).status_code == 400

    b = TestClient(importlib.reload(buyer_app).app)
    r = b.post("/evaluate", json={"negotiation_id": "n1", "invoice_number": "ALF-2026-0142", "x": 60_000, "d": 0.02}).json()
    assert r["feasible"] is True


def _imports(package: str) -> set[str]:
    names = set()
    for path in (ROOT / "services" / package).rglob("*.py"):
        for node in ast.walk(ast.parse(path.read_text())):
            if isinstance(node, ast.Import):
                names |= {a.name for a in node.names}
            elif isinstance(node, ast.ImportFrom) and node.module:
                names.add(node.module)
                names |= {f"{node.module}.{a.name}" for a in node.names}
    return names


def _text(package: str) -> str:
    return "\n".join(p.read_text() for p in (ROOT / "services" / package).rglob("*.py"))


def test_isolation_supplier_never_imports_buyer_and_vice_versa():
    assert not any(n.startswith("services.buyer") for n in _imports("supplier"))
    assert not any(n.startswith("services.supplier") for n in _imports("buyer"))
    assert "beta_markets.db" not in _text("supplier")
    assert "alpha_foods.db" not in _text("buyer")
