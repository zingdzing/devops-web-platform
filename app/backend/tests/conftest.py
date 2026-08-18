import sys
from pathlib import Path

import pytest

BACKEND_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BACKEND_DIR))

from app import create_app


@pytest.fixture()
def app():
    return create_app({"TESTING": True})


@pytest.fixture()
def client(app):
    return app.test_client()
