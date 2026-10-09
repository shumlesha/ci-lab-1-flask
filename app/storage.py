import json
import logging
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime
from importlib.resources import files
from typing import Iterator

import psycopg
from psycopg_pool import ConnectionPool, PoolClosed, PoolTimeout, TooManyRequests
from redis import Redis
from redis.backoff import NoBackoff
from redis.exceptions import RedisError
from redis.retry import Retry

from app.visits import StorageUnavailable, Visit

logger = logging.getLogger(__name__)

DB_UNAVAILABLE = (
    psycopg.OperationalError,
    psycopg.InterfaceError,
    PoolClosed,
    PoolTimeout,
    TooManyRequests,
)


@contextmanager
def database_errors() -> Iterator[None]:
    try:
        yield
    except DB_UNAVAILABLE as exc:
        logger.warning("PostgreSQL unavailable: %s", type(exc).__name__)
        raise StorageUnavailable("Storage temporarily unavailable") from exc


@dataclass(slots=True)
class PostgresVisitStore:
    pool: ConnectionPool

    def create(self) -> Visit:
        with database_errors(), self.pool.connection() as connection:
            row = connection.execute(
                "INSERT INTO visits DEFAULT VALUES RETURNING id, created_at"
            ).fetchone()
            visit = Visit(row[0], row[1].isoformat())

        return visit

    def get(self, visit_id: int) -> Visit | None:
        with database_errors(), self.pool.connection() as connection:
            row = connection.execute(
                "SELECT id, created_at FROM visits WHERE id = %s", (visit_id,)
            ).fetchone()

        return None if row is None else Visit(row[0], row[1].isoformat())

    def ready(self) -> bool:
        with database_errors(), self.pool.connection() as connection:
            row = connection.execute(
                "SELECT to_regclass('public.visits') IS NOT NULL"
            ).fetchone()

        return bool(row[0])


def cache_key(visit_id: int) -> str:
    return f"lab3:visits:v1:{visit_id}"


@dataclass(slots=True)
class RedisVisitCache:
    client: Redis
    ttl: int = 60

    def get(self, visit_id: int) -> Visit | None:
        try:
            raw = self.client.get(cache_key(visit_id))

            if raw is None:
                return None

            data = json.loads(raw)

            if not isinstance(data, dict) or set(data) != {"id", "created_at"}:
                raise ValueError("Invalid cache schema")

            if type(data["id"]) is not int or data["id"] != visit_id:
                raise ValueError("Invalid cached identity")

            timestamp = datetime.fromisoformat(data["created_at"])

            if timestamp.tzinfo is None:
                raise ValueError("Cached timestamp must include a timezone")

            return Visit(data["id"], data["created_at"])

        except (RedisError, ValueError, TypeError):
            logger.warning("Redis read failed or cached value was invalid; using DB")
            return None

    def put(self, visit: Visit) -> None:
        try:
            self.client.set(
                cache_key(visit.id),
                json.dumps(visit.as_dict(), separators=(",", ":")),
                ex=self.ttl,
            )
        except RedisError:
            logger.warning("Redis write failed; PostgreSQL commit remains valid")


@dataclass(slots=True)
class Resources:
    pool: ConnectionPool
    redis: Redis

    @classmethod
    def create(cls, database_url: str, redis_url: str) -> "Resources":
        client = Redis.from_url(
            redis_url,
            decode_responses=True,
            max_connections=8,
            socket_connect_timeout=0.5,
            socket_timeout=0.5,
            retry=Retry(NoBackoff(), 0),
        )

        pool = ConnectionPool(
            conninfo=database_url,
            min_size=0,
            max_size=4,
            timeout=3,
            max_waiting=16,
            kwargs={
                "connect_timeout": 3,
                "options": "-c statement_timeout=3000 -c lock_timeout=1000",
            },
            open=False,
        )

        pool.open()
        return cls(pool, client)

    def init_schema(self) -> None:
        sql = files("app").joinpath("schema.sql").read_text(encoding="utf-8")

        with self.pool.connection() as connection:
            connection.execute("SELECT pg_advisory_xact_lock(30031001)")
            connection.execute(sql)

    def close(self) -> None:
        try:
            self.pool.close()
        finally:
            self.redis.close()
            self.redis.connection_pool.disconnect()
