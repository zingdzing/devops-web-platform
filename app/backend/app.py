from pathlib import Path

from flask import Flask, jsonify

from config import load_config


def create_app(test_config=None, database=None):
    frontend_dir = Path(__file__).resolve().parents[1] / "frontend" / "src"
    app = Flask(__name__, static_folder=str(frontend_dir), static_url_path="")
    app.config.from_mapping(load_config())
    if test_config:
        app.config.update(test_config)
    if database is not None:
        app.extensions["database"] = database

    @app.get("/")
    def index():
        return app.send_static_file("index.html")

    @app.get("/healthz")
    def healthz():
        return jsonify(status="alive")

    return app


if __name__ == "__main__":
    flask_app = create_app()
    flask_app.run(
        host=flask_app.config["FLASK_HOST"],
        port=flask_app.config["FLASK_PORT"],
    )
