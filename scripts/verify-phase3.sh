#!/usr/bin/env bash

set -Eeuo pipefail

readonly NAMESPACE='devops-platform'
readonly RELEASE='devops-platform'
readonly CHART_DIR='deploy/helm/devops-web-platform'
readonly BASE_URL='http://localhost:8080'
readonly BACKEND_SELECTOR='app.kubernetes.io/component=backend'
readonly MYSQL_SELECTOR='app.kubernetes.io/component=mysql'
readonly BACKEND_DEPLOYMENT_NAME='devops-platform-devops-web-platform-backend'
readonly FRONTEND_DEPLOYMENT_NAME='devops-platform-devops-web-platform-frontend'
readonly MYSQL_STATEFUL_NAME='devops-platform-devops-web-platform-mysql'
readonly CLUSTER_CONTEXT='k3d-devops-platform'
created_id=''
persistent_id=''
response_file=''
mysql_scaled_down=false

log() {
  printf '[phase3] %s\n' "$1"
}

fail() {
  printf '[phase3] ERROR: %s\n' "$1" >&2
  kubectl get pods,svc,ingress,pvc --namespace "$NAMESPACE" >&2 || true
  kubectl get events --namespace "$NAMESPACE" --sort-by=.lastTimestamp | tail -n 30 >&2 || true
  exit 1
}

preflight_fail() {
  printf '[phase3] ERROR: %s\n' "$1" >&2
  exit 1
}

expect_status() {
  local expected="$1"
  local url="$2"
  local actual
  actual="$(curl --silent --output "$response_file" --write-out '%{http_code}' "$url" || true)"
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

backend_pod() {
  kubectl get pod --namespace "$NAMESPACE" --selector "$BACKEND_SELECTOR" \
    -o jsonpath='{.items[0].metadata.name}'
}

pod_http_status() {
  local pod_name="$1"
  local path="$2"
  kubectl exec --namespace "$NAMESPACE" "$pod_name" -- python -c '
import sys
import urllib.error
import urllib.request
try:
    response = urllib.request.urlopen(sys.argv[1], timeout=5)
    print(response.status)
except urllib.error.HTTPError as error:
    print(error.code)
' "http://127.0.0.1:5000${path}"
}

wait_for_pod_status() {
  local expected="$1"
  local pod_name="$2"
  local path="$3"
  local attempts="$4"
  local current
  local actual
  for ((current = 1; current <= attempts; current += 1)); do
    actual="$(pod_http_status "$pod_name" "$path" 2>/dev/null || true)"
    if [[ "$actual" == "$expected" ]]; then
      return 0
    fi
    sleep 2
  done
  fail "$pod_name $path did not reach HTTP $expected"
}

wait_for_item() {
  local item_id="$1"
  local attempts="$2"
  local current
  for ((current = 1; current <= attempts; current += 1)); do
    if curl --fail --silent "$BASE_URL/api/items" \
      | python3 -c 'import json,sys; expected=int(sys.argv[1]); assert any(item["id"] == expected for item in json.load(sys.stdin))' "$item_id" \
      >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  fail "item $item_id did not reappear after MySQL recovery"
}

# ShellCheck SC2329 is disabled because cleanup is invoked indirectly by the EXIT trap.
# shellcheck disable=SC2329
cleanup() {
  local exit_status="$?"
  set +e
  if [[ "$mysql_scaled_down" == true ]]; then
    kubectl scale statefulset/"$MYSQL_STATEFUL_NAME" --namespace "$NAMESPACE" --replicas=1 >/dev/null
    kubectl rollout status statefulset/"$MYSQL_STATEFUL_NAME" --namespace "$NAMESPACE" --timeout=300s >/dev/null || true
    kubectl wait --namespace "$NAMESPACE" --for=condition=Available \
      deployment/"$BACKEND_DEPLOYMENT_NAME" --timeout=180s >/dev/null || true
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
  exit "$exit_status"
}

[[ -f .env ]] || preflight_fail '.env is missing; copy .env.example to .env first'
for command_name in curl jq python3 git kubectl helm k3d make mktemp; do
  command -v "$command_name" >/dev/null 2>&1 || preflight_fail "$command_name is missing"
done
[[ "$(kubectl config current-context)" == "$CLUSTER_CONTEXT" ]] \
  || preflight_fail "current context is not $CLUSTER_CONTEXT"
kubectl wait --for=condition=Ready node --all --timeout=30s >/dev/null \
  || preflight_fail 'Kubernetes node is not Ready'
helm status "$RELEASE" --namespace "$NAMESPACE" -o json \
  | jq -e '.info.status == "deployed"' >/dev/null \
  || preflight_fail 'application Helm release is not deployed'
curl --fail --silent "$BASE_URL/readyz" >/dev/null \
  || preflight_fail 'application is not ready through Ingress'

set -a
# shellcheck disable=SC1091
source .env
set +a
[[ -n "${DB_NAME:-}" ]] || preflight_fail 'DB_NAME is empty in .env'

response_file="$(mktemp /tmp/devops-phase3-response.XXXXXX)"
trap cleanup EXIT

log 'checking cluster, controller, workloads, storage, and exposure'
if kubectl --namespace kube-system get deployment traefik >/dev/null 2>&1; then
  fail 'Traefik is present'
fi
[[ "$(kubectl get ingressclass nginx -o jsonpath='{.spec.controller}')" == 'nginx.org/ingress-controller' ]] \
  || fail 'IngressClass nginx has the wrong controller'
kubectl wait --namespace nginx-ingress --for=condition=Available deployment --all --timeout=30s >/dev/null
kubectl wait --namespace "$NAMESPACE" --for=condition=Available deployment/"$FRONTEND_DEPLOYMENT_NAME" --timeout=30s >/dev/null
kubectl wait --namespace "$NAMESPACE" --for=condition=Available deployment/"$BACKEND_DEPLOYMENT_NAME" --timeout=30s >/dev/null
[[ "$(kubectl get statefulset "$MYSQL_STATEFUL_NAME" --namespace "$NAMESPACE" -o jsonpath='{.status.readyReplicas}')" == '1' ]] \
  || fail 'MySQL StatefulSet is not ready'
kubectl get pvc --namespace "$NAMESPACE" -o json \
  | jq -e '[.items[] | select(.status.phase == "Bound")] | length == 1' >/dev/null \
  || fail 'expected one Bound PVC'
kubectl get service --namespace "$NAMESPACE" -o json \
  | jq -e 'all(.items[]; .spec.type == "ClusterIP" and all(.spec.ports[]; (.nodePort // null) == null))' >/dev/null \
  || fail 'an application Service is externally exposed'
[[ "$(kubectl exec --namespace "$NAMESPACE" deployment/"$FRONTEND_DEPLOYMENT_NAME" -- id -u)" != '0' ]] \
  || fail 'frontend runs as root'
[[ "$(kubectl exec --namespace "$NAMESPACE" deployment/"$BACKEND_DEPLOYMENT_NAME" -- id -u)" != '0' ]] \
  || fail 'backend runs as root'
curl --fail --silent "$BASE_URL/" | grep -Fq 'DEVOPS WEB PLATFORM · PHASE 3' \
  || fail 'Phase 3 frontend page is unavailable'

log 'verifying CRUD through F5 NGINX Ingress'
create_response="$(curl --fail --silent \
  --header 'Content-Type: application/json' \
  --data '{"title":"Phase 3 verification","description":"Created by verify-phase3.sh","status":"pending"}' \
  "$BASE_URL/api/items")"
created_id="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$create_response")"
[[ "$created_id" =~ ^[0-9]+$ ]] || fail 'create response has no numeric id'
wait_for_item "$created_id" 10
update_response="$(curl --fail --silent \
  --request PUT \
  --header 'Content-Type: application/json' \
  --data '{"title":"Phase 3 verification","description":"Updated by verify-phase3.sh","status":"completed"}' \
  "$BASE_URL/api/items/$created_id")"
python3 -c 'import json,sys; assert json.load(sys.stdin)["status"] == "completed"' <<<"$update_response" \
  || fail 'updated item is not completed'
delete_status="$(curl --silent --output /dev/null --write-out '%{http_code}' \
  --request DELETE "$BASE_URL/api/items/$created_id")"
[[ "$delete_status" == '204' ]] || fail "delete returned $delete_status; expected 204"
created_id=''

log 'deleting the backend Pod and verifying Deployment reconciliation'
old_backend_uid="$(kubectl get pod --namespace "$NAMESPACE" --selector "$BACKEND_SELECTOR" -o jsonpath='{.items[0].metadata.uid}')"
old_backend_pod="$(backend_pod)"
kubectl delete pod --namespace "$NAMESPACE" "$old_backend_pod" --wait=true >/dev/null
kubectl wait --namespace "$NAMESPACE" --for=condition=Ready pod --selector "$BACKEND_SELECTOR" --timeout=180s >/dev/null
kubectl rollout status deployment/"$BACKEND_DEPLOYMENT_NAME" --namespace "$NAMESPACE" --timeout=180s >/dev/null
new_backend_uid="$(kubectl get pod --namespace "$NAMESPACE" --selector "$BACKEND_SELECTOR" -o jsonpath='{.items[0].metadata.uid}')"
[[ "$new_backend_uid" != "$old_backend_uid" ]] || fail 'backend Pod UID did not change'
log "backend Pod replaced: ${old_backend_uid:0:8} -> ${new_backend_uid:0:8}"
wait_for_status 200 "$BASE_URL/healthz" 30
wait_for_status 200 "$BASE_URL/readyz" 30

log 'scaling MySQL down and checking Kubernetes readiness semantics'
backend_pod_name="$(backend_pod)"
kubectl scale statefulset/"$MYSQL_STATEFUL_NAME" --namespace "$NAMESPACE" --replicas=0 >/dev/null
mysql_scaled_down=true
kubectl wait --namespace "$NAMESPACE" --for=delete pod --selector "$MYSQL_SELECTOR" --timeout=180s >/dev/null
wait_for_pod_status 503 "$backend_pod_name" /readyz 30
[[ "$(pod_http_status "$backend_pod_name" /healthz)" == '200' ]] \
  || fail 'backend liveness failed while MySQL was unavailable'
expect_status 503 "$BASE_URL/readyz"

log 'restoring MySQL and checking automatic recovery'
kubectl scale statefulset/"$MYSQL_STATEFUL_NAME" --namespace "$NAMESPACE" --replicas=1 >/dev/null
kubectl rollout status statefulset/"$MYSQL_STATEFUL_NAME" --namespace "$NAMESPACE" --timeout=300s >/dev/null
wait_for_pod_status 200 "$backend_pod_name" /readyz 60
wait_for_status 200 "$BASE_URL/readyz" 60
mysql_scaled_down=false

log 'creating a persistence marker and recreating the MySQL Pod'
persistent_response="$(curl --fail --silent \
  --header 'Content-Type: application/json' \
  --data '{"title":"Phase 3 persistence","description":"Must survive MySQL Pod recreation","status":"pending"}' \
  "$BASE_URL/api/items")"
persistent_id="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$persistent_response")"
old_mysql_uid="$(kubectl get pod --namespace "$NAMESPACE" --selector "$MYSQL_SELECTOR" -o jsonpath='{.items[0].metadata.uid}')"
mysql_pod="$(kubectl get pod --namespace "$NAMESPACE" --selector "$MYSQL_SELECTOR" -o jsonpath='{.items[0].metadata.name}')"
kubectl delete pod --namespace "$NAMESPACE" "$mysql_pod" --wait=true >/dev/null
kubectl wait --namespace "$NAMESPACE" --for=condition=Ready pod --selector "$MYSQL_SELECTOR" --timeout=300s >/dev/null
kubectl rollout status statefulset/"$MYSQL_STATEFUL_NAME" --namespace "$NAMESPACE" --timeout=300s >/dev/null
new_mysql_uid="$(kubectl get pod --namespace "$NAMESPACE" --selector "$MYSQL_SELECTOR" -o jsonpath='{.items[0].metadata.uid}')"
[[ "$new_mysql_uid" != "$old_mysql_uid" ]] || fail 'MySQL Pod UID did not change'
log "MySQL Pod replaced: ${old_mysql_uid:0:8} -> ${new_mysql_uid:0:8}"
wait_for_status 200 "$BASE_URL/readyz" 60
wait_for_item "$persistent_id" 30
curl --silent --request DELETE "$BASE_URL/api/items/$persistent_id" >/dev/null
persistent_id=''

log 'checking repeated Helm upgrade and tracked-file safety'
helm upgrade --install "$RELEASE" "$CHART_DIR" \
  --namespace "$NAMESPACE" \
  --set-string mysql.database="$DB_NAME" \
  --rollback-on-failure --wait=watcher --timeout 5m >/dev/null
make phase3-manifests >/dev/null
if git ls-files | grep -Eq '(^|/)(\.env|kubeconfig([^/]*|/.*)|id_(rsa|ed25519)|.*\.(pem|key|p12|pfx)|.*secret.*\.ya?ml)$'; then
  fail 'Git tracks a forbidden secret-shaped file'
fi
if git grep -nEI '(ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|-----BEGIN (OPENSSH|RSA|EC) PRIVATE KEY-----)' -- .; then
  fail 'tracked content contains a token or private-key signature'
fi

log 'Phase 3 verification passed'
