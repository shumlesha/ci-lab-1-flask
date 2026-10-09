"""Function-scoped real containers: isolated PostgreSQL and Redis."""

import json
import os
from contextlib import ExitStack, closing
from pathlib import Path
from uuid import uuid4

import docker
import pytest
from docker.errors import NotFound
from testcontainers.community.postgres import PostgresContainer
from testcontainers.community.redis import RedisContainer
from testcontainers.core.exceptions import ContainerStartException

from app import close_app, create_app


@pytest.fixture()
def environment(request):
    run_id = os.environ.get("LAB3_TEST_RUN_ID", uuid4().hex)
    worker = os.environ.get("PYTEST_XDIST_WORKER", "master")

    output = Path(
        os.environ.get(
            "LAB3_REPORT_DIR",
            "reports/integration/manual",
        )
    )
    output.mkdir(parents=True, exist_ok=True)

    labels = {
        "lab3.suite": "integration",
        "lab3.run": run_id,
    }

    def record(event, **data):
        path = output / f"lifecycle-{worker}.jsonl"

        with path.open("a", encoding="utf-8") as log:
            log.write(
                json.dumps({
                    "event": event,
                    "test": request.node.nodeid,
                    "run_id": run_id,
                    **data,
                }) + "\n"
            )

    def cleanup(container, role):
        try:
            identifier = container.get_wrapped_container().id
        except ContainerStartException:
            identifier = None

        try:
            if identifier is not None:
                try:
                    stdout, stderr = container.get_logs()

                    (output / f"{identifier}-{role}.log").write_bytes(
                        stdout + stderr
                    )
                except docker.errors.DockerException:
                    record(
                        "logs_unavailable",
                        role=role,
                        id=identifier,
                    )
        finally:
            container.stop()

        if identifier is not None:
            with closing(docker.from_env()) as client:
                try:
                    client.containers.get(identifier)
                except NotFound:
                    record(
                        "removed",
                        role=role,
                        id=identifier,
                    )
                else:
                    record(
                        "leaked",
                        role=role,
                        id=identifier,
                    )
                    raise AssertionError(
                        f"Container was not removed: {identifier}"
                    )

    with ExitStack() as stack:
        pg = PostgresContainer(
            os.environ.get("TEST_POSTGRES_IMAGE", "postgres:16"),
            username="test",
            password="test",
            dbname="testdb",
            driver=None,
        ).with_kwargs(
            labels=labels,
            mem_limit="256m",
        )

        stack.callback(cleanup, pg, "postgres")

        pg.start()

        record(
            "started",
            role="postgres",
            id=pg.get_wrapped_container().id,
        )

        redis_container = RedisContainer(
            os.environ.get("TEST_REDIS_IMAGE", "redis:7")
        ).with_kwargs(
            labels=labels,
            mem_limit="128m",
        )

        stack.callback(cleanup, redis_container, "redis")

        redis_container.start()

        record(
            "started",
            role="redis",
            id=redis_container.get_wrapped_container().id,
        )

        host = redis_container.get_container_host_ip()
        port = redis_container.get_exposed_port(6379)

        application = create_app({
            "TESTING": True,
            "DATABASE_URL": pg.get_connection_url(),
            "REDIS_URL": f"redis://{host}:{port}/0",
            "CACHE_TTL_SECONDS": 60,
        })

        stack.callback(close_app, application)

        resources = application.extensions["lab3_resources"]
        resources.init_schema()

        yield (
            application.test_client(),
            resources,
            pg,
            redis_container,
        )
