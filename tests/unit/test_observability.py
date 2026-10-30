from unittest.mock import MagicMock

import pytest
from prometheus_client.parser import text_string_to_metric_families

from app import create_app
from app.visits import StorageUnavailable, VisitService


CONFIG = {
    "TESTING": True,
    "DATABASE_URL": "",
    "REDIS_URL": "",
    "CACHE_TTL_SECONDS": 60,
    "APP_VERSION": "stable-test",
    "CHAOS_MODE": False,
}


def counters(client):
    response = client.get("/metrics")
    assert response.status_code == 200
    assert response.mimetype == "text/plain"
    return {
        (sample.labels["status_code"], sample.labels["route"]): sample.value
        for metric in text_string_to_metric_families(response.get_data(as_text=True))
        for sample in metric.samples
        if sample.name == "http_requests_total"
    }


def test_stable_demo_never_injects_failure(monkeypatch):
    application = create_app(CONFIG)
    random_value = MagicMock(return_value=0.0)
    monkeypatch.setattr("app.random.random", random_value)
    client = application.test_client()
    response = client.get("/demo")
    assert response.status_code == 200
    assert response.get_json() == {"status": "ok", "version": "stable-test"}
    random_value.assert_not_called()
    assert counters(client) == {("200", "/demo"): 1, ("500", "/demo"): 0}


@pytest.mark.parametrize("value, expected_code, expected_status", [
    (0.0, 500, "error"),
    (0.29999, 500, "error"),
    (0.30, 200, "ok"),
    (0.99, 200, "ok"),
])
def test_chaos_threshold_and_error_accounting(
    monkeypatch, value, expected_code, expected_status,
):
    application = create_app({**CONFIG, "CHAOS_MODE": "true"})
    monkeypatch.setattr("app.random.random", lambda: value)
    client = application.test_client()
    response = client.get("/demo")
    assert response.status_code == expected_code
    assert response.get_json() == {
        "status": expected_status, "version": "stable-test",
    }
    values = counters(client)
    assert values[(str(expected_code), "/demo")] == 1
    assert sum(values.values()) == 1


def test_probes_and_metrics_do_not_dilute_application_error_ratio():
    client = create_app(CONFIG).test_client()
    assert counters(client) == {("200", "/demo"): 0, ("500", "/demo"): 0}
    assert client.get("/health").get_json() == {"status": "ok"}
    assert client.get("/ready").status_code == 503
    assert client.get("/metrics").status_code == 200
    assert counters(client) == {("200", "/demo"): 0, ("500", "/demo"): 0}


def test_factories_have_independent_registries_and_counters():
    first = create_app(CONFIG)
    second = create_app(CONFIG)
    assert first.extensions["lab4_metrics_registry"] is not (
        second.extensions["lab4_metrics_registry"]
    )
    first_client = first.test_client()
    second_client = second.test_client()
    first_client.get("/demo")
    first_client.get("/demo")
    assert counters(first_client)[("200", "/demo")] == 2
    assert counters(second_client)[("200", "/demo")] == 0


def test_route_labels_have_bounded_cardinality():
    client = create_app(CONFIG).test_client()
    for identifier in (1, 2, 3):
        assert client.get(f"/visits/{identifier}").status_code == 503
        assert client.get(f"/unknown/{identifier}").status_code == 404
    values = counters(client)
    assert values[("503", "/visits/<int:visit_id>")] == 3
    assert values[("404", "__unmatched__")] == 3
    assert len(values) == 4


def test_handled_storage_failures_count_as_application_errors():
    store = MagicMock()
    store.create.side_effect = StorageUnavailable()
    service = VisitService(store, MagicMock())
    client = create_app(CONFIG, service=service).test_client()
    assert client.post("/visits").status_code == 503
    assert counters(client)[("503", "/visits")] == 1


def test_unhandled_http_500_is_counted_in_production_mode():
    application = create_app({**CONFIG, "TESTING": False})

    @application.get("/unexpected-error")
    def unexpected_error():
        raise RuntimeError("Intentional test-only exception")

    client = application.test_client()
    assert client.get("/unexpected-error").status_code == 500
    assert counters(client)[("500", "/unexpected-error")] == 1


@pytest.mark.parametrize("value", ["yes", "", "truthy", 1, None])
def test_invalid_chaos_configuration_is_rejected(value):
    with pytest.raises(ValueError, match="CHAOS_MODE must be true or false"):
        create_app({**CONFIG, "CHAOS_MODE": value})


def test_environment_configuration_is_used(monkeypatch):
    monkeypatch.setenv("DATABASE_URL", "")
    monkeypatch.setenv("REDIS_URL", "")
    monkeypatch.setenv("APP_VERSION", "environment-version")
    monkeypatch.setenv("CHAOS_MODE", "false")
    application = create_app()
    assert application.config["CHAOS_MODE"] is False
    assert application.test_client().get("/demo").get_json() == {
        "status": "ok", "version": "environment-version",
    }
