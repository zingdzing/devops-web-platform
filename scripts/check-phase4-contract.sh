#!/usr/bin/env bash

set -Eeuo pipefail

readonly JENKINS_DIR='deploy/jenkins'
readonly COMPOSE_FILE="$JENKINS_DIR/compose.yaml"
readonly RBAC_FILE='deploy/kubernetes/jenkins-rbac.yaml'
readonly KUBECONFIG_SCRIPT='scripts/create-phase4-kubeconfig.sh'
readonly CI_DIR='scripts/ci'

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

require_file "$RBAC_FILE"
require_file "$KUBECONFIG_SCRIPT"

for ci_script in \
  "$CI_DIR/common.sh" \
  "$CI_DIR/unit-test.sh" \
  "$CI_DIR/quality-check.sh"; do
  require_file "$ci_script"
  grep -Fq 'set -Eeuo pipefail' "$ci_script" \
    || fail "$ci_script must use strict Bash mode"
done

if grep -Eq '(^|[[:space:]])(source|\.)[[:space:]]+([^[:space:]]*/)?\.env([[:space:]]|$)' "$CI_DIR"/*.sh; then
  fail 'CI scripts must not source the root .env file'
fi
if grep -Eq 'kubectl[[:space:]]+get[[:space:]]+secrets?.*-o[[:space:]]+(yaml|json)' "$CI_DIR"/*.sh; then
  fail 'CI scripts must not render Kubernetes Secrets'
fi
if grep -Eq 'docker[[:space:]]+(system|image)[[:space:]]+prune|helm[[:space:]]+uninstall|kubectl[[:space:]]+delete[[:space:]]+(namespace|pvc|persistentvolumeclaim|secret)|rm[[:space:]]+-rf' "$CI_DIR"/*.sh; then
  fail 'CI scripts contain a forbidden destructive command'
fi

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

grep -Eq '^kind: Role$' "$RBAC_FILE" \
  || fail 'Jenkins RBAC must contain a namespaced Role'
grep -Eq '^kind: RoleBinding$' "$RBAC_FILE" \
  || fail 'Jenkins RBAC must contain a namespaced RoleBinding'
if grep -Eq '^kind: ClusterRole(Binding)?$|cluster-admin' "$RBAC_FILE"; then
  fail 'Jenkins RBAC must not grant cluster-scoped or cluster-admin access'
fi
grep -Fq "readonly EXPECTED_CONTEXT='k3d-devops-platform'" "$KUBECONFIG_SCRIPT" \
  || fail 'kubeconfig generator must pin the expected k3d context'

log 'Phase 4 infrastructure contract passed'
