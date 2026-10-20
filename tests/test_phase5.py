import importlib
from datetime import date

import pytest
from fastapi.testclient import TestClient

from engine import bilno
from engine.alternatives import early_payment_apr
from engine.stress import simulate
from services.buyer import data as buyer_data
from services.buyer import policy as buyer_policy
from services.common.ratelimit import EvaluationBudget, EvaluationLimitExceeded
from services.supplier import data as supplier_data
from services.supplier.policy import SupplierPolicy

AS_OF = date(2026, 10, 20)
INVOICE = "ALF-2026-0142"


@pytest.fixture
def alpha(tmp_path):
    return supplier_data.connect(tmp_path / "alpha.db", as_of=AS_OF)


@pytest.fixture
def beta(tmp_path):
    return buyer_data.connect(tmp_path / "beta.db", as_of=AS_OF)


def _decide(alpha, beta, allow_partial=True, record=None):
    sp = SupplierPolicy(alpha, INVOICE)

    def buyer_eval(x, d):
        if record is not None:
            record.append(x)
        return buyer_policy.evaluate(beta, INVOICE, x, d)

    return sp, bilno.decide(sp.summary(), sp.evaluate, buyer_eval, allow_partial)


def test_sanity_example_numbers():
    x, d, days, r_opp = 60_000, 0.02, 60, 0.09
    assert x * (1 - d) == pytest.approx(58_800)
    early_cash_cost = x * (1 - d) * r_opp * days / 365
    assert early_cash_cost == pytest.approx(870, abs=1)
    assert x * d == pytest.approx(1_200)
    assert buyer_policy.buyer_gain(x, d, r_opp, days) == pytest.approx(330, abs=1)
    assert early_payment_apr(d, days) == pytest.approx(0.1241, abs=1e-4)


def test_seed_scenario_feasible_deal_good_for_both(alpha, beta):
    sp, r = _decide(alpha, beta)
    assert r.status == bilno.AGREEMENT
    assert r.supplier_gain_bucket > 0 and r.buyer_gain_bucket > 0
    assert sp.gain(r.x, r.d) > 0
    # Buyer's reserve is not breached beyond its own risk limit after paying early
    c = buyer_data.company(beta)
    after = buyer_data.load_profile(beta).with_flow(0, -r.pay_amount).with_outflow_amount(60, 100_000, 100_000 - r.x)
    assert simulate(after).p_breach <= c["alpha"]
    # Supplier crisis fixed
    supplier_after = sp.profile.with_flow(0, r.pay_amount).with_receivable_amount(INVOICE, 100_000 - r.x)
    assert simulate(supplier_after).p_breach <= sp.alpha
    assert r.d <= 0.03  # supplier's private d_max


def test_no_deal_when_buyer_reserve_too_high(alpha, beta):
    beta.execute("UPDATE company SET reserve = 440000")
    _, r = _decide(alpha, beta)
    assert r.status == bilno.NO_FEASIBLE_AGREEMENT
    assert r.recommendation == "bank_loan"


def test_no_action_needed_when_cash_is_high(alpha, beta):
    alpha.execute("UPDATE company SET cash = 200000")
    _, r = _decide(alpha, beta)
    assert r.status == bilno.NO_ACTION_NEEDED
    assert r.recommendation == "do_nothing"
    assert r.supplier_evaluations == 0


def test_full_amount_only_when_partial_not_allowed(alpha, beta):
    seen: list[float] = []
    _, r = _decide(alpha, beta, allow_partial=False, record=seen)
    assert seen and set(seen) == {100_000}
    if r.status == bilno.AGREEMENT:
        assert r.x == 100_000


def test_optimizer_stays_within_evaluation_budget(alpha, beta):
    _, r = _decide(alpha, beta)
    assert r.supplier_evaluations <= 200 and r.buyer_evaluations <= 200


def test_evaluation_limit_enforced():
    budget = EvaluationBudget(max_calls=200)
    for _ in range(200):
        budget.charge("neg-1")
    with pytest.raises(EvaluationLimitExceeded):
        budget.charge("neg-1")
    assert budget.charge("neg-2") == 1  # separate negotiation, separate budget


def test_evaluation_limit_enforced_over_http(tmp_path, monkeypatch):
    monkeypatch.setenv("BUYER_DB", str(tmp_path / "b.db"))
    monkeypatch.setenv("SUPPLIER_DB", str(tmp_path / "s.db"))
    from services.buyer import app as buyer_app
    from services.supplier import app as supplier_app

    for module in (buyer_app, supplier_app):
        mod = importlib.reload(module)
        mod.budget.max_calls = 3
        client = TestClient(mod.app)
        body = {"negotiation_id": "probe", "invoice_number": INVOICE, "x": 60_000, "d": 0.02}
        assert [client.post("/evaluate", json=body).status_code for _ in range(4)] == [200, 200, 200, 429]


def test_evaluate_reveals_no_private_numbers(alpha, beta):
    sp = SupplierPolicy(alpha, INVOICE)
    assert set(sp.evaluate(60_000, 0.02)) == {"feasible", "gain_bucket"}
    assert set(sp.summary()) == {"invoice_number", "face", "days_to_due", "no_action_needed", "best_alternative"}
    assert set(buyer_policy.evaluate(beta, INVOICE, 60_000, 0.02)) == {"feasible", "gain_bucket"}


def test_supplier_rejects_discount_above_private_limit(alpha):
    sp = SupplierPolicy(alpha, INVOICE)
    assert not sp.evaluate(60_000, 0.031)["feasible"]  # d_max_S = 3%
    assert not sp.evaluate(5_000, 0.02)["feasible"]  # below min net amount
