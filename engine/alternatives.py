"""Costing of the supplier's ways to cover a liquidity gap (deterministic code, no LLM).

For the needed amount N over D days:
- Bank loan:       cost = N * r_bank * D/365 + fee; infeasible if it arrives after the first critical day.
- Early payment:   at discount d for D days, APR_approx = d/(1-d) * 365/D.
- Date shift:      cost = configured fee; only for outflows the counterparty allows to move.
- Do nothing:      feasible only if p_breach <= alpha.
Each feasibility check re-runs the stress test with the action applied.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass

from engine.stress import LiquidityProfile, simulate


@dataclass(frozen=True)
class BankTerms:
    rate: float  # annual
    arrival_days: int
    fee: float


@dataclass(frozen=True)
class ShiftOption:
    label: str
    day: int
    amount: float
    shift_days: int
    fee: float


@dataclass
class Alternative:
    name: str
    amount: float
    cost: float
    apr: float | None
    arrival_day: int
    p_breach_after: float
    feasible: bool
    reason: str

    def as_dict(self) -> dict:
        return asdict(self)


def early_payment_apr(d: float, days: int) -> float:
    return d / (1 - d) * 365 / days


def bank_loan_cost(amount: float, bank: BankTerms, days: int) -> float:
    return amount * bank.rate * days / 365 + bank.fee if amount > 0 else 0.0


def do_nothing(profile: LiquidityProfile, alpha: float) -> Alternative:
    p = simulate(profile).p_breach
    ok = p <= alpha
    return Alternative("do_nothing", 0, 0, None, 0, p, ok, "risk within limit" if ok else f"p_breach {p:.1%} > {alpha:.0%}")


def bank_loan(profile: LiquidityProfile, alpha: float, needed: float, days: int, bank: BankTerms) -> Alternative:
    critical = simulate(profile).first_critical_day
    p = simulate(profile.with_flow(bank.arrival_days, needed)).p_breach
    cost = bank_loan_cost(needed, bank, days)
    apr = cost / needed * 365 / days if needed else None
    if critical is not None and bank.arrival_days >= critical:
        return Alternative("bank_loan", needed, cost, apr, bank.arrival_days, p, False,
                           f"arrives day {bank.arrival_days}, crisis on day {critical}")
    ok = p <= alpha
    return Alternative("bank_loan", needed, cost, apr, bank.arrival_days, p, ok,
                       "arrives before the crisis" if ok else f"p_breach {p:.1%} > {alpha:.0%}")


def date_shift(profile: LiquidityProfile, alpha: float, shifts: list[ShiftOption], days: int) -> Alternative:
    if not shifts:
        return Alternative("date_shift", 0, 0, None, 0, 1.0, False, "no counterparty allows a date shift")
    shifted = profile
    for s in shifts:
        shifted = shifted.with_flow(s.day, s.amount).with_flow(s.day + s.shift_days, -s.amount)
    p = simulate(shifted).p_breach
    amount, cost = sum(s.amount for s in shifts), sum(s.fee for s in shifts)
    ok = p <= alpha
    labels = ", ".join(s.label for s in shifts)
    return Alternative("date_shift", amount, cost, cost / amount * 365 / days, 0, p, ok,
                       f"shift {labels}" + ("" if ok else f"; still p_breach {p:.1%} > {alpha:.0%}"))


def early_payment(
    profile: LiquidityProfile, alpha: float, invoice_label: str, face: float, x: float, d: float, days: int
) -> Alternative:
    after = profile.with_flow(0, x * (1 - d)).with_receivable_amount(invoice_label, face - x)
    p = simulate(after).p_breach
    ok = p <= alpha
    return Alternative(f"early_payment {x:,.0f} @ {d:.1%}", x * (1 - d), x * d, early_payment_apr(d, days), 0, p, ok,
                       "covers the gap" if ok else f"p_breach {p:.1%} > {alpha:.0%}")


def price_alternatives(
    profile: LiquidityProfile, alpha: float, needed: float, days: int, bank: BankTerms, shifts: list[ShiftOption]
) -> list[Alternative]:
    """Alternatives that do not need the buyer's agreement (used as the supplier's BATNA)."""
    return [do_nothing(profile, alpha), bank_loan(profile, alpha, needed, days, bank), date_shift(profile, alpha, shifts, days)]


def best_alternative(alternatives: list[Alternative]) -> Alternative | None:
    feasible = [a for a in alternatives if a.feasible]
    return min(feasible, key=lambda a: (a.cost, a.arrival_day)) if feasible else None
