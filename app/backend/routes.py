import pymysql
from flask import Blueprint, current_app, jsonify, request

api = Blueprint("api", __name__)
VALID_STATUSES = {"pending", "in_progress", "completed"}


def error_response(code, message, status_code):
    return jsonify(error={"code": code, "message": message}), status_code


def validate_item(payload, default_status=None):
    if not isinstance(payload, dict):
        return None, "request body must be a JSON object"

    title = str(payload.get("title") or "").strip()
    description = str(payload.get("description") or "").strip()
    raw_status = payload.get("status", default_status)

    if raw_status is None:
        return None, "status is required"
    status = str(raw_status).strip()

    if not title:
        return None, "title is required"
    if len(title) > 120:
        return None, "title must not exceed 120 characters"
    if not description:
        return None, "description is required"
    if status not in VALID_STATUSES:
        return None, "status is invalid"

    return {"title": title, "description": description, "status": status}, None


def database():
    return current_app.extensions["database"]


@api.errorhandler(pymysql.MySQLError)
def handle_database_error(error):
    current_app.logger.warning("database operation failed: %s", type(error).__name__)
    return error_response(
        "database_unavailable",
        "database is unavailable",
        503,
    )


@api.get("/api/items")
def list_items():
    return jsonify(database().list_items())


@api.post("/api/items")
def create_item():
    values, validation_error = validate_item(
        request.get_json(silent=True),
        default_status="pending",
    )
    if validation_error:
        return error_response("validation_error", validation_error, 400)

    item = database().create_item(**values)
    return jsonify(item), 201


@api.put("/api/items/<int:item_id>")
def update_item(item_id):
    values, validation_error = validate_item(request.get_json(silent=True))
    if validation_error:
        return error_response("validation_error", validation_error, 400)

    item = database().update_item(item_id=item_id, **values)
    if item is None:
        return error_response("item_not_found", "item was not found", 404)
    return jsonify(item)


@api.delete("/api/items/<int:item_id>")
def delete_item(item_id):
    if not database().delete_item(item_id):
        return error_response("item_not_found", "item was not found", 404)
    return "", 204
