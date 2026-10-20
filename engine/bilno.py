"""BILNO: Bilateral Liquidity-Neutral Optimization.

Decision variables: x = face amount settled early (1,000 TL steps, x <= F; only x = F if partial
payment is not allowed) and d = discount (0.1% steps). The optimizer never sees either side's data:
it only calls each side's evaluate(x, d) -> {feasible, gain_bucket}, where gain_bucket is that side's
gain vs its own best alternative, rounded to 100 TL. It maximizes the Nash product of the two gains
over the points both sides call feasible, or returns NO_FEASIBLE_AGREEMENT.

Search: a coarse grid (10% of F x 0.5%), then two rounds of one-variable refinement around the best
point. This keeps calls well under the 200-evaluation budget each workspace enforces.

CLI: python -m engine.bilno --demo
"""

from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass, field
from typing import Callable

from engine.alternatives import early_payment_apr

Evaluator = Callable[[float, float], dict]

GAIN_BUCKET = 100.0
X_STEP = 1_000.0
D_STEP = 0.001
D_COARSE = 0.005
D_CAP = 0.05  # public search bound; each side's private d limit is enforced inside its evaluate()

AGREEMENT = "AGREEMENT"
NO_FEASIBLE_AGREEMENT = "NO_FEASIBLE_AGREEMENT"
NO_ACTION_NEEDED = "NO_ACTION_NEEDED"


@dataclass
class BilnoResult:
    status: str
    recommendation: str
    x: float | None = None
    d: float | None = None
    pay_amount: float | None = None
    supplier_gain_bucket: int | None = None
    buyer_gain_bucket: int | None = None
    nash_product: float | None = None
    apr: float | None = None
    supplier_evaluations: int = 0
    buyer_evaluations: int = 0
    feasible_points: int = 0
    trace: list[dict] = field(default_factory=list, repr=False)

    def as_dict(self, with_trace: bool = False) -> dict:
        d = asdict(self)
        if not with_trace:
            d.pop("trace")
        return d


class _Search:
    def __init__(self, supplier: Evaluator, buyer: Evaluator):
        self.supplier, self.buyer = supplier, buyer
        self.cache: dict[tuple[float, float], tuple[int, int] | None] = {}
        self.s_calls = self.b_calls = 0
        self.trace: list[dict] = []

    def joint(self, x: float, d: float) -> tuple[int, int] | None:
        key = (round(x, 2), round(d, 4))
        if key in self.cache:
            return self.cache[key]
        self.s_calls += 1
        s = self.supplier(x, d)
        out = None
        if s["feasible"]:
            self.b_calls += 1
            b = self.buyer(x, d)
            if b["feasible"]:
                out = (s["gain_bucket"], b["gain_bucket"])
        self.cache[key] = out
        self.trace.append({"x": x, "d": d, "supplier_ok": s["feasible"], "both_ok": out is not None})
        return out

    @staticmethod
    def score(point: tuple[float, float], gains: tuple[int, int]) -> tuple:
        s, b = gains
        # Nash product, then joint surplus, then the smaller discount and amount
        return (s * b, s + b, -point[1], -point[0])

    def best(self) -> tuple[tuple[float, float], tuple[int, int]] | None:
        ok = [(k, v) for k, v in self.cache.items() if v is not None and v[0] > 0 and v[1] > 0]
        return max(ok, key=lambda kv: self.score(*kv)) if ok else None


def _grid(lo: float, hi: float, step: float) -> list[float]:
    n = int(round((hi - lo) / step))
    return [round(lo + i * step, 6) for i in range(n + 1)]


def optimize(supplier: Evaluator, buyer: Evaluator, face: float, days: int, allow_partial: bool = True) -> BilnoResult:
    search = _Search(supplier, buyer)
    d_grid_fine = _grid(D_STEP, D_CAP, D_STEP)

    if allow_partial:
        x_coarse_step = max(X_STEP, round(face / 10 / X_STEP) * X_STEP)
        xs = sorted({*_grid(x_coarse_step, face - face % x_coarse_step, x_coarse_step), face})
        for x in xs:
            for d in _grid(D_COARSE, D_CAP, D_COARSE):
                search.joint(x, d)
        for _ in range(2):
            found = search.best()
            if not found:
                break
            (bx, bd), _ = found
            for x in _grid(max(X_STEP, bx - x_coarse_step), min(face, bx + x_coarse_step), X_STEP):
                search.joint(x, bd)
            (bx, bd), _ = search.best()
            for d in _grid(max(D_STEP, bd - D_COARSE), min(D_CAP, bd + D_COARSE), D_STEP):
                search.joint(bx, d)
    else:
        for d in d_grid_fine:
            search.joint(face, d)

    found = search.best()
    common = {
        "supplier_evaluations": search.s_calls,
        "buyer_evaluations": search.b_calls,
        "feasible_points": sum(v is not None for v in search.cache.values()),
        "trace": search.trace,
    }
    if not found:
        return BilnoResult(NO_FEASIBLE_AGREEMENT, "", **common)
    (x, d), (s, b) = found
    return BilnoResult(
        AGREEMENT,
        "early_payment",
        x=x,
        d=d,
        pay_amount=round(x * (1 - d), 2),
        supplier_gain_bucket=s,
        buyer_gain_bucket=b,
        nash_product=s * GAIN_BUCKET * b * GAIN_BUCKET,
        apr=early_payment_apr(d, days),
        **common,
    )


def decide(supplier_summary: dict, supplier: Evaluator, buyer: Evaluator, allow_partial: bool = True) -> BilnoResult:
    """Full decision: no action / BILNO deal / no deal + the supplier's best alternative."""
    if supplier_summary["no_action_needed"]:
        return BilnoResult(NO_ACTION_NEEDED, "do_nothing")
    result = optimize(supplier, buyer, supplier_summary["face"], supplier_summary["days_to_due"], allow_partial)
    if result.status == NO_FEASIBLE_AGREEMENT:
        result.recommendation = supplier_summary["best_alternative"] or "none_feasible"
    return result


def _demo() -> None:
    # Local demo: both workspaces in one process, each answering only through its own evaluate().
    from engine.alternatives import early_payment
    from services.buyer import data as buyer_data
    from services.buyer import policy as buyer_policy
    from services.common.config import get_settings
    from services.supplier import data as supplier_data
    from services.supplier.policy import SupplierPolicy

    invoice = "ALF-2026-0142"
    sp = SupplierPolicy(supplier_data.connect(), invoice)
    bconn = buyer_data.connect()
    summary = sp.summary()
    result = decide(summary, sp.evaluate, lambda x, d: buyer_policy.evaluate(bconn, invoice, x, d), get_settings().allow_partial)

    print(f"Invoice {invoice}: face {summary['face']:,.0f} TL, due in {summary['days_to_due']} days")
    print(f"Supplier needs {sp.needed:,.0f} TL (shortfall + reserve gap)\n")
    rows = list(sp.alternatives)
    if result.status == AGREEMENT:
        rows.append(early_payment(sp.profile, sp.alpha, invoice, summary["face"], result.x, result.d, sp.days))
    print(f"{'alternative':<28} {'amount':>9} {'cost':>8} {'APR':>7} {'arrives':>8} {'p_breach':>9}  feasible")
    for a in rows:
        apr = f"{a.apr:.2%}" if a.apr is not None else "-"
        print(f"{a.name:<28} {a.amount:>9,.0f} {a.cost:>8,.0f} {apr:>7} {'day ' + str(a.arrival_day):>8} "
              f"{a.p_breach_after:>9.1%}  {'yes' if a.feasible else 'no'} ({a.reason})")

    print(f"\nBILNO: {result.status} -> recommendation: {result.recommendation}")
    if result.status == AGREEMENT:
        print(f"  x = {result.x:,.0f} TL settled early at d = {result.d:.1%}; buyer pays {result.pay_amount:,.0f} TL now")
        print(f"  supplier gain ~ {result.supplier_gain_bucket * 100:,} TL, buyer gain ~ {result.buyer_gain_bucket * 100:,} TL"
              " (100 TL buckets)")
        print(f"  Nash product {result.nash_product:,.0f}; discount APR {result.apr:.2%}")
    print(f"  evaluations: supplier {result.supplier_evaluations}, buyer {result.buyer_evaluations} (limit 200 each)")


def main() -> None:
    parser = argparse.ArgumentParser(description="BILNO optimizer")
    parser.add_argument("--demo", action="store_true", help="run on the seeded Alpha Foods / Beta Markets data")
    if parser.parse_args().demo:
        _demo()
    else:
        parser.print_help()


if __name__ == "__main__":
    main()
