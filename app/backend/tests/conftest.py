import sys
from pathlib import Path

import pymysql
import pytest

BACKEND_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BACKEND_DIR))

from app import create_app


class FakeDatabase:
    def __init__(self):
        self.available = True
        self.raise_error = False
        self.items = []
        self.next_id = 1

    def _check_error(self):
        if self.raise_error:
            raise pymysql.MySQLError("test database failure")

    def check_connection(self):
        return self.available

    def list_items(self):
        self._check_error()
        return [item.copy() for item in reversed(self.items)]

    def create_item(self, title, description, status):
        self._check_error()
        item = {
            "id": self.next_id,
            "title": title,
            "description": description,
            "status": status,
            "created_at": "2026-08-18T00:00:00+00:00",
            "updated_at": "2026-08-18T00:00:00+00:00",
        }
        self.items.append(item)
        self.next_id += 1
        return item.copy()

    def update_item(self, item_id, title, description, status):
        self._check_error()
        for item in self.items:
            if item["id"] == item_id:
                item.update(
                    title=title,
                    description=description,
                    status=status,
                )
                return item.copy()
        return None

    def delete_item(self, item_id):
        self._check_error()
        for index, item in enumerate(self.items):
            if item["id"] == item_id:
                self.items.pop(index)
                return True
        return False


@pytest.fixture()
def fake_database():
    return FakeDatabase()


@pytest.fixture()
def app(fake_database):
    return create_app({"TESTING": True}, database=fake_database)


@pytest.fixture()
def client(app):
    return app.test_client()
