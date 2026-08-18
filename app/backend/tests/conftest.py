import sys
from pathlib import Path

import pytest

BACKEND_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BACKEND_DIR))

from app import create_app


class FakeDatabase:
    def __init__(self):
        self.available = True
        self.items = []
        self.next_id = 1

    def check_connection(self):
        return self.available


@pytest.fixture()
def fake_database():
    return FakeDatabase()


@pytest.fixture()
def app(fake_database):
    return create_app({"TESTING": True}, database=fake_database)


@pytest.fixture()
def client(app):
    return app.test_client()
