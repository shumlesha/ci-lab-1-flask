import atexit
import os
from collections.abc import Mapping
from typing import Any

import click
from flask import Flask, jsonify, url_for

from app.storage import PostgresVisitStore, RedisVisitCache, Resources
from app.visits import StorageUnavailable, VisitService


def close_app(application: Flask) -> None:
    """Close process-scoped resources, NOT once per HTTP request."""
    resources = application.extensions.pop("lab3_resources", None)

    if resources is not None:
        atexit.unregister(resources.close)
        resources.close()


def create_app(
    test_config: Mapping[str, Any] | None = None,
    *,
    service: VisitService | None = None,
) -> Flask:
    application = Flask(__name__)

    application.config.from_mapping(
        DATABASE_URL=os.environ.get("DATABASE_URL", ""),
        REDIS_URL=os.environ.get("REDIS_URL", ""),
        CACHE_TTL_SECONDS=os.environ.get("CACHE_TTL_SECONDS", "60"),
    )

    if test_config is not None:
        application.config.update(test_config)

    ttl = int(application.config["CACHE_TTL_SECONDS"])

    if not 1 <= ttl <= 3600:
        raise ValueError("CACHE_TTL_SECONDS must be between 1 and 3600")

    database_url = application.config["DATABASE_URL"]
    redis_url = application.config["REDIS_URL"]

    if bool(database_url) != bool(redis_url):
        raise ValueError("Set both DATABASE_URL and REDIS_URL, or neither")

    if service is None and database_url:
        resources = Resources.create(database_url, redis_url)

        application.extensions["lab3_resources"] = resources
        atexit.register(resources.close)

        service = VisitService(
            PostgresVisitStore(resources.pool),
            RedisVisitCache(resources.redis, ttl),
        )

    @application.get("/health")
    def health():
        return jsonify(status="ok"), 200

    @application.get("/ready")
    def ready():
        if service is None or not service.store.ready():
            return jsonify(status="not_ready"), 503

        return jsonify(status="ready"), 200

    @application.post("/visits")
    def create_visit():
        if service is None:
            return jsonify(error="storage_not_configured"), 503

        visit = service.create()

        response = jsonify(**visit.as_dict(), source="db")
        response.status_code = 201

        response.headers["Location"] = url_for(
            "get_visit", visit_id=visit.id
        )

        return response

    @application.get("/visits/<int:visit_id>")
    def get_visit(visit_id: int):
        if not 1 <= visit_id <= 9223372036854775807:
            return jsonify(error="visit_not_found"), 404

        if service is None:
            return jsonify(error="storage_not_configured"), 503

        visit, source = service.get(visit_id)

        if visit is None:
            return jsonify(error="visit_not_found"), 404

        return jsonify(**visit.as_dict(), source=source), 200

    @application.errorhandler(StorageUnavailable)
    def unavailable(_error: StorageUnavailable):
        return jsonify(error="storage_unavailable"), 503, {
            "Retry-After": "3"
        }

    @application.cli.command("init-db")
    def init_db_command():
        resources = application.extensions.get("lab3_resources")

        if resources is None:
            raise click.ClickException(
                "Configure DATABASE_URL and REDIS_URL first"
            )

        resources.init_schema()
        click.echo("Database schema initialized")

    return application
