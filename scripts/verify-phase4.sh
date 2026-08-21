#!/usr/bin/env bash

set -Eeuo pipefail

readonly JENKINS_CONTAINER='devops-platform-jenkins'
readonly JENKINS_HOME_VOLUME='devops-platform-jenkins-home'
readonly JENKINS_URL='http://127.0.0.1:8090'
readonly APPLICATION_URL='http://localhost:8080'
readonly NAMESPACE='devops-platform'
readonly RELEASE='devops-platform'
readonly FRONTEND_DEPLOYMENT='devops-platform-devops-web-platform-frontend'
readonly BACKEND_DEPLOYMENT='devops-platform-devops-web-platform-backend'
readonly MYSQL_STATEFULSET='devops-platform-devops-web-platform-mysql'
readonly FRONTEND_REPOSITORY='zingzin/devops-web-platform-frontend'
readonly BACKEND_REPOSITORY='zingzin/devops-web-platform-backend'
readonly EXPECTED_CONTEXT='k3d-devops-platform'
readonly PERSISTENCE_TITLE='Phase 4 pipeline persistence'
readonly JENKINS_JOB_CONFIG='/var/jenkins_home/jobs/devops-web-platform/jobs/main/config.xml'

fail() {
  printf '[phase4-verify] ERROR: %s\n' "$1" >&2
  exit 1
}

log() {
  printf '[phase4-verify] %s\n' "$1"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 is missing"
}

wait_for_jenkins() {
  local health

  for _ in $(seq 1 60); do
    health="$(docker inspect --format \
      '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
      "$JENKINS_CONTAINER" 2>/dev/null || true)"
    if [[ "$health" == 'healthy' ]] \
      && curl --fail --silent --show-error "$JENKINS_URL/login" >/dev/null; then
      return 0
    fi
    sleep 2
  done

  fail 'Jenkins did not become healthy within 120 seconds'
}

for command_name in curl docker helm jq kubectl; do
  require_command "$command_name"
done

current_context="$(kubectl config current-context)"
[[ "$current_context" == "$EXPECTED_CONTEXT" ]] \
  || fail "kubectl context must be $EXPECTED_CONTEXT"

log 'Checking the persistent Jenkins controller boundary'
[[ "$(docker inspect --format '{{.State.Running}}' "$JENKINS_CONTAINER")" == 'true' ]] \
  || fail 'Jenkins container is not running'
jenkins_home_mount="$(docker inspect --format \
  '{{range .Mounts}}{{if eq .Destination "/var/jenkins_home"}}{{.Name}}{{end}}{{end}}' \
  "$JENKINS_CONTAINER")"
[[ "$jenkins_home_mount" == "$JENKINS_HOME_VOLUME" ]] \
  || fail 'Jenkins Home is not backed by the expected named volume'
wait_for_jenkins
docker exec "$JENKINS_CONTAINER" java -version >/dev/null 2>&1 \
  || fail 'Java is unavailable in Jenkins'
docker exec "$JENKINS_CONTAINER" docker version >/dev/null \
  || fail 'Docker Engine is unavailable to Jenkins'
docker exec "$JENKINS_CONTAINER" kubectl version --client >/dev/null \
  || fail 'kubectl is unavailable in Jenkins'
docker exec "$JENKINS_CONTAINER" helm version >/dev/null \
  || fail 'Helm is unavailable in Jenkins'
docker exec "$JENKINS_CONTAINER" shellcheck --version >/dev/null \
  || fail 'ShellCheck is unavailable in Jenkins'
docker exec "$JENKINS_CONTAINER" test -f "$JENKINS_JOB_CONFIG" \
  || fail 'Jenkins Pipeline Job configuration is missing'

log 'Checking the deployed Git-SHA images and public registry manifests'
frontend_image="$(kubectl get deployment "$FRONTEND_DEPLOYMENT" \
  --namespace "$NAMESPACE" --output 'jsonpath={.spec.template.spec.containers[0].image}')"
backend_image="$(kubectl get deployment "$BACKEND_DEPLOYMENT" \
  --namespace "$NAMESPACE" --output 'jsonpath={.spec.template.spec.containers[0].image}')"
frontend_tag="${frontend_image#*:}"
backend_tag="${backend_image#*:}"
[[ "$frontend_image" == "$FRONTEND_REPOSITORY:$frontend_tag" ]] \
  || fail 'frontend Deployment uses an unexpected repository'
[[ "$backend_image" == "$BACKEND_REPOSITORY:$backend_tag" ]] \
  || fail 'backend Deployment uses an unexpected repository'
[[ "$frontend_tag" =~ ^git-[0-9a-f]{12}$ ]] \
  || fail 'frontend image tag does not match git-<sha12>'
[[ "$backend_tag" == "$frontend_tag" ]] \
  || fail 'frontend and backend are not using the same Git tag'
docker manifest inspect "$frontend_image" >/dev/null \
  || fail 'frontend image manifest is unavailable from Docker Hub'
docker manifest inspect "$backend_image" >/dev/null \
  || fail 'backend image manifest is unavailable from Docker Hub'

log 'Checking Helm status, rollouts, workload readiness, and actual Pod images'
helm_status="$(helm status "$RELEASE" --namespace "$NAMESPACE" \
  --output json | jq -r '.info.status')"
[[ "$helm_status" == 'deployed' ]] || fail 'Helm release is not deployed'
helm_revision="$(helm status "$RELEASE" --namespace "$NAMESPACE" \
  --output json | jq -r '.version')"
kubectl rollout status deployment/"$FRONTEND_DEPLOYMENT" \
  --namespace "$NAMESPACE" --timeout=120s >/dev/null
kubectl rollout status deployment/"$BACKEND_DEPLOYMENT" \
  --namespace "$NAMESPACE" --timeout=120s >/dev/null
mysql_ready="$(kubectl get statefulset "$MYSQL_STATEFULSET" \
  --namespace "$NAMESPACE" --output 'jsonpath={.status.readyReplicas}')"
[[ "$mysql_ready" == '1' ]] || fail 'MySQL StatefulSet is not Ready'
actual_frontend_image="$(kubectl get pods --namespace "$NAMESPACE" \
  --selector 'app.kubernetes.io/instance=devops-platform,app.kubernetes.io/component=frontend' \
  --output 'jsonpath={.items[0].spec.containers[0].image}')"
actual_backend_image="$(kubectl get pods --namespace "$NAMESPACE" \
  --selector 'app.kubernetes.io/instance=devops-platform,app.kubernetes.io/component=backend' \
  --output 'jsonpath={.items[0].spec.containers[0].image}')"
[[ "$actual_frontend_image" == "$frontend_image" ]] \
  || fail 'frontend Pod image does not match its Deployment'
[[ "$actual_backend_image" == "$backend_image" ]] \
  || fail 'backend Pod image does not match its Deployment'

log 'Checking the real Ingress path and the persistence marker'
curl --fail --silent --show-error "$APPLICATION_URL/healthz" >/dev/null
curl --fail --silent --show-error "$APPLICATION_URL/readyz" >/dev/null
page_body="$(curl --fail --silent --show-error "$APPLICATION_URL/")"
grep -Fq 'DEVOPS WEB PLATFORM · PHASE 4' <<<"$page_body" \
  || fail 'Phase 4 page marker is missing'
items_json="$(curl --fail --silent --show-error "$APPLICATION_URL/api/items")"
jq -e 'type == "array"' <<<"$items_json" >/dev/null \
  || fail '/api/items did not return a JSON array'
matching_markers="$(jq --arg title "$PERSISTENCE_TITLE" \
  '[.[] | select(.title == $title)] | length' <<<"$items_json")"
[[ "$matching_markers" == '1' ]] \
  || fail "expected exactly one persistence marker titled: $PERSISTENCE_TITLE"
persistence_id="$(jq -r --arg title "$PERSISTENCE_TITLE" \
  '.[] | select(.title == $title) | .id' <<<"$items_json")"
[[ "$persistence_id" =~ ^[0-9]+$ ]] || fail 'persistence marker ID is invalid'

log 'Restarting only Jenkins and checking controller persistence'
docker restart "$JENKINS_CONTAINER" >/dev/null
wait_for_jenkins
docker exec "$JENKINS_CONTAINER" test -f "$JENKINS_JOB_CONFIG" \
  || fail 'Jenkins Pipeline Job did not survive the controller restart'
docker exec "$JENKINS_CONTAINER" sh -c \
  'find /var/jenkins_home/jobs/devops-web-platform/jobs/main/builds -mindepth 2 -maxdepth 2 -name build.xml -print -quit | grep -q .' \
  || fail 'Jenkins build history did not survive the controller restart'
docker exec "$JENKINS_CONTAINER" grep -RFq '<id>zing</id>' /var/jenkins_home/users \
  || fail 'Jenkins administrator did not survive the controller restart'
for credential_id in dockerhub-ci k3d-deployer-kubeconfig; do
  docker exec "$JENKINS_CONTAINER" sh -c \
    'grep -RFq -- "$1" /var/jenkins_home/credentials.xml /var/jenkins_home/jobs/devops-web-platform 2>/dev/null' \
    sh "<id>$credential_id</id>" \
    || fail "Jenkins credential ID did not survive the controller restart: $credential_id"
done
post_restart_items="$(curl --fail --silent --show-error "$APPLICATION_URL/api/items")"
jq -e --argjson marker_id "$persistence_id" \
  'any(.[]; .id == $marker_id and .title == "Phase 4 pipeline persistence")' \
  <<<"$post_restart_items" >/dev/null \
  || fail 'application persistence marker disappeared after the Jenkins restart'

log "Acceptance passed: image tag $frontend_tag, Helm revision $helm_revision, persistence marker $persistence_id"
