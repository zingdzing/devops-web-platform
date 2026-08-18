# Phase 1 Minimal Application Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a beginner-friendly operations task list with a Flask API, a MySQL database, a static browser UI, health endpoints, automated tests, and a repeatable real-service verification script.

**Architecture:** Flask runs directly in WSL and temporarily serves the static frontend from the same origin. A `Database` adapter uses parameterized PyMySQL queries against one MySQL 8.4 Docker container; Flask receives the adapter through `app.extensions` so unit tests can inject a small fake without starting MySQL.

**Tech Stack:** Python 3.14, Flask 3.1.3, PyMySQL 1.2.0 with RSA support, pytest 9.1.1, MySQL 8.4 LTS, HTML/CSS/JavaScript, Bash, Docker

**Spec:** `docs/superpowers/specs/2026-08-18-phase-1-minimal-application-design.md`

## Global Constraints

- Keep one Flask service, one MySQL instance, one table, and one static page.
- Do not add ORM, authentication, pagination, search, CORS, Compose, Prometheus, or Kubernetes in Phase 1.
- Use parameterized SQL for every user-controlled value.
- Never commit `.env`, real passwords, tokens, private keys, recovery codes, or kubeconfig.
- `/healthz` checks only the Flask process; `/readyz` performs a real database check.
- Database-unavailable responses use HTTP 503 and never expose connection details.
- Use test-first development and commit each independently testable task.

---

### Task 1: Flask application shell and process health

**Learning purpose:** Establish the smallest runnable Flask application and distinguish a process health check from database readiness.

**Files:**
- Create: `app/backend/__init__.py`
- Create: `app/backend/app.py`
- Create: `app/backend/config.py`
- Create: `app/backend/requirements.txt`
- Create: `app/backend/tests/conftest.py`
- Create: `app/backend/tests/test_health.py`
- Modify: `.gitignore`

**Interfaces:**
- Produces: `load_config() -> dict[str, object]`
- Produces: `create_app(test_config: dict | None = None, database: object | None = None) -> Flask`
- Produces: `GET /`, `GET /healthz`

- [ ] **Step 1: Pin the minimal Python dependencies and ignore the virtual environment**

Create `app/backend/requirements.txt`:

```text
Flask==3.1.3
PyMySQL[rsa]==1.2.0
pytest==9.1.1
```

Ensure `.gitignore` contains:

```text
.venv/
__pycache__/
.pytest_cache/
*.py[cod]
```

- [ ] **Step 2: Write failing tests for the page and process health**

Create `app/backend/tests/conftest.py`:

```python
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
```

Create `app/backend/tests/test_health.py`:

```python
def test_index_serves_frontend(client):
    response = client.get("/")
    assert response.status_code == 200
    assert b"Ops Task Board" in response.data


def test_healthz_reports_process_alive(client):
    response = client.get("/healthz")
    assert response.status_code == 200
    assert response.get_json() == {"status": "alive"}
```

- [ ] **Step 3: Run the focused tests and confirm the expected failure**

Run:

```bash
cd ~/projects/devops-web-platform
python3 -m venv .venv
.venv/bin/python -m pip install -r app/backend/requirements.txt
.venv/bin/python -m pytest app/backend/tests/test_health.py -v
```

Expected: collection fails because `app.py` or `create_app` does not exist.

- [ ] **Step 4: Implement configuration and the Flask application factory**

Create an empty `app/backend/__init__.py`.

Create `app/backend/config.py`:

```python
import os


def load_config():
    return {
        "DB_HOST": os.getenv("DB_HOST", "127.0.0.1"),
        "DB_PORT": int(os.getenv("DB_PORT", "3306")),
        "DB_NAME": os.getenv("DB_NAME", "ops_tasks"),
        "DB_USER": os.getenv("DB_USER", "ops_app"),
        "DB_PASSWORD": os.getenv("DB_PASSWORD", ""),
        "FLASK_HOST": os.getenv("FLASK_HOST", "127.0.0.1"),
        "FLASK_PORT": int(os.getenv("FLASK_PORT", "5000")),
    }
```

Create `app/backend/app.py`:

```python
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
```

Create a temporary minimal `app/frontend/src/index.html` containing `<title>Ops Task Board</title>` so the focused test has a real file. Task 5 replaces it with the complete UI.

- [ ] **Step 5: Run focused tests and syntax checks**

Run:

```bash
.venv/bin/python -m pytest app/backend/tests/test_health.py -v
.venv/bin/python -m compileall -q app/backend
```

Expected: 2 tests pass and compileall exits 0.

- [ ] **Step 6: Commit the application shell**

```bash
git add .gitignore app/backend app/frontend/src/index.html
git commit -m "feat: add Flask application shell"
```

---

### Task 2: Database adapter and readiness endpoint

**Learning purpose:** Make database connectivity explicit and demonstrate why liveness and readiness are different operational signals.

**Files:**
- Create: `app/backend/db.py`
- Modify: `app/backend/app.py`
- Modify: `app/backend/tests/conftest.py`
- Modify: `app/backend/tests/test_health.py`

**Interfaces:**
- Produces: `Database.from_config(config) -> Database`
- Produces: `Database.check_connection() -> bool`
- Produces: `GET /readyz`
- Consumes: the `database` keyword argument of `create_app`

- [ ] **Step 1: Add a controllable fake database and failing readiness tests**

Add to `conftest.py`:

```python
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
```

Replace the earlier `app` fixture rather than defining a duplicate. Add to `test_health.py`:

```python
def test_readyz_reports_database_ready(client):
    response = client.get("/readyz")
    assert response.status_code == 200
    assert response.get_json() == {"status": "ready"}


def test_readyz_reports_database_unavailable(client, fake_database):
    fake_database.available = False
    response = client.get("/readyz")
    assert response.status_code == 503
    assert response.get_json()["error"]["code"] == "database_unavailable"
```

- [ ] **Step 2: Run the readiness tests and confirm 404 failures**

```bash
.venv/bin/python -m pytest app/backend/tests/test_health.py -v
```

Expected: the two `/readyz` tests fail because the route is missing.

- [ ] **Step 3: Implement the PyMySQL adapter**

Create `app/backend/db.py` with a `Database` class. `from_config` copies `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, and `DB_PASSWORD`. A private `_connect()` calls `pymysql.connect` with `cursorclass=DictCursor`, `connect_timeout=3`, and `autocommit=False`. `check_connection()` executes `SELECT 1`, returns `True` on success, and returns `False` on `pymysql.MySQLError`; every connection is closed with a context manager.

The exact public methods are `from_config(cls, config)`, `check_connection() -> bool`, `list_items() -> list[dict]`, `create_item(title, description, status) -> dict`, `update_item(item_id, title, description, status) -> dict | None`, and `delete_item(item_id) -> bool`.

Only `check_connection` is implemented in this task. The CRUD methods are implemented in Task 3.

- [ ] **Step 4: Construct the real adapter by default and add `/readyz`**

In `create_app`, create `Database.from_config(app.config)` when `database is None`, store it in `app.extensions["database"]`, and add:

```python
@app.get("/readyz")
def readyz():
    if app.extensions["database"].check_connection():
        return jsonify(status="ready")
    return jsonify(error={
        "code": "database_unavailable",
        "message": "database is unavailable",
    }), 503
```

- [ ] **Step 5: Verify readiness behavior**

```bash
.venv/bin/python -m pytest app/backend/tests/test_health.py -v
.venv/bin/python -m compileall -q app/backend
```

Expected: 4 tests pass.

- [ ] **Step 6: Commit database readiness**

```bash
git add app/backend
git commit -m "feat: add database readiness check"
```

---

### Task 3: CRUD API with validation and database failure handling

**Learning purpose:** Build the business API while practicing parameterized SQL, HTTP status codes, validation, transactions, and safe error responses.

**Files:**
- Create: `app/backend/routes.py`
- Create: `app/backend/tests/test_items.py`
- Modify: `app/backend/app.py`
- Modify: `app/backend/db.py`
- Modify: `app/backend/tests/conftest.py`

**Interfaces:**
- Produces: `GET/POST /api/items`
- Produces: `PUT/DELETE /api/items/<int:item_id>`
- Consumes: the four CRUD methods declared in Task 2

- [ ] **Step 1: Extend `FakeDatabase` with deterministic CRUD methods**

Implement `list_items`, `create_item`, `update_item`, and `delete_item` using the in-memory `items` list. Each item has `id`, `title`, `description`, `status`, `created_at`, and `updated_at`; timestamps use the fixed test string `2026-08-18T00:00:00+00:00`. Add `raise_error = False`; each method raises `pymysql.MySQLError("test database failure")` when it is true.

- [ ] **Step 2: Write failing endpoint tests**

Create `test_items.py` with concrete request and response assertions:

```python
import pytest


@pytest.fixture()
def created_item(client):
    response = client.post("/api/items", json={
        "title": "Check backup",
        "description": "Verify the nightly MySQL backup",
    })
    assert response.status_code == 201
    return response.get_json()


def test_list_items_returns_array(client):
    response = client.get("/api/items")
    assert response.status_code == 200
    assert response.get_json() == []


def test_create_item_returns_201(client):
    response = client.post("/api/items", json={
        "title": "Check backup",
        "description": "Verify the nightly MySQL backup",
    })
    assert response.status_code == 201
    assert response.get_json()["status"] == "pending"


@pytest.mark.parametrize(
    ("payload", "message"),
    [
        ({"description": "Missing title"}, "title is required"),
        ({"title": "Bad", "description": "Bad status", "status": "unknown"}, "status is invalid"),
    ],
)
def test_create_rejects_invalid_input(client, payload, message):
    response = client.post("/api/items", json=payload)
    assert response.status_code == 400
    assert response.get_json()["error"]["message"] == message


def test_update_item_returns_updated_record(client, created_item):
    response = client.put(f"/api/items/{created_item['id']}", json={
        "title": created_item["title"],
        "description": created_item["description"],
        "status": "completed",
    })
    assert response.status_code == 200
    assert response.get_json()["status"] == "completed"


def test_update_missing_item_returns_404(client):
    response = client.put("/api/items/999", json={
        "title": "Missing",
        "description": "No matching record",
        "status": "pending",
    })
    assert response.status_code == 404
    assert response.get_json()["error"]["code"] == "item_not_found"


def test_update_requires_status(client, created_item):
    response = client.put(f"/api/items/{created_item['id']}", json={
        "title": created_item["title"],
        "description": created_item["description"],
    })
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
```

- [ ] **Step 3: Run the API tests and confirm route failures**

```bash
.venv/bin/python -m pytest app/backend/tests/test_items.py -v
```

Expected: tests fail with 404 because CRUD routes are not registered.

- [ ] **Step 4: Implement SQL CRUD methods**

Use these parameterized statements in `db.py`:

```sql
SELECT id, title, description, status, created_at, updated_at
FROM ops_tasks ORDER BY created_at DESC, id DESC
```

```sql
INSERT INTO ops_tasks (title, description, status) VALUES (%s, %s, %s)
```

```sql
UPDATE ops_tasks SET title = %s, description = %s, status = %s WHERE id = %s
```

```sql
DELETE FROM ops_tasks WHERE id = %s
```

After insert or update, select the affected row. Commit successful writes, roll back on `pymysql.MySQLError`, re-raise the exception, and always close the connection.

- [ ] **Step 5: Implement the Blueprint and validation**

Create `routes.py` with `api = Blueprint("api", __name__)`, `VALID_STATUSES = {"pending", "in_progress", "completed"}`, and helpers:

```python
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
```

POST calls `validate_item(payload, default_status="pending")`; PUT calls `validate_item(payload)` so a complete update requires all three fields. Catch only `pymysql.MySQLError` at the API boundary and return `database_unavailable` with HTTP 503. Register the Blueprint in `create_app`.

- [ ] **Step 6: Run the complete unit suite**

```bash
.venv/bin/python -m pytest app/backend/tests -v
.venv/bin/python -m compileall -q app/backend
```

Expected: all health and item tests pass.

- [ ] **Step 7: Commit the CRUD API**

```bash
git add app/backend
git commit -m "feat: add operations task API"
```

---

### Task 4: MySQL schema and repeatable local container lifecycle

**Learning purpose:** Connect application code to a real service and make service startup reproducible instead of relying on manual Docker commands.

**Files:**
- Create: `app/database/init.sql`
- Create: `scripts/start-phase1-mysql.sh`
- Create: `scripts/stop-phase1-mysql.sh`
- Modify: `.env.example`
- Modify: `Makefile`

**Interfaces:**
- Produces: Docker container `devops-phase1-mysql`
- Produces: Docker volume `devops-phase1-mysql-data`
- Produces: `make phase1-db-up`, `make phase1-db-down`

- [ ] **Step 1: Create the MySQL schema**

Create `init.sql`:

```sql
CREATE TABLE IF NOT EXISTS ops_tasks (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    title VARCHAR(120) NOT NULL,
    description TEXT NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'pending',
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    CONSTRAINT chk_ops_tasks_status
        CHECK (status IN ('pending', 'in_progress', 'completed'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
```

- [ ] **Step 2: Expand the public environment template**

Use non-deployable examples only:

```dotenv
DB_HOST=127.0.0.1
DB_PORT=3306
DB_NAME=ops_tasks
DB_USER=ops_app
DB_PASSWORD=change-me
MYSQL_ROOT_PASSWORD=change-me-too
FLASK_HOST=127.0.0.1
FLASK_PORT=5000
```

- [ ] **Step 3: Implement the idempotent start script**

`start-phase1-mysql.sh` must use `set -Eeuo pipefail`, require a repository-root `.env`, load it with `set -a; source .env; set +a`, and validate all five database variables. If the container exists, run `docker start devops-phase1-mysql`; otherwise run:

```bash
docker run -d \
  --name devops-phase1-mysql \
  -p "${DB_PORT}:3306" \
  -e MYSQL_DATABASE="${DB_NAME}" \
  -e MYSQL_USER="${DB_USER}" \
  -e MYSQL_PASSWORD="${DB_PASSWORD}" \
  -e MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD}" \
  -v devops-phase1-mysql-data:/var/lib/mysql \
  -v "${PROJECT_ROOT}/app/database/init.sql:/docker-entrypoint-initdb.d/init.sql:ro" \
  mysql:8.4
```

Poll `docker exec devops-phase1-mysql mysqladmin ping --silent` for up to 90 seconds and fail with recent container logs if MySQL does not become healthy.

- [ ] **Step 4: Implement the safe stop script and Make targets**

`stop-phase1-mysql.sh` stops the named container only when it is running; it must not delete the container or volume. Add Make targets that call the scripts.

- [ ] **Step 5: Validate scripts and start real MySQL**

Create an ignored `.env` with randomly generated local passwords, then run:

```bash
shellcheck scripts/start-phase1-mysql.sh scripts/stop-phase1-mysql.sh
bash -n scripts/start-phase1-mysql.sh scripts/stop-phase1-mysql.sh
make phase1-db-up
set -a; source .env; set +a
docker exec devops-phase1-mysql mysql -uops_app -p"$DB_PASSWORD" ops_tasks -e "SHOW CREATE TABLE ops_tasks"
```

Expected: shell checks pass, the container is running, and the table definition includes the status CHECK constraint.

- [ ] **Step 6: Commit database lifecycle automation**

```bash
git add .env.example Makefile app/database scripts/start-phase1-mysql.sh scripts/stop-phase1-mysql.sh
git commit -m "feat: add Phase 1 MySQL environment"
```

---

### Task 5: Beginner-friendly static operations task board

**Learning purpose:** Provide a visible business result for demonstrations while keeping frontend tooling out of the DevOps learning path.

**Files:**
- Replace: `app/frontend/src/index.html`
- Create: `app/frontend/src/app.js`
- Create: `app/frontend/src/style.css`
- Modify: `app/backend/tests/test_health.py`

**Interfaces:**
- Consumes: relative `/api/items` CRUD endpoints
- Produces: task create form, task list, status update, delete action, error banner

- [ ] **Step 1: Strengthen the frontend smoke test**

Update `test_index_serves_frontend` to assert the response includes the Chinese page heading `运维任务清单` and a script reference to `app.js`. Run it and confirm failure against the temporary HTML.

- [ ] **Step 2: Build semantic HTML without a framework**

The page contains one header explaining that this is the Phase 1 application, one form with title and description, one error/status banner using `aria-live="polite"`, and one task list container. Include `style.css` and load `app.js` with `defer`.

- [ ] **Step 3: Implement browser CRUD behavior**

The HTML must expose `task-form`, `title`, `description`, `message`, and `task-list` element IDs. Implement `app.js` with the complete request and rendering flow:

```javascript
const form = document.querySelector("#task-form");
const list = document.querySelector("#task-list");
const messageBox = document.querySelector("#message");

async function apiRequest(path, options = {}) {
  const response = await fetch(path, {
    headers: { "Content-Type": "application/json", ...(options.headers || {}) },
    ...options,
  });
  if (response.status === 204) return null;
  const body = await response.json().catch(() => ({
    error: { message: "服务器返回了无法解析的响应" },
  }));
  if (!response.ok) throw new Error(body.error?.message || "请求失败");
  return body;
}

function showMessage(message, isError = false) {
  messageBox.textContent = message;
  messageBox.dataset.state = isError ? "error" : "success";
}

async function updateTask(id, task, status) {
  await apiRequest(`/api/items/${id}`, {
    method: "PUT",
    body: JSON.stringify({ ...task, status }),
  });
  showMessage("任务状态已更新");
  await loadTasks();
}

async function deleteTask(id) {
  await apiRequest(`/api/items/${id}`, { method: "DELETE" });
  showMessage("任务已删除");
  await loadTasks();
}

function renderTasks(tasks) {
  list.replaceChildren();
  for (const task of tasks) {
    const row = document.createElement("article");
    const title = document.createElement("h2");
    const description = document.createElement("p");
    const status = document.createElement("select");
    const remove = document.createElement("button");
    title.textContent = task.title;
    description.textContent = task.description;
    for (const [value, label] of [["pending", "待处理"], ["in_progress", "处理中"], ["completed", "已完成"]]) {
      const option = document.createElement("option");
      option.value = value;
      option.textContent = label;
      option.selected = value === task.status;
      status.append(option);
    }
    status.addEventListener("change", () => updateTask(task.id, task, status.value).catch(handleError));
    remove.type = "button";
    remove.textContent = "删除";
    remove.addEventListener("click", () => deleteTask(task.id).catch(handleError));
    row.append(title, description, status, remove);
    list.append(row);
  }
}

async function loadTasks() {
  renderTasks(await apiRequest("/api/items"));
}

async function createTask(event) {
  event.preventDefault();
  const submit = form.querySelector('button[type="submit"]');
  submit.disabled = true;
  try {
    await apiRequest("/api/items", {
      method: "POST",
      body: JSON.stringify({
        title: form.elements.title.value,
        description: form.elements.description.value,
      }),
    });
    form.reset();
    showMessage("任务已创建");
    await loadTasks();
  } finally {
    submit.disabled = false;
  }
}

function handleError(error) {
  showMessage(error.message, true);
}

form.addEventListener("submit", (event) => createTask(event).catch(handleError));
loadTasks().catch(handleError);
```

Use `textContent`, never `innerHTML`, for task data. Disable submit while a request is running. Render the three statuses with Chinese labels but send the English enum values to the API.

- [ ] **Step 4: Add responsive CSS with no external assets**

Use a centered content width, readable contrast, card rows, clear status chips, keyboard-visible focus states, and one mobile breakpoint. Do not add a CSS framework, icon library, web font, image, or build step.

- [ ] **Step 5: Verify frontend delivery and unit regression**

```bash
.venv/bin/python -m pytest app/backend/tests -v
.venv/bin/python -m compileall -q app/backend
```

Start Flask with the `.env` values and verify `curl -fsS http://127.0.0.1:5000/` contains `运维任务清单`.

- [ ] **Step 6: Commit the static UI**

```bash
git add app/frontend app/backend/tests/test_health.py
git commit -m "feat: add operations task board UI"
```

---

### Task 6: Real-service acceptance script and documentation

**Learning purpose:** Turn manual checks into repeatable operational evidence that can be discussed in a resume interview.

**Files:**
- Create: `scripts/verify-phase1.sh`
- Modify: `Makefile`
- Modify: `README.md`
- Modify: `app/README.md`
- Modify: `docs/architecture.md`

**Interfaces:**
- Produces: `make phase1-test`
- Produces: `make phase1-run`
- Produces: `make phase1-verify`

- [ ] **Step 1: Implement a fail-fast acceptance script**

The script must:

1. Load the ignored `.env`.
2. Run `python -m compileall` and all pytest tests.
3. Call `make phase1-db-up` and wait for MySQL.
4. Start Flask in the background and register a trap that stops only that process.
5. Assert `/healthz` and `/readyz` return 200.
6. POST one uniquely named verification task and capture its numeric ID with `jq`.
7. GET the list and assert the ID is present.
8. PUT the item to `completed` and assert the returned status.
9. DELETE the item and assert HTTP 204.
10. Stop MySQL and assert `/healthz` remains 200 while `/readyz` becomes 503.
11. Restart MySQL and assert `/readyz` returns 200 again.

Every failure must print the failed check name and exit nonzero. The trap must not delete the MySQL volume, `.env`, or user data.

- [ ] **Step 2: Add Make targets with exact responsibilities**

```make
phase1-test:
	.venv/bin/python -m pytest app/backend/tests -v

phase1-run:
	set -a; . ./.env; set +a; .venv/bin/python app/backend/app.py

phase1-verify:
	./scripts/verify-phase1.sh
```

- [ ] **Step 3: Update documentation without overstating progress**

Change README current status to Phase 1 only after acceptance passes. Document setup, `.env` creation, database startup, test, run, browser URL, verification, and shutdown commands. Explain the difference between `/healthz` and `/readyz`. Keep Jenkins, Kubernetes, Helm, and monitoring explicitly marked as planned.

- [ ] **Step 4: Run the complete acceptance gate**

```bash
shellcheck scripts/*.sh
bash -n scripts/*.sh
make check
make phase1-verify
git diff --check
```

Expected: all prerequisite checks, unit tests, CRUD checks, and the stop/recover readiness test pass.

- [ ] **Step 5: Run a tracked-file secret scan**

Scan for private-key headers, GitHub/Docker token prefixes, password assignments outside `.env.example`, and accidentally tracked `.env`. Confirm `git check-ignore -v .env` reports `.gitignore`.

- [ ] **Step 6: Commit Phase 1 acceptance and documentation**

```bash
git add Makefile README.md app/README.md docs/architecture.md scripts/verify-phase1.sh
git commit -m "docs: add Phase 1 verification workflow"
```

---

### Task 7: Final review and GitHub publication

**Learning purpose:** Preserve evidence that the implementation is reproducible and keep the public repository safe.

**Files:**
- Review: all Phase 1 tracked files

**Interfaces:**
- Produces: verified `main` branch on GitHub

- [ ] **Step 1: Review the commit sequence and working tree**

```bash
git log --oneline --decorate origin/main..main
git status --short --branch
git diff origin/main...main --check
```

Expected: focused Phase 1 commits, no uncommitted files, and no whitespace errors.

- [ ] **Step 2: Re-run the full verification from a fresh shell**

```bash
make check
make phase1-verify
```

Expected: both commands exit 0 with no failed check.

- [ ] **Step 3: Push with the user's unlocked SSH key**

```bash
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519
git push origin main
```

The user enters the SSH passphrase privately; it is never copied into a file or chat.

- [ ] **Step 4: Verify local and remote commit identity**

```bash
git rev-parse HEAD
git ls-remote https://github.com/zingdzing/devops-web-platform.git refs/heads/main
git status --short --branch
```

Expected: the two commit hashes match and `main` is not ahead or behind `origin/main`.
