#!/usr/bin/env bash

set -Eeuo pipefail

readonly CLUSTER_NAME='devops-platform'
readonly CLUSTER_CONTEXT='k3d-devops-platform'
readonly NAMESPACE='devops-platform'
readonly RELEASE='devops-platform'
readonly CHART_DIR='deploy/helm/devops-web-platform'
readonly SECRET_NAME='devops-platform-db'
readonly CONFIGMAP_NAME='devops-platform-devops-web-platform-config'
readonly BACKEND_IMAGE='devops-web-platform-backend:phase3'
readonly FRONTEND_IMAGE='devops-web-platform-frontend:phase3'
readonly BACKEND_DEPLOYMENT='devops-platform-devops-web-platform-backend'
readonly FRONTEND_DEPLOYMENT='devops-platform-devops-web-platform-frontend'
readonly MYSQL_STATEFULSET='devops-platform-devops-web-platform-mysql'
readonly BASE_URL='http://localhost:8080'
readonly ENV_FILE="${PHASE3_ENV_FILE:-.env}"
secret_env_file=''

fail() {
  printf '[phase3-deploy] ERROR: %s\n' "$1" >&2
  exit 1
}

log() {
  printf '[phase3-deploy] %s\n' "$1"
}

assert_existing_database_identity() {
  local current_db_name
  local current_db_password
  local current_db_user
  local current_root_password
  local pvc_count

  if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    return 0
  fi
  pvc_count="$(kubectl get pvc --namespace "$NAMESPACE" -l app.kubernetes.io/component=mysql -o json \
    | jq -er '.items | length')" \
    || fail 'could not inspect the existing MySQL PVC state'
  [[ "$pvc_count" != '0' ]] || return 0

  kubectl get secret "$SECRET_NAME" --namespace "$NAMESPACE" >/dev/null 2>&1 \
    || fail 'MySQL PVC exists but its credential Secret is missing; restore the Secret before deployment'
  current_db_user="$(kubectl get secret "$SECRET_NAME" --namespace "$NAMESPACE" -o json \
    | jq -er '.data.DB_USER | @base64d')"
  current_db_password="$(kubectl get secret "$SECRET_NAME" --namespace "$NAMESPACE" -o json \
    | jq -er '.data.DB_PASSWORD | @base64d')"
  current_root_password="$(kubectl get secret "$SECRET_NAME" --namespace "$NAMESPACE" -o json \
    | jq -er '.data.MYSQL_ROOT_PASSWORD | @base64d')"
  current_db_name="$(kubectl get secret "$SECRET_NAME" --namespace "$NAMESPACE" -o json \
    | jq -r '.data.DB_NAME // empty | if . == "" then "" else @base64d end')"
  if [[ -z "$current_db_name" ]]; then
    kubectl get configmap "$CONFIGMAP_NAME" --namespace "$NAMESPACE" >/dev/null 2>&1 \
      || fail 'MySQL PVC predates the database identity guard and DB_NAME cannot be recovered; follow the destructive local reset Runbook'
    current_db_name="$(kubectl get configmap "$CONFIGMAP_NAME" --namespace "$NAMESPACE" -o jsonpath='{.data.DB_NAME}')"
    log 'migrating the existing database name into the external Secret identity record'
  fi

  if [[ "$current_db_name" != "$DB_NAME" \
    || "$current_db_user" != "$DB_USER" \
    || "$current_db_password" != "$DB_PASSWORD" \
    || "$current_root_password" != "$MYSQL_ROOT_PASSWORD" ]]; then
    fail 'database identity changes are not supported while the Phase 3 PVC exists; keep the existing .env or follow the destructive local reset Runbook'
  fi
}

[[ -f "$ENV_FILE" ]] || fail "$ENV_FILE is missing; create it with: install -m 600 .env.example .env"
[[ "$(stat --format='%a' "$ENV_FILE")" == '600' ]] \
  || fail "$ENV_FILE must have mode 600; run: chmod 600 $ENV_FILE"
[[ -f app/database/init.sql ]] || fail 'app/database/init.sql is missing'
[[ -f "$CHART_DIR/files/init.sql" ]] || fail 'Chart init.sql is missing'
for command_name in docker jq k3d kubectl helm curl make cmp mktemp stat; do
  command -v "$command_name" >/dev/null 2>&1 || fail "$command_name is missing"
done
docker info >/dev/null 2>&1 || fail 'Docker Desktop is not reachable'
cmp --silent app/database/init.sql "$CHART_DIR/files/init.sql" \
  || fail 'Chart init.sql differs from app/database/init.sql'
make phase3-manifests
k3d cluster list -o json | jq -e --arg name "$CLUSTER_NAME" '.[] | select(.name == $name)' >/dev/null \
  || fail 'Phase 3 cluster is missing; run make phase3-cluster-create'
kubectl config use-context "$CLUSTER_CONTEXT" >/dev/null
kubectl wait --for=condition=Ready node --all --timeout=180s

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
for variable_name in DB_NAME DB_USER DB_PASSWORD MYSQL_ROOT_PASSWORD; do
  [[ -n "${!variable_name:-}" ]] || fail "$variable_name is empty in $ENV_FILE"
done

assert_existing_database_identity

umask 077
secret_env_file="$(mktemp /tmp/devops-phase3-secret.XXXXXX)"
cleanup() {
  rm -f -- "$secret_env_file"
}
trap cleanup EXIT
printf 'DB_NAME=%s\nDB_USER=%s\nDB_PASSWORD=%s\nMYSQL_ROOT_PASSWORD=%s\n' \
  "$DB_NAME" "$DB_USER" "$DB_PASSWORD" "$MYSQL_ROOT_PASSWORD" >"$secret_env_file"

log 'building fixed Phase 3 application images'
docker build --tag "$BACKEND_IMAGE" app/backend
docker build --tag "$FRONTEND_IMAGE" app/frontend

log 'importing application images into k3d'
k3d image import --cluster "$CLUSTER_NAME" "$BACKEND_IMAGE" "$FRONTEND_IMAGE"
node_images="$(docker exec k3d-devops-platform-server-0 crictl images)"
grep -Fq 'devops-web-platform-backend' <<<"$node_images" || fail 'backend image was not imported'
grep -Fq 'devops-web-platform-frontend' <<<"$node_images" || fail 'frontend image was not imported'

log 'creating namespace and runtime Secret without printing values'
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic "$SECRET_NAME" \
  --namespace "$NAMESPACE" \
  --from-env-file="$secret_env_file" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl get secret "$SECRET_NAME" --namespace "$NAMESPACE" -o json \
  | jq -e '.data | keys | sort == ["DB_NAME","DB_PASSWORD","DB_USER","MYSQL_ROOT_PASSWORD"]' >/dev/null \
  || fail 'runtime Secret keys differ from the expected contract'

log 'installing or upgrading the application Helm release'
helm upgrade --install "$RELEASE" "$CHART_DIR" \
  --namespace "$NAMESPACE" \
  --create-namespace \
  --set-string mysql.database="$DB_NAME" \
  --rollback-on-failure --wait=watcher --timeout 5m
kubectl rollout status deployment/"$FRONTEND_DEPLOYMENT" --namespace "$NAMESPACE" --timeout=180s
kubectl rollout status deployment/"$BACKEND_DEPLOYMENT" --namespace "$NAMESPACE" --timeout=180s
kubectl rollout status statefulset/"$MYSQL_STATEFULSET" --namespace "$NAMESPACE" --timeout=300s
curl --fail --silent "$BASE_URL/readyz" >/dev/null \
  || fail 'application readiness endpoint is unavailable through Ingress'

log 'Phase 3 deployment is ready'
