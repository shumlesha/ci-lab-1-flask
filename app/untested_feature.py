

def classify_score(score: int) -> str:
    if score < 0:
        raise ValueError("score must be non-negative")
    if score < 50:
        return "low"
    if score < 80:
        return "medium"
    return "high"
