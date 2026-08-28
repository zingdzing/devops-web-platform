#!/usr/bin/env bash

set -Eeuo pipefail

readonly CONTEXT='k3d-devops-platform'
readonly APPLICATION_NAMESPACE='devops-platform'
readonly MONITORING_NAMESPACE='monitoring'
readonly APPLICATION_URL='http://localhost:8080'
readonly PHASE6_MARKER_TITLE='Phase 6 rollback persistence'
readonly RELEASE='devops-platform'
readonly FRONTEND_DEPLOYMENT='devops-platform-devops-web-platform-frontend'
readonly BACKEND_DEPLOYMENT='devops-platform-devops-web-platform-backend'
readonly MYSQL_STATEFULSET='devops-platform-devops-web-platform-mysql'
readonly PROMETHEUS_SERVICE='kube-prometheus-stack-prometheus'
readonly PROMETHEUS_PORT="${PHASE6_PROMETHEUS_PORT:-29090}"
readonly PROMETHEUS_URL="http://127.0.0.1:${PROMETHEUS_PORT}"

prometheus_pid=''
temp_dir=''
created_item_id=''
pvc_name_before=''
pvc_uid_before=''

log() {
  printf '[phase6-verify] %s\n' "$1"
}

fail() {
  printf '[phase6-verify] ERROR: %s\n' "$1" >&2
  exit 1
}

api() {
  local path="$1"
  shift
  curl --fail --silent --show-error \
    --connect-timeout 3 --max-time 10 \
    "$@" "${APPLICATION_URL}${path}"
}

# ShellCheck SC2329 is disabled because cleanup is invoked by traps.
# shellcheck disable=SC2329
cleanup() {
  local exit_status="$?"
  trap - EXIT INT TERM
  set +e

  if [[ -n "$created_item_id" ]]; then
    api "/api/items/$created_item_id" --request DELETE >/dev/null 2>&1 || true
  fi
  if [[ -n "$prometheus_pid" ]]; then
    kill "$prometheus_pid" >/dev/null 2>&1 || true
    wait "$prometheus_pid" >/dev/null 2>&1 || true
  fi
  [[ -z "$temp_dir" ]] || rm -rf -- "$temp_dir"
  exit "$exit_status"
}

wait_for_prometheus() {
  local attempt
  for ((attempt = 1; attempt <= 20; attempt += 1)); do
    if curl --fail --silent --output /dev/null "$PROMETHEUS_URL/-/ready"; then
      return 0
    fi
    sleep 1
  done
  cat "$temp_dir/prometheus-port-forward.log" >&2 || true
  fail 'Prometheus port-forward did not become ready'
}

pvc_identity() {
  kubectl --context "$CONTEXT" --namespace "$APPLICATION_NAMESPACE" \
    get persistentvolumeclaims -l app.kubernetes.io/component=mysql -o json \
    | jq -r '
        [.items[] | select(.status.phase == "Bound")]
        | if length == 1 then "\(.[0].metadata.name)\t\(.[0].metadata.uid)" else empty end
      '
}

for command_name in curl helm jq kubectl mktemp; do
  command -v "$command_name" >/dev/null 2>&1 \
    || fail "$command_name is missing"
done
[[ "$(kubectl config current-context)" == "$CONTEXT" ]] \
  || fail "current Kubernetes context must be $CONTEXT"

[[ "$(helm status "$RELEASE" --kubeconfig "${KUBECONFIG:-$HOME/.kube/config}" \
  --namespace "$APPLICATION_NAMESPACE" -o json | jq -r '.info.status')" == 'deployed' ]] \
  || fail 'Helm release is not deployed'
kubectl --context "$CONTEXT" --namespace "$APPLICATION_NAMESPACE" \
  rollout status "deployment/$FRONTEND_DEPLOYMENT" --timeout=120s >/dev/null \
  || fail 'frontend Deployment is not Ready'
kubectl --context "$CONTEXT" --namespace "$APPLICATION_NAMESPACE" \
  rollout status "deployment/$BACKEND_DEPLOYMENT" --timeout=120s >/dev/null \
  || fail 'backend Deployment is not Ready'
kubectl --context "$CONTEXT" --namespace "$APPLICATION_NAMESPACE" \
  rollout status "statefulset/$MYSQL_STATEFULSET" --timeout=180s >/dev/null \
  || fail 'MySQL StatefulSet is not Ready'

pvc_record="$(pvc_identity)"
[[ -n "$pvc_record" ]] || fail 'expected exactly one Bound MySQL PVC'
IFS=$'\t' read -r pvc_name_before pvc_uid_before <<<"$pvc_record"
kubectl --context "$CONTEXT" --namespace "$MONITORING_NAMESPACE" \
  wait pod --all --for=condition=Ready --timeout=120s >/dev/null \
  || fail 'monitoring Pods are not Ready'

api '/healthz' --output /dev/null || fail '/healthz failed'
api '/readyz' --output /dev/null || fail '/readyz failed'
items_response="$(api '/api/items')" || fail 'task list API failed'
jq -e --arg title "$PHASE6_MARKER_TITLE" '
    [.[] | select(.title == $title and .status == "completed")]
    | length >= 1
  ' <<<"$items_response" >/dev/null \
  || fail 'completed Phase 6 persistence marker is missing'

temp_dir="$(mktemp -d /tmp/devops-phase6-verify.XXXXXX)"
trap cleanup EXIT INT TERM
kubectl --context "$CONTEXT" --namespace "$MONITORING_NAMESPACE" \
  port-forward --address 127.0.0.1 "service/$PROMETHEUS_SERVICE" \
  "$PROMETHEUS_PORT:9090" >"$temp_dir/prometheus-port-forward.log" 2>&1 &
prometheus_pid="$!"
wait_for_prometheus

curl --fail --silent --show-error "$PROMETHEUS_URL/api/v1/targets" \
  | jq -e '
      [.data.activeTargets[]
        | select(.health == "up"
            and .labels.namespace == "devops-platform"
            and .labels.service == "backend")]
      | length == 1
    ' >/dev/null \
  || fail 'backend Prometheus Target is not UP'
curl --fail --silent --show-error "$PROMETHEUS_URL/api/v1/alerts" \
  | jq -e '
      [.data.alerts[]
        | select(.state == "firing" and .labels.severity == "critical")]
      | length == 0
    ' >/dev/null \
  || fail 'a critical Prometheus alert is firing'

create_payload="$(jq -n \
  --arg title "Phase 6 verifier $(date +%s)" \
  --arg description 'Temporary CRUD verification item' \
  '{title: $title, description: $description, status: "pending"}')"
create_response="$(api '/api/items' --request POST \
  --header 'Content-Type: application/json' --data "$create_payload")"
created_item_id="$(jq -r '.id' <<<"$create_response")"
[[ "$created_item_id" =~ ^[1-9][0-9]*$ ]] || fail 'CRUD create returned an invalid ID'

update_payload="$(jq -n \
  --arg title "Phase 6 verifier $(date +%s)" \
  --arg description 'Temporary CRUD verification item updated' \
  '{title: $title, description: $description, status: "in_progress"}')"
api "/api/items/$created_item_id" --request PUT \
  --header 'Content-Type: application/json' --data "$update_payload" \
  | jq -e '.status == "in_progress"' >/dev/null \
  || fail 'CRUD update failed'
api "/api/items/$created_item_id" --request DELETE --output /dev/null \
  || fail 'CRUD delete failed'
api '/api/items' \
  | jq -e --argjson item_id "$created_item_id" \
    'all(.[]; .id != $item_id)' >/dev/null \
  || fail 'deleted CRUD verification item still exists'
created_item_id=''

pvc_record_after="$(pvc_identity)"
[[ -n "$pvc_record_after" ]] || fail 'MySQL PVC disappeared during verification'
IFS=$'\t' read -r pvc_name_after pvc_uid_after <<<"$pvc_record_after"
[[ "$pvc_name_after" == "$pvc_name_before" && "$pvc_uid_after" == "$pvc_uid_before" ]] \
  || fail 'MySQL PVC identity changed during verification'

mkdir -p reports
{
  printf 'Phase 6 final verification\n'
  printf 'generated_at=%s\n' "$(date --iso-8601=seconds)"
  printf 'helm_status=deployed\n'
  printf 'workloads_ready=true\n'
  printf 'persistence_marker_completed=true\n'
  printf 'prometheus_target_up=true\n'
  printf 'critical_alerts_firing=0\n'
  printf 'crud_verified=true\n'
  printf 'mysql_pvc_name=%s\n' "$pvc_name_after"
  printf 'mysql_pvc_uid=%s\n' "$pvc_uid_after"
} >reports/phase6-verification.txt

log 'PASS: recovery state, monitoring, persistence and CRUD verified'
