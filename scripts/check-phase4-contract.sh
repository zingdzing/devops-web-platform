#!/usr/bin/env bash

set -Eeuo pipefail

readonly JENKINS_DIR='deploy/jenkins'
readonly COMPOSE_FILE="$JENKINS_DIR/compose.yaml"

fail() {
  printf '[phase4-contract] ERROR: %s\n' "$1" >&2
  exit 1
}

log() {
  printf '[phase4-contract] %s\n' "$1"
}

require_file() {
  [[ -f "$1" ]] || fail "$1 is missing"
}

for required_file in \
  "$JENKINS_DIR/Dockerfile" \
  "$COMPOSE_FILE" \
  "$JENKINS_DIR/entrypoint.sh" \
  "$JENKINS_DIR/plugins.txt"; do
  require_file "$required_file"
done

grep -Fq 'FROM jenkins/jenkins:2.568.1-jdk21' "$JENKINS_DIR/Dockerfile" \
  || fail 'Jenkins base image is not pinned to 2.568.1-jdk21'
grep -Fq '127.0.0.1:8090:8080' "$COMPOSE_FILE" \
  || fail 'Jenkins is not bound to 127.0.0.1:8090'
grep -Fq '/var/jenkins_home' "$COMPOSE_FILE" \
  || fail 'Jenkins Home is not persisted'
grep -Fq '/var/run/docker.sock:/var/run/docker.sock' "$COMPOSE_FILE" \
  || fail 'Docker socket is not mounted'
grep -Fq 'host.docker.internal:host-gateway' "$COMPOSE_FILE" \
  || fail 'host gateway mapping is missing'
if grep -Eq '(^|[^0-9])50000([^0-9]|$)' "$COMPOSE_FILE"; then
  fail 'Jenkins inbound-agent port 50000 must not be published'
fi

log 'Phase 4 infrastructure contract passed'
