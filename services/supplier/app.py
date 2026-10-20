"""Alpha Foods workspace API. Serves only Alpha Foods' own data."""

import os
from pathlib import Path

from fastapi import FastAPI, HTTPException

from engine.stress import SCENARIOS, compare, simulate
from pydantic import BaseModel, Field

from services.common.ratelimit import EvaluationBudget, EvaluationLimitExceeded
from services.supplier import data
from services.supplier.policy import SupplierPolicy

app = FastAPI(title="Alpha Foods workspace")
conn = data.connect(Path(os.environ.get("SUPPLIER_DB", data.DB_PATH)))
budget = EvaluationBudget()
_policies: dict[str, SupplierPolicy] = {}


def _policy(invoice_number: str) -> SupplierPolicy:
    if invoice_number not in _policies:
        try:
            _policies[invoice_number] = SupplierPolicy(conn, invoice_number)
        except ValueError as e:
            raise HTTPException(404, str(e)) from e
    return _policies[invoice_number]


class EvaluateRequest(BaseModel):
    negotiation_id: str
    invoice_number: str
    x: float = Field(gt=0)
    d: float = Field(gt=0, lt=1)


@app.get("/company")
def company():
    c = data.company(conn)
    return {k: c[k] for k in ("name", "as_of", "cash", "reserve")}


@app.get("/obligations")
def obligations():
    return data.obligations(conn)


@app.get("/receivables")
def receivables():
    return data.receivables(conn)


@app.get("/eligible-invoices")
def eligible_invoices():
    return data.eligible_invoices(conn)


@app.get("/forecast")
def forecast(scenario: str = "normal", bands: bool = False):
    if scenario not in SCENARIOS:
        raise HTTPException(400, f"scenario must be one of {list(SCENARIOS)}")
    r = simulate(data.load_profile(conn), scenario)
    out = r.summary()
    if bands:
        out |= {"p5": r.p5, "p50": r.p50, "p95": r.p95}
    return out


@app.get("/forecast/what-if")
def what_if(inflow_today: float, scenario: str = "normal"):
    """Before / After view for a hypothetical inflow today (e.g. an early payment)."""
    profile = data.load_profile(conn)
    return compare(simulate(profile, scenario), simulate(profile.with_flow(0, inflow_today), scenario))


@app.get("/negotiation-summary/{invoice_number}")
def negotiation_summary(invoice_number: str):
    """What the supplier shares to open a negotiation: no limits, no BATNA cost."""
    return _policy(invoice_number).summary()


@app.get("/alternatives/{invoice_number}")
def alternatives(invoice_number: str):
    """Supplier's own view (Strategy Agent / Supplier UI). Not sent to the buyer."""
    p = _policy(invoice_number)
    return {"needed": p.needed, "days": p.days, "alternatives": [a.as_dict() for a in p.alternatives]}


@app.post("/evaluate")
def evaluate(req: EvaluateRequest):
    try:
        budget.charge(req.negotiation_id)
    except EvaluationLimitExceeded as e:
        raise HTTPException(429, str(e)) from e
    return _policy(req.invoice_number).evaluate(req.x, req.d)
