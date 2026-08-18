import pytest


@pytest.fixture()
def created_item(client):
    response = client.post(
        "/api/items",
        json={
            "title": "Check backup",
            "description": "Verify the nightly MySQL backup",
        },
    )
    assert response.status_code == 201
    return response.get_json()


def test_list_items_returns_array(client):
    response = client.get("/api/items")

    assert response.status_code == 200
    assert response.get_json() == []


def test_create_item_returns_201(client):
    response = client.post(
        "/api/items",
        json={
            "title": "Check backup",
            "description": "Verify the nightly MySQL backup",
        },
    )

    assert response.status_code == 201
    assert response.get_json()["status"] == "pending"


@pytest.mark.parametrize(
    ("payload", "message"),
    [
        ({"description": "Missing title"}, "title is required"),
        (
            {
                "title": "Bad",
                "description": "Bad status",
                "status": "unknown",
            },
            "status is invalid",
        ),
    ],
)
def test_create_rejects_invalid_input(client, payload, message):
    response = client.post("/api/items", json=payload)

    assert response.status_code == 400
    assert response.get_json()["error"]["message"] == message


def test_update_item_returns_updated_record(client, created_item):
    response = client.put(
        f"/api/items/{created_item['id']}",
        json={
            "title": created_item["title"],
            "description": created_item["description"],
            "status": "completed",
        },
    )

    assert response.status_code == 200
    assert response.get_json()["status"] == "completed"


def test_update_missing_item_returns_404(client):
    response = client.put(
        "/api/items/999",
        json={
            "title": "Missing",
            "description": "No matching record",
            "status": "pending",
        },
    )

    assert response.status_code == 404
    assert response.get_json()["error"]["code"] == "item_not_found"


def test_update_requires_status(client, created_item):
    response = client.put(
        f"/api/items/{created_item['id']}",
        json={
            "title": created_item["title"],
            "description": created_item["description"],
        },
    )

    assert response.status_code == 400
    assert response.get_json()["error"]["message"] == "status is required"


def test_delete_item_returns_204(client, created_item):
    response = client.delete(f"/api/items/{created_item['id']}")

    assert response.status_code == 204


def test_delete_missing_item_returns_404(client):
    response = client.delete("/api/items/999")

    assert response.status_code == 404


def test_database_error_returns_503(client, fake_database):
    fake_database.raise_error = True

    response = client.get("/api/items")

    assert response.status_code == 503
    assert response.get_json()["error"]["code"] == "database_unavailable"
