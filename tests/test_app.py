import pytest
from flask.testing import FlaskClient


from app import create_app


@pytest.fixture()
def client() -> FlaskClient:
    application = create_app()
    application.config.update(TESTING=True)
    return application.test_client()


def test_health_returns_200_and_json(client: FlaskClient) -> None:
    response = client.get("/health")
    assert response.status_code == 200
    assert response.mimetype == "application/json"
    assert response.get_json() == {"status": "ok"}


def test_health_head_has_no_body(client: FlaskClient) -> None:
    response = client.head("/health")
    assert response.status_code == 200
    assert response.data == b""


def test_health_rejects_post(client: FlaskClient) -> None:
    response = client.post("/health")
    assert response.status_code == 405


def test_unknown_route_returns_404(client: FlaskClient) -> None:
    response = client.get("/does-not-exist")
    assert response.status_code == 404
