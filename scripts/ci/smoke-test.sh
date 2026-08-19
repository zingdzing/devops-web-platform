#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=scripts/ci/common.sh
source "$SCRIPT_DIR/common.sh"

for command_name in curl grep python3; do
  ci_require_command "$command_name"
done

readonly CI_BASE_URL="${CI_BASE_URL:-http://host.docker.internal:8080}"
readonly -a CURL_ARGS=(
  --silent
  --show-error
  --connect-timeout 3
  --max-time 10
  --header 'Host: localhost'
)

ci_log "Waiting for readiness through the real Ingress path at $CI_BASE_URL"
ready='false'
for _ in {1..30}; do
  if curl "${CURL_ARGS[@]}" --fail "$CI_BASE_URL/readyz" >/dev/null; then
    ready='true'
    break
  fi
  sleep 2
done
[[ "$ready" == 'true' ]] || ci_fail 'Ingress readiness did not succeed within 60 seconds'

for endpoint in /healthz /readyz; do
  status_code="$(curl "${CURL_ARGS[@]}" --output /dev/null \
    --write-out '%{http_code}' "$CI_BASE_URL$endpoint")"
  [[ "$status_code" == '200' ]] || ci_fail "$endpoint returned HTTP $status_code"
done

curl "${CURL_ARGS[@]}" --fail "$CI_BASE_URL/" \
  | grep -Fq 'DEVOPS WEB PLATFORM · PHASE 4' \
  || ci_fail 'Phase 4 page marker was not found'
curl "${CURL_ARGS[@]}" --fail "$CI_BASE_URL/api/items" \
  | python3 -c 'import json,sys; assert isinstance(json.load(sys.stdin), list)' \
  || ci_fail 'items API did not return a JSON array'

ci_log 'Read-only Ingress smoke checks passed'
