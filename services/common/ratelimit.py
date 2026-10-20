"""Per-negotiation evaluation budget, enforced by the workspace that owns the private data."""

MAX_EVALUATIONS = 200


class EvaluationLimitExceeded(Exception):
    pass


class EvaluationBudget:
    def __init__(self, max_calls: int = MAX_EVALUATIONS):
        self.max_calls = max_calls
        self.calls: dict[str, int] = {}

    def charge(self, negotiation_id: str) -> int:
        used = self.calls.get(negotiation_id, 0)
        if used >= self.max_calls:
            raise EvaluationLimitExceeded(f"{negotiation_id}: limit of {self.max_calls} evaluations reached")
        self.calls[negotiation_id] = used + 1
        return used + 1
