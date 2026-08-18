#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"
FLASK_LOG="${PROJECT_ROOT}/.phase1-flask.log"
FLASK_PID=""

log() {
  printf '[VERIFY] %s\n' "$1"
}

fail() {
  printf '[FAIL] %s\n' "$1" >&2
  exit 1
}

# Invoked indirectly by the EXIT trap below.
# shellcheck disable=SC2329
cleanup() {
  if [[ -n "${FLASK_PID}" ]] && kill -0 "${FLASK_PID}" 2>/dev/null; then
    kill "${FLASK_PID}" 2>/dev/null || true
    wait "${FLASK_PID}" 2>/dev/null || true
  fi
  rm -f "${FLASK_LOG}"
}
trap cleanup EXIT

cd "${PROJECT_ROOT}"

[[ -f "${ENV_FILE}" ]] || fail "Missing .env; copy .env.example to .env"
[[ -x .venv/bin/python ]] || fail "Missing .venv; create it and install requirements"

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

BASE_URL="http://${FLASK_HOST}:${FLASK_PORT}"

log "Checking Python syntax and unit tests"
.venv/bin/python -m compileall -q app/backend
.venv/bin/python -m pytest app/backend/tests -q

log "Starting MySQL"
make phase1-db-up

log "Starting Flask"
.venv/bin/python app/backend/app.py >"${FLASK_LOG}" 2>&1 &
FLASK_PID=$!

for _ in {1..30}; do
  if curl -fsS "${BASE_URL}/healthz" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
curl -fsS "${BASE_URL}/healthz" >/dev/null || fail "Flask health check failed"
curl -fsS "${BASE_URL}/readyz" >/dev/null || fail "Database readiness check failed"

log "Creating, reading, updating, and deleting one task"
create_response="$(curl -fsS -X POST "${BASE_URL}/api/items" \
  -H 'Content-Type: application/json' \
  --data '{"title":"Phase 1 verification","description":"Automated CRUD acceptance task"}')"
item_id="$(jq -er '.id' <<<"${create_response}")" || fail "Create response has no numeric ID"

curl -fsS "${BASE_URL}/api/items" | jq -e --argjson id "${item_id}" \
  'any(.[]; .id == $id)' >/dev/null || fail "Created task was not listed"

update_response="$(curl -fsS -X PUT "${BASE_URL}/api/items/${item_id}" \
  -H 'Content-Type: application/json' \
  --data '{"title":"Phase 1 verification","description":"Automated CRUD acceptance task","status":"completed"}')"
jq -e '.status == "completed"' <<<"${update_response}" >/dev/null || fail "Task status was not updated"

delete_status="$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE "${BASE_URL}/api/items/${item_id}")"
[[ "${delete_status}" == "204" ]] || fail "Delete returned HTTP ${delete_status}"

log "Stopping MySQL to verify liveness and readiness separation"
make phase1-db-down
health_status="$(curl -sS -o /dev/null -w '%{http_code}' "${BASE_URL}/healthz")"
ready_status="$(curl -sS -o /dev/null -w '%{http_code}' "${BASE_URL}/readyz")"
[[ "${health_status}" == "200" ]] || fail "Health endpoint returned ${health_status} while MySQL was down"
[[ "${ready_status}" == "503" ]] || fail "Readiness endpoint returned ${ready_status} while MySQL was down"

log "Restarting MySQL and verifying recovery"
make phase1-db-up
for _ in {1..30}; do
  if curl -fsS "${BASE_URL}/readyz" >/dev/null 2>&1; then
    log "Phase 1 acceptance passed"
    exit 0
  fi
  sleep 1
done

fail "Readiness did not recover after MySQL restart"
