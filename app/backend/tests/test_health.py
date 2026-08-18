def test_index_serves_frontend(client):
    response = client.get("/")

    assert response.status_code == 200
    assert b"Ops Task Board" in response.data


def test_healthz_reports_process_alive(client):
    response = client.get("/healthz")

    assert response.status_code == 200
    assert response.get_json() == {"status": "alive"}


def test_readyz_reports_database_ready(client):
    response = client.get("/readyz")

    assert response.status_code == 200
    assert response.get_json() == {"status": "ready"}


def test_readyz_reports_database_unavailable(client, fake_database):
    fake_database.available = False

    response = client.get("/readyz")

    assert response.status_code == 503
    assert response.get_json()["error"]["code"] == "database_unavailable"
