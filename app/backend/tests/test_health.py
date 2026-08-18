def test_index_serves_frontend(client):
    response = client.get("/")

    assert response.status_code == 200
    assert b"Ops Task Board" in response.data


def test_healthz_reports_process_alive(client):
    response = client.get("/healthz")

    assert response.status_code == 200
    assert response.get_json() == {"status": "alive"}
