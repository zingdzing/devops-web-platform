#!/usr/bin/env bash

set -Eeuo pipefail

readonly DOCKER_SOCKET='/var/run/docker.sock'

if [[ ! -S "$DOCKER_SOCKET" ]]; then
  printf '[jenkins-entrypoint] ERROR: %s is unavailable\n' "$DOCKER_SOCKET" >&2
  exit 1
fi

socket_gid="$(stat --format='%g' "$DOCKER_SOCKET")"
if socket_group="$(getent group "$socket_gid")"; then
  socket_group="${socket_group%%:*}"
else
  socket_group='docker-host'
  groupadd --gid "$socket_gid" "$socket_group"
fi

usermod --append --groups "$socket_group" jenkins
printf '[jenkins-entrypoint] starting Jenkins with Docker socket group %s\n' "$socket_gid"
exec gosu jenkins /usr/bin/tini -- /usr/local/bin/jenkins.sh
