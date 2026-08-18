#!/usr/bin/env bash
set -Eeuo pipefail

readonly COMPOSE_FILE="deploy/compose/docker-compose.yml"
readonly BASE_URL="http://127.0.0.1:8080"
COMPOSE=(docker compose --env-file .env -f "$COMPOSE_FILE")
readonly -a COMPOSE
created_id=""
persistent_id=""
response_file=""
mysql_stopped_by_verifier=false

log() {
  printf '[phase2] %s\n' "$1"
}

fail() {
  printf '[phase2] ERROR: %s\n' "$1" >&2
  "${COMPOSE[@]}" ps >&2 || true
  "${COMPOSE[@]}" logs --tail=80 >&2 || true
  exit 1
}

preflight_fail() {
  printf '[phase2] ERROR: %s\n' "$1" >&2
  exit 1
}

expect_status() {
  local expected="$1"
  local url="$2"
  local actual
  actual="$(curl --silent --output "$response_file" --write-out '%{http_code}' "$url")"
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

assert_no_host_ports() {
  local service="$1"
  local container_id
  local bindings
  container_id="$("${COMPOSE[@]}" ps -q "$service")"
  [[ -n "$container_id" ]] || fail "$service has no container id"
  bindings="$(docker inspect "$container_id" --format '{{json .HostConfig.PortBindings}}')"
  [[ "$bindings" == '{}' ]] || fail "$service publishes a host port: $bindings"
}

# ShellCheck SC2329 is disabled because cleanup is invoked indirectly by the EXIT trap.
# shellcheck disable=SC2329
cleanup() {
  local current
  if [[ "$mysql_stopped_by_verifier" == true ]]; then
    "${COMPOSE[@]}" start mysql >/dev/null 2>&1 || true
    for ((current = 1; current <= 60; current += 1)); do
      if [[ "$(curl --silent --output /dev/null --write-out '%{http_code}' "$BASE_URL/readyz" || true)" == '200' ]]; then
        break
      fi
      sleep 2
    done
  fi
  if [[ -n "$created_id" ]]; then
    curl --silent --request DELETE "$BASE_URL/api/items/$created_id" >/dev/null || true
  fi
  if [[ -n "$persistent_id" ]]; then
    curl --silent --request DELETE "$BASE_URL/api/items/$persistent_id" >/dev/null || true
  fi
  if [[ -n "$response_file" ]]; then
    rm -f -- "$response_file"
  fi
}

[[ -f .env ]] || preflight_fail '.env is missing; copy .env.example to .env first'
command -v docker >/dev/null || preflight_fail 'docker is not installed'
command -v curl >/dev/null || preflight_fail 'curl is not installed'
command -v python3 >/dev/null || preflight_fail 'python3 is not installed'
response_file="$(mktemp /tmp/devops-phase2-response.XXXXXX)"
trap cleanup EXIT

log 'validating Compose and tracked source safety'
"${COMPOSE[@]}" config --quiet
if git ls-files | grep -Eq '(^|/)(\.env|id_(rsa|ed25519)|.*\.(pem|key|p12|pfx))$'; then
  fail 'Git tracks a forbidden secret-shaped file'
fi
if git grep -nEI '(ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|-----BEGIN (OPENSSH|RSA|EC) PRIVATE KEY-----)' -- .; then
  fail 'tracked content contains a token or private-key signature'
fi
[[ "$(sed -n '/^[^#[:space:]]/ {p;q;}' app/backend/.dockerignore)" == '*' ]] \
  || fail 'backend build context is not default-deny'
[[ "$(sed -n '/^[^#[:space:]]/ {p;q;}' app/frontend/.dockerignore)" == '*' ]] \
  || fail 'frontend build context is not default-deny'

log 'building and starting all services'
"${COMPOSE[@]}" up -d --build --wait
running_services="$("${COMPOSE[@]}" ps --services --status running | sort | tr '\n' ' ')"
[[ "$running_services" == 'backend frontend mysql ' ]] || fail "running services differ: $running_services"
curl --fail --silent "$BASE_URL/" | grep -Fq '运维任务清单' || fail 'frontend page is unavailable'
expect_status 200 "$BASE_URL/healthz"
expect_status 200 "$BASE_URL/readyz"

log 'checking host exposure and runtime users'
assert_no_host_ports backend
assert_no_host_ports mysql
[[ "$("${COMPOSE[@]}" exec -T backend id -u)" != '0' ]] || fail 'backend runs as root'
[[ "$("${COMPOSE[@]}" exec -T frontend id -u)" != '0' ]] || fail 'frontend runs as root'
if "${COMPOSE[@]}" exec -T backend python -m pytest --version >/dev/null 2>&1; then
  fail 'pytest is present in the runtime backend image'
fi

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

log 'creating persistence marker'
persistent_response="$(curl --fail --silent \
  --header 'Content-Type: application/json' \
  --data '{"title":"Phase 2 persistence","description":"Must survive container recreation","status":"pending"}' \
  "$BASE_URL/api/items")"
persistent_id="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$persistent_response")"

log 'stopping MySQL and checking degraded readiness'
"${COMPOSE[@]}" stop mysql
mysql_stopped_by_verifier=true
wait_for_status 503 "$BASE_URL/readyz" 20
expect_status 200 "$BASE_URL/healthz"
expect_status 503 "$BASE_URL/api/items"

log 'starting MySQL and checking automatic recovery'
"${COMPOSE[@]}" start mysql
wait_for_status 200 "$BASE_URL/readyz" 60
mysql_stopped_by_verifier=false

log 'recreating containers without deleting the volume'
"${COMPOSE[@]}" up -d --force-recreate --wait
curl --fail --silent "$BASE_URL/api/items" \
  | python3 -c 'import json,sys; expected=int(sys.argv[1]); assert any(item["id"] == expected for item in json.load(sys.stdin))' "$persistent_id" \
  || fail 'persistent item disappeared after recreation'

log 'Phase 2 verification passed'
