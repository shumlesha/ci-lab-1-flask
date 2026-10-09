from dataclasses import dataclass
from typing import Protocol


class StorageUnavailable(RuntimeError):
    """A transient storage failure; no connection details reach the client."""


@dataclass(frozen=True, slots=True)
class Visit:
    id: int
    created_at: str

    def as_dict(self) -> dict[str, int | str]:
        return {"id": self.id, "created_at": self.created_at}


class VisitStore(Protocol):
    def create(self) -> Visit: ...

    def get(self, visit_id: int) -> Visit | None: ...

    def ready(self) -> bool: ...


class VisitCache(Protocol):
    def get(self, visit_id: int) -> Visit | None: ...

    def put(self, visit: Visit) -> None: ...


@dataclass(slots=True)
class VisitService:
    store: VisitStore
    cache: VisitCache

    def create(self) -> Visit:
        visit = self.store.create()
        self.cache.put(visit)
        return visit

    def get(self, visit_id: int) -> tuple[Visit | None, str]:
        cached = self.cache.get(visit_id)
        if cached is not None:
            return cached, "cache"

        visit = self.store.get(visit_id)
        if visit is not None:
            self.cache.put(visit)

        return visit, "db"
