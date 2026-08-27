def test_metrics_endpoint_uses_prometheus_content_type(client):
    response = client.get("/metrics")

    assert response.status_code == 200
    assert response.content_type.startswith("text/plain")
    assert b"devops_app_info" in response.data


def test_request_uses_route_template_not_item_id(client):
    client.put(
        "/api/items/987654",
        json={
            "title": "Missing",
            "description": "No matching record",
            "status": "pending",
        },
    )

    metrics = client.get("/metrics").get_data(as_text=True)

    assert 'endpoint="/api/items/<int:item_id>"' in metrics
    assert "987654" not in metrics


def test_metrics_request_is_not_counted(client):
    first = client.get("/metrics").get_data(as_text=True)
    client.get("/metrics")
    second = client.get("/metrics").get_data(as_text=True)

    assert first == second


def test_histogram_exposes_bucket_count_and_sum(client):
    client.get("/healthz")

    metrics = client.get("/metrics").get_data(as_text=True)

    assert "devops_http_request_duration_seconds_bucket" in metrics
    assert "devops_http_request_duration_seconds_count" in metrics
    assert "devops_http_request_duration_seconds_sum" in metrics


def test_metrics_do_not_expose_configuration_secrets(app, client):
    app.config.update(
        DB_PASSWORD="phase5-database-secret",
        SECRET_KEY="phase5-flask-secret",
    )

    metrics = client.get("/metrics").get_data(as_text=True)

    assert "phase5-database-secret" not in metrics
    assert "phase5-flask-secret" not in metrics
