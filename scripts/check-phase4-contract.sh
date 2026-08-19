#!/usr/bin/env bash

set -Eeuo pipefail

readonly JENKINS_DIR='deploy/jenkins'
readonly COMPOSE_FILE="$JENKINS_DIR/compose.yaml"
readonly RBAC_FILE='deploy/kubernetes/jenkins-rbac.yaml'
readonly KUBECONFIG_SCRIPT='scripts/create-phase4-kubeconfig.sh'
readonly CI_DIR='scripts/ci'
readonly JENKINSFILE='Jenkinsfile'

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
require_file "$JENKINSFILE"

for ci_script in \
  "$CI_DIR/common.sh" \
  "$CI_DIR/unit-test.sh" \
  "$CI_DIR/quality-check.sh" \
  "$CI_DIR/build-images.sh" \
  "$CI_DIR/verify-images.sh" \
  "$CI_DIR/deploy.sh" \
  "$CI_DIR/smoke-test.sh" \
  "$CI_DIR/collect-diagnostics.sh"; do
  require_file "$ci_script"
  grep -Fq 'set -Eeuo pipefail' "$ci_script" \
    || fail "$ci_script must use strict Bash mode"
done

grep -Fq 'ci_validate_image_tag()' "$CI_DIR/common.sh" \
  || fail 'common CI helpers must validate IMAGE_TAG'
grep -Fq "readonly CI_FRONTEND_REPOSITORY='zingzin/devops-web-platform-frontend'" "$CI_DIR/common.sh" \
  || fail 'frontend Docker Hub repository does not match the verified zingzin namespace'
grep -Fq "readonly CI_BACKEND_REPOSITORY='zingzin/devops-web-platform-backend'" "$CI_DIR/common.sh" \
  || fail 'backend Docker Hub repository does not match the verified zingzin namespace'
grep -Fq 'org.opencontainers.image.revision' "$CI_DIR/build-images.sh" \
  || fail 'image builds must record the Git revision OCI label'
grep -Fq 'app/frontend' "$CI_DIR/build-images.sh" \
  || fail 'frontend image build context is missing'
grep -Fq 'app/backend' "$CI_DIR/build-images.sh" \
  || fail 'backend image build context is missing'
grep -Fq -- '--entrypoint nginx' "$CI_DIR/verify-images.sh" \
  || fail 'frontend Nginx entrypoint verification is missing'
grep -Eq -- '(^|[[:space:]])-t([[:space:]]|$)' "$CI_DIR/verify-images.sh" \
  || fail 'frontend Nginx test mode is missing'
grep -Fq 'from app import create_app' "$CI_DIR/verify-images.sh" \
  || fail 'backend application import verification is missing'
grep -Fq 'pytest --version' "$CI_DIR/verify-images.sh" \
  || fail 'backend production dependency verification is missing'
grep -Fq -- '--entrypoint id' "$CI_DIR/verify-images.sh" \
  || fail 'non-root image verification is missing'
for required_deploy_option in \
  '--set-string images.frontend.repository' \
  '--set-string images.frontend.tag' \
  '--set-string images.backend.repository' \
  '--set-string images.backend.tag' \
  '--rollback-on-failure' \
  '--timeout 5m'; do
  grep -Fq -- "$required_deploy_option" "$CI_DIR/deploy.sh" \
    || fail "protected Helm deployment option is missing: $required_deploy_option"
done
grep -Fq 'actual_image' "$CI_DIR/deploy.sh" \
  || fail 'actual Pod image comparison is missing'
grep -Fq '/api/items' "$CI_DIR/smoke-test.sh" \
  || fail 'real API smoke check is missing'
grep -Fq 'DEVOPS WEB PLATFORM · PHASE 4' "$CI_DIR/smoke-test.sh" \
  || fail 'Phase 4 page marker smoke check is missing'

expected_stages=(
  'Checkout'
  'Unit Test'
  'Quality Check'
  'Build Images'
  'Image Verification'
  'Push Images'
  'Deploy'
  'Rollout Verification'
  'Smoke Test'
)
stage_count="$(grep -Ec "^[[:space:]]*stage\\('[^']+'\\)" "$JENKINSFILE")"
[[ "$stage_count" == '9' ]] || fail "Jenkinsfile has $stage_count stages; expected 9"
previous_line=0
for stage_name in "${expected_stages[@]}"; do
  stage_line="$(grep -nF "stage('$stage_name')" "$JENKINSFILE" | cut -d: -f1)"
  [[ -n "$stage_line" && "$stage_line" -gt "$previous_line" ]] \
    || fail "Jenkins stage is missing or out of order: $stage_name"
  previous_line="$stage_line"
done
for pipeline_contract in \
  "timeout(time: 30, unit: 'MINUTES')" \
  'disableConcurrentBuilds()' \
  'timestamps()' \
  "numToKeepStr: '20'" \
  "pollSCM('H/5 * * * *')" \
  "credentialsId: 'dockerhub-ci'" \
  "credentialsId: 'k3d-deployer-kubeconfig'" \
  'junit' \
  'archiveArtifacts' \
  'collect-diagnostics.sh'; do
  grep -Fq "$pipeline_contract" "$JENKINSFILE" \
    || fail "Jenkinsfile contract is missing: $pipeline_contract"
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
if grep -Eq 'kubectl[[:space:]]+create[[:space:]]+secret|helm[[:space:]]+rollback' "$CI_DIR"/*.sh; then
  fail 'CI scripts may not create secrets or issue an extra rollback'
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
