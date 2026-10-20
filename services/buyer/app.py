"""Beta Markets workspace API. Raw financials are private: the public surface is /evaluate."""

import os
from pathlib import Path

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

from engine.stress import simulate
from services.buyer import data, policy
from services.common.ratelimit import EvaluationBudget, EvaluationLimitExceeded

app = FastAPI(title="Beta Markets workspace")
conn = data.connect(Path(os.environ.get("BUYER_DB", data.DB_PATH)))
budget = EvaluationBudget()


class EvaluateRequest(BaseModel):
    negotiation_id: str
    invoice_number: str
    x: float = Field(gt=0)
    d: float = Field(gt=0, lt=1)


@app.post("/evaluate")
def evaluate(req: EvaluateRequest):
    try:
        budget.charge(req.negotiation_id)
    except EvaluationLimitExceeded as e:
        raise HTTPException(429, str(e)) from e
    return policy.evaluate(conn, req.invoice_number, req.x, req.d)


@app.get("/internal/forecast")
def forecast(scenario: str = "normal"):
    """Buyer's own view (Buyer role in the UI). Not exposed to the coordinator."""
    return simulate(data.load_profile(conn), scenario).summary()
