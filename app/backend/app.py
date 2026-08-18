from pathlib import Path

from flask import Flask, jsonify

from config import load_config
from db import Database
from routes import api


def create_app(test_config=None, database=None):
    frontend_dir = Path(__file__).resolve().parents[1] / "frontend" / "src"
    app = Flask(__name__, static_folder=str(frontend_dir), static_url_path="")
    app.config.from_mapping(load_config())
    if test_config:
        app.config.update(test_config)

    app.extensions["database"] = database or Database.from_config(app.config)
    app.register_blueprint(api)

    @app.get("/")
    def index():
        return app.send_static_file("index.html")

    @app.get("/healthz")
    def healthz():
        return jsonify(status="alive")

    @app.get("/readyz")
    def readyz():
        if app.extensions["database"].check_connection():
            return jsonify(status="ready")
        return (
            jsonify(
                error={
                    "code": "database_unavailable",
                    "message": "database is unavailable",
                }
            ),
            503,
        )

    return app


if __name__ == "__main__":
    flask_app = create_app()
    flask_app.run(
        host=flask_app.config["FLASK_HOST"],
        port=flask_app.config["FLASK_PORT"],
    )
