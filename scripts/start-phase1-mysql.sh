#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"
CONTAINER_NAME="devops-phase1-mysql"
VOLUME_NAME="devops-phase1-mysql-data"

if [[ ! -f "${ENV_FILE}" ]]; then
  printf 'Missing %s. Copy .env.example to .env first.\n' "${ENV_FILE}" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

required_variables=(DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD MYSQL_ROOT_PASSWORD)
for variable in "${required_variables[@]}"; do
  if [[ -z "${!variable:-}" ]]; then
    printf 'Required variable %s is empty.\n' "${variable}" >&2
    exit 1
  fi
done

if docker container inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
  docker start "${CONTAINER_NAME}" >/dev/null
else
  docker run -d \
    --name "${CONTAINER_NAME}" \
    -p "127.0.0.1:${DB_PORT}:3306" \
    -e MYSQL_DATABASE="${DB_NAME}" \
    -e MYSQL_USER="${DB_USER}" \
    -e MYSQL_PASSWORD="${DB_PASSWORD}" \
    -e MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD}" \
    -v "${VOLUME_NAME}:/var/lib/mysql" \
    -v "${PROJECT_ROOT}/app/database/init.sql:/docker-entrypoint-initdb.d/init.sql:ro" \
    mysql:8.4 >/dev/null
fi

for _ in {1..90}; do
  if docker exec -e MYSQL_PWD="${MYSQL_ROOT_PASSWORD}" "${CONTAINER_NAME}" \
    mysqladmin ping -uroot --silent >/dev/null 2>&1; then
    printf 'MySQL is ready in container %s.\n' "${CONTAINER_NAME}"
    exit 0
  fi
  sleep 1
done

printf 'MySQL did not become ready within 90 seconds.\n' >&2
docker logs --tail 50 "${CONTAINER_NAME}" >&2
exit 1
