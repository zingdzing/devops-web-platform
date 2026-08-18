#!/usr/bin/env bash
set -Eeuo pipefail

CONTAINER_NAME="devops-phase1-mysql"

if [[ "$(docker container inspect -f '{{.State.Running}}' "${CONTAINER_NAME}" 2>/dev/null || true)" == "true" ]]; then
  docker stop "${CONTAINER_NAME}" >/dev/null
  printf 'Stopped %s. Data volume was preserved.\n' "${CONTAINER_NAME}"
else
  printf '%s is already stopped or does not exist.\n' "${CONTAINER_NAME}"
fi
