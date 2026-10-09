from datetime import datetime, timezone
from unittest.mock import MagicMock

import psycopg
import pytest
from redis.exceptions import ConnectionError as RedisConnectionError

from app import close_app, create_app
from app.storage import (
    PostgresVisitStore,
    RedisVisitCache,
    Resources,
    cache_key,
    database_errors,
)
from app.visits import StorageUnavailable, Visit, VisitService

VISIT = Visit(1, "2026-01-01T00:00:00+00:00")
CONFIG = {
    "TESTING": True, "DATABASE_URL": "", "REDIS_URL": "", "CACHE_TTL_SECONDS": 60,
}


@pytest.fixture()
def components():
    store = MagicMock()
    cache = MagicMock()
    store.create.return_value = VISIT
    store.get.return_value = VISIT
    store.ready.return_value = True
    cache.get.return_value = None
    service = VisitService(store, cache)
    application = create_app(CONFIG, service=service)
    return application.test_client(), service, store, cache


def test_post_commits_before_cache_and_returns_location(components):
    client, _, store, cache = components
    order = MagicMock()
    order.attach_mock(store, "store")
    order.attach_mock(cache, "cache")
    response = client.post("/visits")
    assert response.status_code == 201
    assert response.headers["Location"] == "/visits/1"
    assert response.get_json() == {**VISIT.as_dict(), "source": "db"}
    assert [call[0] for call in order.mock_calls] == ["store.create", "cache.put"]


def test_get_cold_cache_uses_database(components):
    client, _, store, cache = components
    response = client.get("/visits/1")
    assert response.status_code == 200
    assert response.get_json()["source"] == "db"
    store.get.assert_called_once_with(1)
    cache.put.assert_called_once_with(VISIT)


def test_get_warm_cache_does_not_call_database(components):
    client, _, store, cache = components
    cache.get.return_value = VISIT
    assert client.get("/visits/1").get_json()["source"] == "cache"
    store.get.assert_not_called()


def test_missing_visit_is_not_cached(components):
    client, _, store, cache = components
    store.get.return_value = None
    assert client.get("/visits/999").status_code == 404
    cache.put.assert_not_called()


@pytest.mark.parametrize("identifier", ["0", "9223372036854775808", "abc", "-1"])
def test_invalid_id_never_reaches_storage(components, identifier):
    client, _, store, cache = components
    assert client.get(f"/visits/{identifier}").status_code == 404
    store.get.assert_not_called()
    cache.get.assert_not_called()


def test_storage_failure_does_not_cache_or_leak_details(components):
    client, _, store, cache = components
    store.create.side_effect = StorageUnavailable("secret database details")
    response = client.post("/visits")
    assert response.status_code == 503
    assert response.get_json() == {"error": "storage_unavailable"}
    assert response.headers["Retry-After"] == "3"
    cache.put.assert_not_called()


def test_ready_requires_database_but_health_does_not(components):
    client, _, store, _ = components
    assert client.get("/ready").status_code == 200
    store.ready.return_value = False
    assert client.get("/ready").status_code == 503
    assert client.get("/health").get_json() == {"status": "ok"}
    store.ready.side_effect = StorageUnavailable()
    assert client.get("/ready").status_code == 503
    assert client.get("/health").status_code == 200


def test_unconfigured_storage_keeps_health_but_fails_ready_and_business_routes():
    application = create_app(CONFIG)
    client = application.test_client()
    assert client.get("/health").status_code == 200
    assert client.get("/ready").status_code == 503
    assert client.post("/visits").status_code == 503
    assert client.get("/visits/1").status_code == 503
    result = application.test_cli_runner().invoke(args=["init-db"])
    assert result.exit_code != 0
    close_app(application)


@pytest.mark.parametrize("overrides", [
    {"DATABASE_URL": "postgresql://example"},
    {"REDIS_URL": "redis://example"},
    {"CACHE_TTL_SECONDS": 0},
    {"CACHE_TTL_SECONDS": 3601},
    {"CACHE_TTL_SECONDS": "not-an-integer"},
])
def test_bad_configuration_is_rejected(overrides):
    with pytest.raises(ValueError):
        create_app({**CONFIG, **overrides})


def test_factory_initializes_closes_resources_and_exposes_schema_command(monkeypatch):
    resources = MagicMock()
    construct = MagicMock(return_value=resources)
    monkeypatch.setattr(Resources, "create", construct)
    application = create_app({
        **CONFIG, "DATABASE_URL": "postgresql://example", "REDIS_URL": "redis://example"
    })
    result = application.test_cli_runner().invoke(args=["init-db"])
    assert result.exit_code == 0
    resources.init_schema.assert_called_once_with()
    construct.assert_called_once_with("postgresql://example", "redis://example")
    close_app(application)
    close_app(application)
    resources.close.assert_called_once_with()


@pytest.mark.parametrize("raw", [
    "not-json", "[]", "null", "{}",
    '{"id":2,"created_at":"2026-01-01T00:00:00+00:00"}',
    '{"id":true,"created_at":"2026-01-01T00:00:00+00:00"}',
    '{"id":1,"created_at":"2026-01-01T00:00:00"}',
    '{"id":1,"created_at":null}',
])
def test_corrupted_cache_is_treated_as_a_miss(raw):
    client = MagicMock()
    client.get.return_value = raw
    assert RedisVisitCache(client).get(1) is None


def test_cache_serialization_ttl_and_miss():
    client = MagicMock()
    cache = RedisVisitCache(client, ttl=60)
    cache.put(VISIT)
    args, kwargs = client.set.call_args
    assert args[0] == cache_key(1)
    assert kwargs == {"ex": 60}
    client.get.return_value = args[1]
    assert cache.get(1) == VISIT
    client.get.return_value = None
    assert cache.get(1) is None


def test_redis_failure_does_not_escape_adapter():
    client = MagicMock()
    client.get.side_effect = RedisConnectionError("offline")
    client.set.side_effect = RedisConnectionError("offline")
    cache = RedisVisitCache(client)
    assert cache.get(1) is None
    cache.put(VISIT)


def test_repository_maps_row_and_queries_by_parameter():
    pool = MagicMock()
    connection = pool.connection.return_value.__enter__.return_value
    timestamp = datetime(2026, 1, 1, tzinfo=timezone.utc)
    connection.execute.return_value.fetchone.return_value = (1, timestamp)
    store = PostgresVisitStore(pool)
    assert store.create() == VISIT
    assert store.get(1) == VISIT
    assert connection.execute.call_args.args[1] == (1,)
    connection.execute.return_value.fetchone.return_value = None
    assert store.get(999) is None
    connection.execute.return_value.fetchone.return_value = (False,)
    assert not store.ready()
    connection.execute.return_value.fetchone.return_value = (True,)
    assert store.ready()


def test_failed_commit_never_reaches_cache():
    pool = MagicMock()
    context = pool.connection.return_value
    context.__enter__.return_value.execute.return_value.fetchone.return_value = (
        1, datetime(2026, 1, 1, tzinfo=timezone.utc)
    )
    context.__exit__.side_effect = psycopg.OperationalError("commit failed")
    cache = MagicMock()
    service = VisitService(PostgresVisitStore(pool), cache)
    with pytest.raises(StorageUnavailable):
        service.create()
    cache.put.assert_not_called()


def test_programming_errors_are_not_mislabeled_as_temporary_failures():
    with pytest.raises(psycopg.ProgrammingError):
        with database_errors():
            raise psycopg.ProgrammingError("invalid SQL")


def test_resources_use_bounded_pools_and_close_them(monkeypatch):
    pool = MagicMock()
    client = MagicMock()
    pool_constructor = MagicMock(return_value=pool)
    monkeypatch.setattr("app.storage.ConnectionPool", pool_constructor)
    monkeypatch.setattr("app.storage.Redis.from_url", MagicMock(return_value=client))
    resources = Resources.create("postgresql://example", "redis://example")
    assert pool_constructor.call_args.kwargs["max_size"] == 4
    assert pool_constructor.call_args.kwargs["max_waiting"] == 16
    assert pool_constructor.call_args.kwargs["open"] is False
    pool.open.assert_called_once_with()
    resources.init_schema()
    connection = pool.connection.return_value.__enter__.return_value
    statements = connection.execute.call_args_list
    assert "pg_advisory_xact_lock" in statements[0].args[0]
    assert "CREATE TABLE IF NOT EXISTS visits" in statements[1].args[0]
    resources.close()
    pool.close.assert_called_once_with()
    client.close.assert_called_once_with()
    client.connection_pool.disconnect.assert_called_once_with()
