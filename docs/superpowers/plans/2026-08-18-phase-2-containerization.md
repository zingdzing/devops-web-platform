# Phase 2 Containerization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert the Phase 1 Flask/MySQL application into a reproducible three-container system that starts with Docker Compose, survives container recreation, exposes only Nginx, and records build and troubleshooting evidence.

**Architecture:** An unprivileged Nginx container serves the static task-board frontend and proxies application paths to a non-root Gunicorn/Flask backend. The backend reaches MySQL 8.4.11 over one Compose network, while a named volume persists database data and health-gated dependencies control startup order.

**Tech Stack:** Docker Engine 29.7.2, Docker Compose 5.4.0, Python 3.14.6 slim, Flask 3.1.3, PyMySQL 1.2.0, Gunicorn 26.0.0, nginxinc/nginx-unprivileged 1.28.1 Alpine, MySQL 8.4.11, Bash, pytest 9.1.1

**Spec:** `docs/superpowers/specs/2026-08-18-phase-2-containerization-design.md`

## Global Constraints

- Keep exactly three runtime services: `frontend`, `backend`, and `mysql`.
- Bind only `frontend` to the host, exactly as `127.0.0.1:8080:8080`; do not publish backend port 5000 or MySQL port 3306.
- Run frontend and backend as non-root users; the expected numeric runtime UID for each is not `0`.
- Use `python:3.14.6-slim`, `gunicorn==26.0.0`, `nginxinc/nginx-unprivileged:1.28.1-alpine`, and `mysql:8.4.11`.
- Use local application image names `devops-web-platform-backend:phase2` and `devops-web-platform-frontend:phase2`; do not use a deployment `latest` tag.
- Keep runtime dependencies in `app/backend/requirements.txt` and development dependencies in `app/backend/requirements-dev.txt`; pytest must not be present in the backend runtime image.
- Read local passwords from the Git-ignored root `.env`; never put passwords, tokens, SSH material, recovery codes, or real credentials in Git or Dockerfiles.
- Preserve Phase 1 behavior: `/healthz` reports process liveness, `/readyz` reports database readiness, and `/api/items` supports create, read, update, and delete.
- Preserve MySQL data through ordinary `docker compose down` and container recreation; acceptance commands must not use `down --volumes`.
- Do not introduce Kubernetes, Helm, Jenkins, Prometheus, Grafana, an image registry, or a cloud service in Phase 2.
- Record only problems that actually occur. Troubleshooting documents must contain no invented incidents or secrets.

---

## File Map

- `app/backend/requirements.txt`: production-only Python packages.
- `app/backend/requirements-dev.txt`: production packages plus pytest for local tests.
- `app/backend/Dockerfile`: multi-stage non-root Gunicorn backend image.
- `app/backend/.dockerignore`: backend build-context exclusions.
- `app/frontend/Dockerfile`: unprivileged Nginx frontend image.
- `app/frontend/nginx.conf`: static-file server and reverse-proxy routing.
- `app/frontend/.dockerignore`: frontend build-context exclusions.
- `deploy/compose/docker-compose.yml`: three-service topology, health checks, network, and volume.
- `scripts/verify-phase2.sh`: repeatable Phase 2 acceptance test and recovery exercise.
- `Makefile`: Phase 2 build, start, stop, logs, and verification entry points.
- `docs/implementation/phase-0-environment.md`: reproducible Phase 0 setup record.
- `docs/implementation/phase-1-application.md`: reproducible Phase 1 build and verification record.
- `docs/implementation/phase-2-containers.md`: Phase 2 architecture, commands, and evidence.
- `docs/troubleshooting/phase-0-1.md`: sanitized record of confirmed Phase 0/1 problems.
- `docs/troubleshooting/phase-2-containers.md`: template plus only confirmed Phase 2 incidents.
- `README.md`: verified one-command Compose quick start and project status.
- `docs/architecture.md`: current three-container request and failure flow.
- `deploy/README.md`: Compose-specific operator commands and data warning.

### Task 1: Split production and development dependencies

**Files:**
- Modify: `app/backend/requirements.txt`
- Create: `app/backend/requirements-dev.txt`

**Interfaces:**
- Consumes: the existing test command `.venv/bin/python -m pytest app/backend/tests -v`.
- Produces: a production dependency file consumed by the backend Dockerfile and a development file consumed by local setup.

- [ ] **Step 1: Add a failing dependency-boundary check**

Run:

```bash
! grep -Eq '^pytest([<=>]|$)' app/backend/requirements.txt \
  && grep -Fxq 'gunicorn==26.0.0' app/backend/requirements.txt \
  && grep -Fxq -- '-r requirements.txt' app/backend/requirements-dev.txt \
  && grep -Fxq 'pytest==9.1.1' app/backend/requirements-dev.txt
```

Expected: FAIL because pytest is still in the runtime file, Gunicorn is absent, and `requirements-dev.txt` does not exist.

- [ ] **Step 2: Define exact dependency boundaries**

Replace `app/backend/requirements.txt` with:

```text
Flask==3.1.3
PyMySQL[rsa]==1.2.0
gunicorn==26.0.0
```

Create `app/backend/requirements-dev.txt` with:

```text
-r requirements.txt
pytest==9.1.1
```

- [ ] **Step 3: Rebuild the local virtual environment packages**

Run:

```bash
.venv/bin/python -m pip install -r app/backend/requirements-dev.txt
```

Expected: command exits `0`, and Gunicorn 26.0.0 plus pytest 9.1.1 are installed.

- [ ] **Step 4: Verify dependency boundaries and regression tests**

Run:

```bash
! grep -Eq '^pytest([<=>]|$)' app/backend/requirements.txt
grep -Fxq 'gunicorn==26.0.0' app/backend/requirements.txt
grep -Fxq -- '-r requirements.txt' app/backend/requirements-dev.txt
grep -Fxq 'pytest==9.1.1' app/backend/requirements-dev.txt
.venv/bin/python -m pytest app/backend/tests -v
```

Expected: all boundary checks pass and the existing 14 tests pass.

- [ ] **Step 5: Commit the dependency split**

```bash
git add app/backend/requirements.txt app/backend/requirements-dev.txt
git commit -m "build: split backend runtime and test dependencies"
```

### Task 2: Build a minimal non-root backend image

**Files:**
- Create: `app/backend/Dockerfile`
- Create: `app/backend/.dockerignore`

**Interfaces:**
- Consumes: `create_app()` from `app/backend/app.py`, `requirements.txt`, and environment variables `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, and `DB_PASSWORD`.
- Produces: image `devops-web-platform-backend:phase2`, port `5000`, and HTTP liveness endpoint `/healthz`.

- [ ] **Step 1: Run the image contract before implementation**

Run:

```bash
docker build -t devops-web-platform-backend:phase2 app/backend
```

Expected: FAIL because `app/backend/Dockerfile` does not exist.

- [ ] **Step 2: Create the backend Dockerfile**

Create `app/backend/Dockerfile` with:

```dockerfile
FROM python:3.14.6-slim AS builder

ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /build
COPY requirements.txt ./
RUN python -m venv /opt/venv \
    && /opt/venv/bin/pip install --requirement requirements.txt

FROM python:3.14.6-slim AS runtime

ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

RUN groupadd --gid 10001 app \
    && useradd --uid 10001 --gid app --create-home --shell /usr/sbin/nologin app

WORKDIR /app
COPY --from=builder /opt/venv /opt/venv
COPY --chown=app:app __init__.py app.py config.py db.py routes.py ./

USER 10001:10001
EXPOSE 5000

HEALTHCHECK --interval=10s --timeout=3s --start-period=10s --retries=6 \
  CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:5000/healthz', timeout=2)"]

CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "2", "--access-logfile", "-", "--error-logfile", "-", "app:create_app()"]
```

- [ ] **Step 3: Restrict the backend build context**

Create `app/backend/.dockerignore` with:

```text
__pycache__/
*.py[cod]
.pytest_cache/
.coverage
htmlcov/
tests/
requirements-dev.txt
.env
.env.*
*.pem
*.key
*.p12
*.pfx
```

- [ ] **Step 4: Build and inspect the backend image**

Run:

```bash
docker build -t devops-web-platform-backend:phase2 app/backend
docker run --rm --entrypoint sh devops-web-platform-backend:phase2 -c 'test "$(id -u)" != "0"'
docker run --rm --entrypoint sh devops-web-platform-backend:phase2 -c '! python -m pytest --version'
docker image inspect devops-web-platform-backend:phase2 --format '{{.Config.User}} {{json .Config.ExposedPorts}}'
```

Expected: build succeeds; UID is non-zero; pytest cannot be imported; inspect output includes `10001:10001` and `5000/tcp`.

- [ ] **Step 5: Run the complete backend regression suite**

Run:

```bash
.venv/bin/python -m pytest app/backend/tests -v
```

Expected: 14 tests pass.

- [ ] **Step 6: Commit the backend image**

```bash
git add app/backend/Dockerfile app/backend/.dockerignore
git commit -m "feat: containerize Flask backend with Gunicorn"
```

### Task 3: Build an unprivileged Nginx frontend and proxy

**Files:**
- Create: `app/frontend/Dockerfile`
- Create: `app/frontend/nginx.conf`
- Create: `app/frontend/.dockerignore`

**Interfaces:**
- Consumes: static assets from `app/frontend/src/` and the Compose DNS name `backend:5000`.
- Produces: image `devops-web-platform-frontend:phase2`, static `/`, and proxy routes `/api/`, `/healthz`, and `/readyz` on port 8080.

- [ ] **Step 1: Run the frontend image contract before implementation**

Run:

```bash
docker build -t devops-web-platform-frontend:phase2 app/frontend
```

Expected: FAIL because `app/frontend/Dockerfile` does not exist.

- [ ] **Step 2: Define exact Nginx routing**

Create `app/frontend/nginx.conf` with:

```nginx
server {
    listen 8080;
    server_name _;

    root /usr/share/nginx/html;
    index index.html;

    location = /healthz {
        proxy_pass http://backend:5000/healthz;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location = /readyz {
        proxy_pass http://backend:5000/readyz;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location /api/ {
        proxy_pass http://backend:5000;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location / {
        try_files $uri $uri/ /index.html;
    }
}
```

- [ ] **Step 3: Create the frontend image and build exclusions**

Create `app/frontend/Dockerfile` with:

```dockerfile
FROM nginxinc/nginx-unprivileged:1.28.1-alpine

COPY --chown=101:101 nginx.conf /etc/nginx/conf.d/default.conf
COPY --chown=101:101 src/ /usr/share/nginx/html/

USER 101:101
EXPOSE 8080

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=6 \
  CMD ["wget", "--quiet", "--tries=1", "--spider", "http://127.0.0.1:8080/"]
```

Create `app/frontend/.dockerignore` with:

```text
.env
.env.*
*.pem
*.key
*.p12
*.pfx
```

- [ ] **Step 4: Build and statically validate Nginx**

Run:

```bash
docker build -t devops-web-platform-frontend:phase2 app/frontend
docker run --rm --entrypoint sh devops-web-platform-frontend:phase2 -c 'test "$(id -u)" != "0"'
docker run --rm --entrypoint nginx devops-web-platform-frontend:phase2 -t
docker image inspect devops-web-platform-frontend:phase2 --format '{{.Config.User}} {{json .Config.ExposedPorts}}'
```

Expected: build and `nginx -t` succeed; UID is non-zero; inspect output includes `101:101` and `8080/tcp`.

- [ ] **Step 5: Commit the frontend image**

```bash
git add app/frontend/Dockerfile app/frontend/nginx.conf app/frontend/.dockerignore
git commit -m "feat: add unprivileged Nginx frontend image"
```

### Task 4: Compose the three-service topology

**Files:**
- Create: `deploy/compose/docker-compose.yml`
- Modify: `.env.example`

**Interfaces:**
- Consumes: both Phase 2 Dockerfiles, `app/database/init.sql`, and root `.env` values `DB_NAME`, `DB_USER`, `DB_PASSWORD`, and `MYSQL_ROOT_PASSWORD`.
- Produces: Compose project `devops-web-platform`, services `frontend`, `backend`, `mysql`, network `app-network`, and volume `mysql-data`.

- [ ] **Step 1: Run Compose validation before the file exists**

Run:

```bash
docker compose --env-file .env -f deploy/compose/docker-compose.yml config --quiet
```

Expected: FAIL because `deploy/compose/docker-compose.yml` does not exist.

- [ ] **Step 2: Create the Compose model**

Create `deploy/compose/docker-compose.yml` with:

```yaml
name: devops-web-platform

services:
  mysql:
    image: mysql:8.4.11
    environment:
      MYSQL_DATABASE: ${DB_NAME}
      MYSQL_USER: ${DB_USER}
      MYSQL_PASSWORD: ${DB_PASSWORD}
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
    volumes:
      - mysql-data:/var/lib/mysql
      - ../../app/database/init.sql:/docker-entrypoint-initdb.d/01-init.sql:ro
    networks:
      - app-network
    healthcheck:
      test: ["CMD-SHELL", "mysqladmin ping --host=127.0.0.1 --user=root --password=$$MYSQL_ROOT_PASSWORD --silent"]
      interval: 10s
      timeout: 5s
      retries: 12
      start_period: 30s
    restart: unless-stopped

  backend:
    image: devops-web-platform-backend:phase2
    build:
      context: ../../app/backend
    environment:
      DB_HOST: mysql
      DB_PORT: "3306"
      DB_NAME: ${DB_NAME}
      DB_USER: ${DB_USER}
      DB_PASSWORD: ${DB_PASSWORD}
    depends_on:
      mysql:
        condition: service_healthy
    networks:
      - app-network
    expose:
      - "5000"
    restart: unless-stopped

  frontend:
    image: devops-web-platform-frontend:phase2
    build:
      context: ../../app/frontend
    depends_on:
      backend:
        condition: service_healthy
    networks:
      - app-network
    ports:
      - "127.0.0.1:8080:8080"
    restart: unless-stopped

networks:
  app-network:
    driver: bridge

volumes:
  mysql-data:
```

- [ ] **Step 3: Clarify environment values for both Phase 1 and Phase 2**

Keep the existing safe values in `.env.example` and change its opening comment to:

```text
# Safe local examples for Phase 1 and Phase 2. Copy to .env; .env is ignored by Git.
```

Do not change any example into a real credential.

- [ ] **Step 4: Validate the resolved Compose topology without leaking secrets**

Run:

```bash
docker compose --env-file .env -f deploy/compose/docker-compose.yml config --quiet
test "$(docker compose --env-file .env -f deploy/compose/docker-compose.yml config --services | sort | tr '\n' ' ')" = "backend frontend mysql "
test "$(docker compose --env-file .env -f deploy/compose/docker-compose.yml config --volumes | tr '\n' ' ')" = "mysql-data "
test "$(docker compose --env-file .env -f deploy/compose/docker-compose.yml config --networks | tr '\n' ' ')" = "app-network "
```

Expected: config parses, and exact service, volume, and network names match.

- [ ] **Step 5: Build and start the system**

Run:

```bash
docker compose --env-file .env -f deploy/compose/docker-compose.yml up -d --build --wait
docker compose --env-file .env -f deploy/compose/docker-compose.yml ps
```

Expected: all three services are running and healthy.

- [ ] **Step 6: Verify routing, internal-only ports, and non-root users**

Run:

```bash
curl --fail --silent http://127.0.0.1:8080/ | grep -Fq '运维任务清单'
curl --fail --silent http://127.0.0.1:8080/healthz | grep -Fq '"alive"'
curl --fail --silent http://127.0.0.1:8080/readyz | grep -Fq '"ready"'
test "$(docker compose --env-file .env -f deploy/compose/docker-compose.yml port backend 5000 2>/dev/null || true)" = ""
test "$(docker compose --env-file .env -f deploy/compose/docker-compose.yml port mysql 3306 2>/dev/null || true)" = ""
test "$(docker compose --env-file .env -f deploy/compose/docker-compose.yml exec -T backend id -u)" != "0"
test "$(docker compose --env-file .env -f deploy/compose/docker-compose.yml exec -T frontend id -u)" != "0"
```

Expected: static page and proxied health routes work; backend and MySQL have no host mapping; application containers have non-zero UIDs.

- [ ] **Step 7: Commit Compose topology**

```bash
git add deploy/compose/docker-compose.yml .env.example
git commit -m "feat: orchestrate Phase 2 services with Compose"
```

### Task 5: Automate full Phase 2 acceptance and recovery

**Files:**
- Create: `scripts/verify-phase2.sh`
- Modify: `Makefile`

**Interfaces:**
- Consumes: root `.env`, `deploy/compose/docker-compose.yml`, HTTP endpoints through `127.0.0.1:8080`, and Docker Compose lifecycle commands.
- Produces: `make phase2-verify` with exit code `0` only after build, health, CRUD, security, outage, recovery, and persistence checks pass.

- [ ] **Step 1: Add the Make target before the script exists**

Add `phase2-up phase2-down phase2-logs phase2-verify` to `.PHONY`, append these help lines, and add these targets:

```make
		'  make phase2-up      Build and start the Phase 2 stack' \
		'  make phase2-down    Stop Phase 2 without deleting data' \
		'  make phase2-logs    Follow Phase 2 service logs' \
		'  make phase2-verify  Run the full Phase 2 acceptance test'

phase2-up:
	@docker compose --env-file .env -f deploy/compose/docker-compose.yml up -d --build --wait

phase2-down:
	@docker compose --env-file .env -f deploy/compose/docker-compose.yml down

phase2-logs:
	@docker compose --env-file .env -f deploy/compose/docker-compose.yml logs --follow

phase2-verify:
	@bash scripts/verify-phase2.sh
```

Run:

```bash
make phase2-verify
```

Expected: FAIL because `scripts/verify-phase2.sh` does not exist.

- [ ] **Step 2: Create deterministic verification helpers**

Create `scripts/verify-phase2.sh` beginning with:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

readonly COMPOSE_FILE="deploy/compose/docker-compose.yml"
readonly BASE_URL="http://127.0.0.1:8080"
COMPOSE=(docker compose --env-file .env -f "$COMPOSE_FILE")
readonly -a COMPOSE
created_id=""
persistent_id=""

log() {
  printf '[phase2] %s\n' "$1"
}

fail() {
  printf '[phase2] ERROR: %s\n' "$1" >&2
  "${COMPOSE[@]}" ps >&2 || true
  "${COMPOSE[@]}" logs --tail=80 >&2 || true
  exit 1
}

expect_status() {
  local expected="$1"
  local url="$2"
  local actual
  actual="$(curl --silent --output /tmp/devops-phase2-response.json --write-out '%{http_code}' "$url")"
  [[ "$actual" == "$expected" ]] || fail "$url returned $actual; expected $expected"
}

wait_for_status() {
  local expected="$1"
  local url="$2"
  local attempts="$3"
  local current
  for ((current = 1; current <= attempts; current += 1)); do
    if [[ "$(curl --silent --output /dev/null --write-out '%{http_code}' "$url" || true)" == "$expected" ]]; then
      return 0
    fi
    sleep 2
  done
  fail "$url did not reach HTTP $expected"
}

# ShellCheck SC2329 is disabled because cleanup is invoked indirectly by the EXIT trap.
# shellcheck disable=SC2329
cleanup() {
  "${COMPOSE[@]}" start mysql >/dev/null 2>&1 || true
  if [[ -n "$created_id" ]]; then
    curl --silent --request DELETE "$BASE_URL/api/items/$created_id" >/dev/null || true
  fi
  if [[ -n "$persistent_id" ]]; then
    curl --silent --request DELETE "$BASE_URL/api/items/$persistent_id" >/dev/null || true
  fi
}
trap cleanup EXIT
```

- [ ] **Step 3: Add preflight, build, health, and exposure checks**

Append:

```bash
[[ -f .env ]] || fail '.env is missing; copy .env.example to .env first'
command -v docker >/dev/null || fail 'docker is not installed'
command -v curl >/dev/null || fail 'curl is not installed'
command -v python3 >/dev/null || fail 'python3 is not installed'

log 'validating Compose and source safety'
"${COMPOSE[@]}" config --quiet
! git ls-files | grep -Eq '(^|/)(\.env|id_(rsa|ed25519)|.*\.(pem|key|p12|pfx))$' \
  || fail 'Git tracks a forbidden secret-shaped file'
! git grep -nEI '(ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|-----BEGIN (OPENSSH|RSA|EC) PRIVATE KEY-----)' -- . \
  || fail 'tracked content contains a token or private-key signature'

log 'building and starting all services'
"${COMPOSE[@]}" up -d --build --wait
[[ "$("${COMPOSE[@]}" ps --services --status running | sort | tr '\n' ' ')" == 'backend frontend mysql ' ]] \
  || fail 'not all services are running'
curl --fail --silent "$BASE_URL/" | grep -Fq '运维任务清单' || fail 'frontend page is unavailable'
expect_status 200 "$BASE_URL/healthz"
expect_status 200 "$BASE_URL/readyz"

log 'checking host exposure and runtime users'
[[ -z "$("${COMPOSE[@]}" port backend 5000 2>/dev/null || true)" ]] || fail 'backend port is published'
[[ -z "$("${COMPOSE[@]}" port mysql 3306 2>/dev/null || true)" ]] || fail 'MySQL port is published'
[[ "$("${COMPOSE[@]}" exec -T backend id -u)" != '0' ]] || fail 'backend runs as root'
[[ "$("${COMPOSE[@]}" exec -T frontend id -u)" != '0' ]] || fail 'frontend runs as root'
! "${COMPOSE[@]}" exec -T backend python -m pytest --version >/dev/null 2>&1 \
  || fail 'pytest is present in the runtime backend image'
```

- [ ] **Step 4: Add real CRUD assertions**

Append:

```bash
log 'verifying CRUD through Nginx'
create_response="$(curl --fail --silent \
  --header 'Content-Type: application/json' \
  --data '{"title":"Phase 2 verification","description":"Created by verify-phase2.sh","status":"pending"}' \
  "$BASE_URL/api/items")"
created_id="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$create_response")"
[[ "$created_id" =~ ^[0-9]+$ ]] || fail 'create response has no numeric id'

curl --fail --silent "$BASE_URL/api/items" \
  | python3 -c 'import json,sys; expected=int(sys.argv[1]); assert any(item["id"] == expected for item in json.load(sys.stdin))' "$created_id" \
  || fail 'created item is absent from list'

update_response="$(curl --fail --silent \
  --request PUT \
  --header 'Content-Type: application/json' \
  --data '{"title":"Phase 2 verification","description":"Updated by verify-phase2.sh","status":"completed"}' \
  "$BASE_URL/api/items/$created_id")"
python3 -c 'import json,sys; assert json.load(sys.stdin)["status"] == "completed"' <<<"$update_response" \
  || fail 'updated item is not completed'

delete_status="$(curl --silent --output /dev/null --write-out '%{http_code}' --request DELETE "$BASE_URL/api/items/$created_id")"
[[ "$delete_status" == '204' ]] || fail "delete returned $delete_status; expected 204"
created_id=""
```

- [ ] **Step 5: Add MySQL outage, recovery, and persistence assertions**

Append:

```bash
log 'creating persistence marker'
persistent_response="$(curl --fail --silent \
  --header 'Content-Type: application/json' \
  --data '{"title":"Phase 2 persistence","description":"Must survive container recreation","status":"pending"}' \
  "$BASE_URL/api/items")"
persistent_id="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$persistent_response")"

log 'stopping MySQL and checking degraded readiness'
"${COMPOSE[@]}" stop mysql
wait_for_status 503 "$BASE_URL/readyz" 20
expect_status 200 "$BASE_URL/healthz"
expect_status 503 "$BASE_URL/api/items"

log 'starting MySQL and checking automatic recovery'
"${COMPOSE[@]}" start mysql
wait_for_status 200 "$BASE_URL/readyz" 60

log 'recreating stateless containers without deleting the volume'
"${COMPOSE[@]}" up -d --force-recreate --wait
curl --fail --silent "$BASE_URL/api/items" \
  | python3 -c 'import json,sys; expected=int(sys.argv[1]); assert any(item["id"] == expected for item in json.load(sys.stdin))' "$persistent_id" \
  || fail 'persistent item disappeared after recreation'

log 'Phase 2 verification passed'
```

- [ ] **Step 6: Make the script executable and run static checks**

Run:

```bash
chmod +x scripts/verify-phase2.sh
bash -n scripts/verify-phase2.sh
shellcheck scripts/verify-phase2.sh scripts/check-prerequisites.sh scripts/start-phase1-mysql.sh scripts/stop-phase1-mysql.sh scripts/verify-phase1.sh
```

Expected: Bash syntax and ShellCheck pass. If ShellCheck flags a real defect, fix the defect; suppress only a confirmed false positive and place the reason directly above the suppression.

- [ ] **Step 7: Execute the full acceptance test twice**

Run:

```bash
make phase2-verify
make phase2-verify
```

Expected: both runs exit `0`, proving the script is repeatable and the existing named volume does not break verification.

- [ ] **Step 8: Commit automated acceptance**

```bash
git add Makefile scripts/verify-phase2.sh
git commit -m "test: automate Phase 2 container acceptance"
```

### Task 6: Preserve implementation and troubleshooting evidence

**Files:**
- Create: `docs/implementation/phase-0-environment.md`
- Create: `docs/implementation/phase-1-application.md`
- Create: `docs/implementation/phase-2-containers.md`
- Create: `docs/troubleshooting/phase-0-1.md`
- Create: `docs/troubleshooting/phase-2-containers.md`

**Interfaces:**
- Consumes: verified command output from Phases 0, 1, and 2 plus the confirmed incidents listed below.
- Produces: sanitized, reproducible learning material and interview evidence; no document is an executable dependency.

- [ ] **Step 1: Create the three implementation records**

Use these exact top-level sections in every implementation record:

```markdown
# Phase N：阶段名称

## 1. 阶段目标
## 2. 最终架构
## 3. 新增或修改的文件
## 4. 实际执行命令
## 5. 验证结果
## 6. 简历能力映射
## 7. 与下一阶段的关系
```

Populate Phase 0 with the verified WSL, Git, Python, Docker, Compose, kubectl, Helm, and k3d environment; populate Phase 1 with Flask, PyMySQL, MySQL, CRUD, health/readiness, frontend, and 14 pytest tests; populate Phase 2 only with evidence produced by `make phase2-verify`. Commands must be copyable and must not include passwords.

- [ ] **Step 2: Record only confirmed Phase 0/1 incidents**

Create `docs/troubleshooting/phase-0-1.md`. For each incident, use these exact headings:

```markdown
### 问题标题

**现象：**

**影响：**

**证据：**

**根本原因：**

**解决办法：**

**验证结果：**

**预防措施：**
```

Document these confirmed incidents, with sanitized commands and no credential values:

1. A passphrase-protected SSH key was unavailable to a noninteractive push; start `ssh-agent` and run `ssh-add ~/.ssh/id_ed25519` in the user's terminal.
2. Files staged through Windows received mode `100755`; normalize ordinary files to `100644` and scripts to `100755` before commit.
3. ShellCheck SC2034 detected an unused wait-loop variable; use `_` as the loop variable.
4. Phase 1 startup stopped because `.env` was absent; copy `.env.example` to the Git-ignored `.env` and keep real values local.
5. ShellCheck SC2329 treated a trap-only cleanup function as unused; apply one targeted suppression with an adjacent explanation after confirming the trap reference.
6. PowerShell expanded variables before a nested WSL Bash command; run the command inside WSL or move complex logic into a versioned Bash script.

- [ ] **Step 3: Create the Phase 2 troubleshooting record from actual execution**

Create `docs/troubleshooting/phase-2-containers.md` with an opening rule that the file records only reproduced incidents. For every problem that occurred while completing Tasks 1 through 5, use the same seven-field format from Step 2. If no Phase 2 problem occurred, state exactly `Phase 2 验收未出现需要单独记录的故障。` rather than inventing one.

- [ ] **Step 4: Validate documentation completeness and safety**

Run:

```bash
for file in \
  docs/implementation/phase-0-environment.md \
  docs/implementation/phase-1-application.md \
  docs/implementation/phase-2-containers.md; do
  grep -Fq '## 1. 阶段目标' "$file"
  grep -Fq '## 5. 验证结果' "$file"
  grep -Fq '## 6. 简历能力映射' "$file"
done
grep -Fq 'SSH Agent' docs/troubleshooting/phase-0-1.md
! git grep -nEI '(ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|-----BEGIN (OPENSSH|RSA|EC) PRIVATE KEY-----)' -- docs
```

Expected: all required sections exist and no token/private-key pattern is found.

- [ ] **Step 5: Commit the evidence records**

```bash
git add docs/implementation docs/troubleshooting
git commit -m "docs: record project build and troubleshooting evidence"
```

### Task 7: Publish verified Phase 2 operator documentation

**Files:**
- Modify: `README.md`
- Modify: `docs/architecture.md`
- Modify: `deploy/README.md`

**Interfaces:**
- Consumes: only capabilities verified by `make phase2-verify`.
- Produces: a beginner-friendly quick start, architecture explanation, operational commands, and explicit data-deletion warning.

- [ ] **Step 1: Update the README project status and quick start**

Document these exact user actions:

```bash
git clone git@github.com:zingdzing/devops-web-platform.git
cd devops-web-platform
cp .env.example .env
make phase2-up
```

State that the page is at `http://127.0.0.1:8080`, that `.env` is local and must never be committed, and that Phase 2 contains Nginx, Gunicorn/Flask, and MySQL containers. List `make phase2-verify` as the evidence command. Keep later Kubernetes, CI/CD, and monitoring capabilities marked as planned rather than complete.

- [ ] **Step 2: Update architecture and operator commands**

In `docs/architecture.md`, add the exact Phase 2 flow:

```text
Browser -> 127.0.0.1:8080 -> Nginx frontend -> Gunicorn/Flask backend -> MySQL -> mysql-data volume
```

Explain that Compose DNS resolves `backend` and `mysql`, liveness does not require MySQL, readiness does, and only Nginx is host-accessible.

In `deploy/README.md`, document:

```bash
make phase2-up
make phase2-logs
make phase2-verify
make phase2-down
```

Add a warning that `docker compose down --volumes` deletes the Phase 2 database volume and is not part of normal shutdown.

- [ ] **Step 3: Run documentation and repository checks**

Run:

```bash
grep -Fq 'http://127.0.0.1:8080' README.md
grep -Fq 'make phase2-verify' README.md
grep -Fq 'down --volumes' deploy/README.md
grep -Fq 'Gunicorn/Flask' docs/architecture.md
git diff --check
```

Expected: all required text is present and Git reports no whitespace errors.

- [ ] **Step 4: Commit verified documentation**

```bash
git add README.md docs/architecture.md deploy/README.md
git commit -m "docs: publish Phase 2 container operations"
```

### Task 8: Run the final Phase 2 release gate

**Files:**
- Modify only files required to correct failures found by this gate.

**Interfaces:**
- Consumes: every deliverable from Tasks 1 through 7.
- Produces: a clean, reproducible Phase 2 branch ready for review, merge, and user-authenticated push.

- [ ] **Step 1: Run static and unit checks from a clean status**

Run:

```bash
git status --short
bash -n scripts/*.sh
shellcheck scripts/*.sh
.venv/bin/python -m pytest app/backend/tests -v
git diff --check
```

Expected: no uncommitted files before the gate, all shell scripts pass, all 14 tests pass, and Git finds no whitespace errors.

- [ ] **Step 2: Run environment and Phase 2 acceptance checks**

Run:

```bash
make check
make phase2-verify
```

Expected: all 15 prerequisite checks and every Phase 2 acceptance assertion pass.

- [ ] **Step 3: Inspect final runtime evidence**

Run:

```bash
docker compose --env-file .env -f deploy/compose/docker-compose.yml ps
docker compose --env-file .env -f deploy/compose/docker-compose.yml images
docker compose --env-file .env -f deploy/compose/docker-compose.yml port frontend 8080
docker compose --env-file .env -f deploy/compose/docker-compose.yml port backend 5000 2>/dev/null || true
docker compose --env-file .env -f deploy/compose/docker-compose.yml port mysql 3306 2>/dev/null || true
git log --oneline --decorate -8
```

Expected: three healthy services; pinned Phase 2 images; frontend bound to `127.0.0.1:8080`; no backend or MySQL host port; small focused commits.

- [ ] **Step 4: Verify tracked-file security and clean status**

Run:

```bash
! git ls-files | grep -Eq '(^|/)(\.env|id_(rsa|ed25519)|.*\.(pem|key|p12|pfx))$'
! git grep -nEI '(ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|-----BEGIN (OPENSSH|RSA|EC) PRIVATE KEY-----)' -- .
git status --short
```

Expected: no tracked secret-shaped file, no token/private-key pattern, and an empty status.

- [ ] **Step 5: Merge through the chosen branch workflow and push with the user's SSH agent**

After review, merge the Phase 2 feature branch into `main` without discarding unrelated user changes. In the user's WSL terminal, run:

```bash
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519
cd ~/projects/devops-web-platform
git push origin main
```

Expected: `origin/main` advances to the verified Phase 2 merge commit. The user enters the SSH key passphrase locally; it is never shared or recorded.
