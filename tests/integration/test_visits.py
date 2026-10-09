from concurrent.futures import ThreadPoolExecutor

import psycopg

from app.storage import cache_key


def create_visit(client):
    response = client.post("/visits")

    assert response.status_code == 201

    return response.get_json()


def test_create_persists_in_postgres(environment):
    client, _, pg, _ = environment

    response = client.post("/visits")

    assert response.status_code == 201

    visit = response.get_json()

    assert visit["source"] == "db"
    assert response.headers["Location"] == f"/visits/{visit['id']}"

    with psycopg.connect(pg.get_connection_url()) as connection:
        row = connection.execute(
            "SELECT id, created_at FROM visits WHERE id = %s",
            (visit["id"],),
        ).fetchone()

    assert row[0] == visit["id"]
    assert row[1].isoformat() == visit["created_at"]


def test_repeat_read_uses_redis_without_another_insert(environment):
    client, resources, _, _ = environment

    visit = create_visit(client)

    response = client.get(f"/visits/{visit['id']}")

    assert response.status_code == 200
    assert response.get_json() == {**visit, "source": "cache"}

    assert resources.redis.exists(cache_key(visit["id"])) == 1

    with resources.pool.connection() as connection:
        count = connection.execute(
            "SELECT COUNT(*) FROM visits"
        ).fetchone()[0]

    assert count == 1


def test_cache_miss_reads_existing_record_and_refills_cache(environment):
    client, resources, _, _ = environment

    visit = create_visit(client)

    resources.redis.delete(cache_key(visit["id"]))

    response = client.get(f"/visits/{visit['id']}")
    assert response.get_json()["source"] == "db"

    response = client.get(f"/visits/{visit['id']}")
    assert response.get_json()["source"] == "cache"


def test_cache_has_bounded_ttl_and_expiry_is_safe(environment):
    client, resources, _, _ = environment

    visit = create_visit(client)
    key = cache_key(visit["id"])

    assert 0 < resources.redis.ttl(key) <= 60

    assert resources.redis.expire(key, 0)

    assert resources.redis.get(key) is None

    response = client.get(f"/visits/{visit['id']}")
    assert response.get_json()["source"] == "db"


def test_unknown_record_returns_404_without_negative_cache(environment):
    client, resources, _, _ = environment

    assert client.get("/visits/999999").status_code == 404
    assert resources.redis.dbsize() == 0


def test_invalid_cached_value_is_repaired_from_postgres(environment):
    client, resources, _, _ = environment

    visit = create_visit(client)

    resources.redis.set(
        cache_key(visit["id"]),
        "not-json",
        ex=60,
    )

    response = client.get(f"/visits/{visit['id']}")
    assert response.get_json()["source"] == "db"

    response = client.get(f"/visits/{visit['id']}")
    assert response.get_json()["source"] == "cache"


def test_redis_outage_does_not_lose_committed_writes(environment):
    client, _, pg, redis_container = environment

    redis_container.get_wrapped_container().stop(timeout=2)

    visit = create_visit(client)

    response = client.get(f"/visits/{visit['id']}")
    assert response.get_json()["source"] == "db"

    assert client.get("/ready").status_code == 200

    with psycopg.connect(pg.get_connection_url()) as connection:
        count = connection.execute(
            "SELECT COUNT(*) FROM visits"
        ).fetchone()[0]

    assert count == 1


def test_postgres_outage_reports_503_but_health_remains_live(environment):
    client, _, pg, _ = environment

    visit = create_visit(client)

    pg.get_wrapped_container().stop(timeout=2)

    cached = client.get(f"/visits/{visit['id']}")

    assert cached.status_code == 200
    assert cached.get_json()["source"] == "cache"

    response = client.post("/visits")

    assert response.status_code == 503
    assert response.get_json() == {"error": "storage_unavailable"}

    assert client.get("/ready").status_code == 503
    assert client.get("/health").status_code == 200


def test_parallel_requests_persist_distinct_visits(environment):
    client, resources, _, _ = environment

    application = client.application

    def create(_index):
        with application.test_client() as thread_client:
            return create_visit(thread_client)["id"]

    with ThreadPoolExecutor(max_workers=4) as executor:
        identifiers = list(executor.map(create, range(8)))

    assert len(set(identifiers)) == 8

    with resources.pool.connection() as connection:
        count = connection.execute(
            "SELECT COUNT(*) FROM visits"
        ).fetchone()[0]

    assert count == 8


def test_initial_schema_can_be_applied_again_without_losing_data(environment):
    client, resources, _, _ = environment

    visit = create_visit(client)

    resources.init_schema()

    resources.redis.delete(cache_key(visit["id"]))

    response = client.get(f"/visits/{visit['id']}")

    assert response.status_code == 200
