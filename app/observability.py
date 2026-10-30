from flask import Flask, Response, request
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    CollectorRegistry,
    Counter,
    generate_latest,
)


def configure_metrics(application: Flask) -> None:
    registry = CollectorRegistry()
    requests = Counter(
        "http_requests_total",
        "Completed application HTTP responses, excluding probes and metrics.",
        ("status_code", "route"),
        registry=registry,
    )

    for status_code in ("200", "500"):
        requests.labels(status_code=status_code, route="/demo")
    application.extensions["lab4_metrics_registry"] = registry

    @application.after_request
    def count_response(response: Response) -> Response:
        if request.path not in {"/health", "/ready", "/metrics"}:
            route = request.url_rule.rule if request.url_rule else "__unmatched__"
            requests.labels(
                status_code=str(response.status_code), route=route
            ).inc()
        return response

    @application.get("/metrics")
    def metrics() -> Response:
        return Response(generate_latest(registry), content_type=CONTENT_TYPE_LATEST)
