#!/usr/bin/env bash

set -Eeuo pipefail

readonly CONTEXT='k3d-devops-platform'
readonly APPLICATION_NAMESPACE='devops-platform'
readonly MONITORING_NAMESPACE='monitoring'
readonly BACKEND_DEPLOYMENT='devops-platform-devops-web-platform-backend'
readonly BACKEND_SELECTOR='app.kubernetes.io/component=backend'
readonly PROMETHEUS_SERVICE='kube-prometheus-stack-prometheus'
readonly ALERTMANAGER_SERVICE='kube-prometheus-stack-alertmanager'
readonly PROMETHEUS_PORT="${PHASE5_PROMETHEUS_PORT:-19090}"
readonly ALERTMANAGER_PORT="${PHASE5_ALERTMANAGER_PORT:-19093}"
readonly PROMETHEUS_URL="http://127.0.0.1:${PROMETHEUS_PORT}"
readonly ALERTMANAGER_URL="http://127.0.0.1:${ALERTMANAGER_PORT}"
readonly APPLICATION_URL='http://localhost:8080'
readonly ALERT_NAME='BackendTargetMissing'

original_replicas=''
backend_scaled=false
prometheus_pid=''
alertmanager_pid=''
temp_dir=''
diagnostics_dir=''
persistence_id=''
pvc_uid_before=''
alert_fired_at=''
alert_resolved_at=''

log() {
  printf '[phase5-verify] %s\n' "$1"
}

preflight_fail() {
  printf '[phase5-verify] ERROR: %s\n' "$1" >&2
  exit 1
}

collect_diagnostics() {
  diagnostics_dir="reports/phase5-diagnostics-$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$diagnostics_dir"

  kubectl --context "$CONTEXT" --namespace "$APPLICATION_NAMESPACE" \
    get deployments,pods,services,endpoints,persistentvolumeclaims -o wide \
    >"$diagnostics_dir/application-resources.txt" 2>&1 || true
  kubectl --context "$CONTEXT" --namespace "$APPLICATION_NAMESPACE" \
    get events --sort-by=.lastTimestamp \
    >"$diagnostics_dir/application-events.txt" 2>&1 || true
  kubectl --context "$CONTEXT" --namespace "$MONITORING_NAMESPACE" \
    get pods,persistentvolumeclaims \
    >"$diagnostics_dir/monitoring-resources.txt" 2>&1 || true
  curl --fail --silent "$PROMETHEUS_URL/api/v1/targets" \
    >"$diagnostics_dir/prometheus-targets.json" 2>/dev/null || true
  curl --fail --silent "$PROMETHEUS_URL/api/v1/rules" \
    >"$diagnostics_dir/prometheus-rules.json" 2>/dev/null || true
  curl --fail --silent "$ALERTMANAGER_URL/api/v2/alerts" \
    >"$diagnostics_dir/alertmanager-alerts.json" 2>/dev/null || true
  log "safe diagnostics written to $diagnostics_dir"
}

restore_backend() {
  if [[ -n "$original_replicas" ]]; then
    kubectl --context "$CONTEXT" --namespace "$APPLICATION_NAMESPACE" \
      scale deployment/"$BACKEND_DEPLOYMENT" --replicas="$original_replicas" \
      >/dev/null 2>&1 || true
    kubectl --context "$CONTEXT" --namespace "$APPLICATION_NAMESPACE" \
      rollout status deployment/"$BACKEND_DEPLOYMENT" --timeout=180s \
      >/dev/null 2>&1 || true
  fi
}

# ShellCheck SC2329 is disabled because cleanup is invoked by the EXIT trap.
# shellcheck disable=SC2329
cleanup() {
  local exit_status="$?"
  trap - EXIT INT TERM
  set +e

  if [[ "$exit_status" -ne 0 ]]; then
    collect_diagnostics
  fi
  if [[ "$backend_scaled" == true ]]; then
    restore_backend
  fi
  for process_id in "$prometheus_pid" "$alertmanager_pid"; do
    if [[ -n "$process_id" ]]; then
      kill "$process_id" >/dev/null 2>&1 || true
      wait "$process_id" >/dev/null 2>&1 || true
    fi
  done
  if [[ -n "$temp_dir" ]]; then
    rm -rf -- "$temp_dir"
  fi
  exit "$exit_status"
}

fail() {
  printf '[phase5-verify] ERROR: %s\n' "$1" >&2
  exit 1
}

wait_for_http() {
  local url="$1"
  local attempts="$2"
  local attempt

  for ((attempt = 1; attempt <= attempts; attempt += 1)); do
    if curl --fail --silent --output /dev/null "$url"; then
      return 0
    fi
    sleep 2
  done
  fail "$url did not become ready"
}

prometheus_query() {
  local query="$1"
  curl --fail --silent --get "$PROMETHEUS_URL/api/v1/query" \
    --data-urlencode "query=$query"
}

require_prometheus_series() {
  local description="$1"
  local query="$2"
  local response

  response="$(prometheus_query "$query")" || fail "Prometheus query failed: $description"
  jq -e '.status == "success" and (.data.result | length > 0)' \
    <<<"$response" >/dev/null \
    || fail "Prometheus query returned no series: $description"
  log "metric available: $description"
}

rule_state_is() {
  local expected_state="$1"
  curl --fail --silent "$PROMETHEUS_URL/api/v1/rules" \
    | jq -e --arg alert_name "$ALERT_NAME" --arg expected "$expected_state" '
        [.data.groups[].rules[]
          | select(.name == $alert_name and .health == "ok" and .state == $expected)]
        | length == 1
      ' >/dev/null
}

wait_for_rule_state() {
  local expected_state="$1"
  local attempts="$2"
  local attempt

  for ((attempt = 1; attempt <= attempts; attempt += 1)); do
    if rule_state_is "$expected_state"; then
      return 0
    fi
    sleep 5
  done
  fail "$ALERT_NAME did not reach Prometheus state $expected_state"
}

alertmanager_has_alert() {
  local expected="$1"
  local count
  count="$(curl --fail --silent "$ALERTMANAGER_URL/api/v2/alerts" \
    | jq --arg alert_name "$ALERT_NAME" '
        [.[] | select(.labels.alertname == $alert_name and .status.state == "active")]
        | length
      ')" || return 1

  if [[ "$expected" == present ]]; then
    [[ "$count" -gt 0 ]]
  else
    [[ "$count" -eq 0 ]]
  fi
}

wait_for_alertmanager() {
  local expected="$1"
  local attempts="$2"
  local attempt

  for ((attempt = 1; attempt <= attempts; attempt += 1)); do
    if alertmanager_has_alert "$expected"; then
      return 0
    fi
    sleep 5
  done
  fail "$ALERT_NAME did not become $expected in Alertmanager"
}

backend_target_is_up() {
  curl --fail --silent "$PROMETHEUS_URL/api/v1/targets" \
    | jq -e '
        [.data.activeTargets[]
          | select(
              .health == "up"
              and .labels.namespace == "devops-platform"
              and .labels.service == "backend"
            )]
        | length == 1
      ' >/dev/null
}

wait_for_backend_target() {
  local attempts="$1"
  local attempt

  for ((attempt = 1; attempt <= attempts; attempt += 1)); do
    if backend_target_is_up; then
      return 0
    fi
    sleep 5
  done
  fail 'backend Prometheus Target did not return to UP'
}

item_exists() {
  local item_id="$1"
  curl --fail --silent "$APPLICATION_URL/api/items" \
    | jq -e --argjson item_id "$item_id" \
      'any(.[]; .id == $item_id)' >/dev/null
}

for command_name in curl date helm jq kubectl mktemp; do
  command -v "$command_name" >/dev/null 2>&1 \
    || preflight_fail "$command_name is missing"
done

[[ "$(kubectl config current-context)" == "$CONTEXT" ]] \
  || preflight_fail "expected current context $CONTEXT"
kubectl --context "$CONTEXT" wait node --all --for=condition=Ready --timeout=30s \
  >/dev/null || preflight_fail 'Kubernetes node is not Ready'
kubectl --context "$CONTEXT" --namespace "$MONITORING_NAMESPACE" \
  wait pod --all --for=condition=Ready --timeout=120s >/dev/null \
  || preflight_fail 'monitoring Pods are not Ready'
[[ "$(kubectl --context "$CONTEXT" --namespace "$MONITORING_NAMESPACE" \
  get persistentvolumeclaims -o json \
  | jq '[.items[] | select(.status.phase == "Bound")] | length')" == '2' ]] \
  || preflight_fail 'expected two Bound monitoring PVCs'
kubectl --context "$CONTEXT" --namespace "$APPLICATION_NAMESPACE" \
  get servicemonitor devops-platform-devops-web-platform-backend >/dev/null \
  || preflight_fail 'backend ServiceMonitor is missing'
kubectl --context "$CONTEXT" --namespace "$APPLICATION_NAMESPACE" \
  get prometheusrule devops-platform-devops-web-platform >/dev/null \
  || preflight_fail 'application PrometheusRule is missing'

original_replicas="$(kubectl --context "$CONTEXT" --namespace "$APPLICATION_NAMESPACE" \
  get deployment "$BACKEND_DEPLOYMENT" -o jsonpath='{.spec.replicas}')"
[[ "$original_replicas" =~ ^[1-9][0-9]*$ ]] \
  || preflight_fail 'backend must start with at least one replica'
pvc_uid_before="$(kubectl --context "$CONTEXT" --namespace "$APPLICATION_NAMESPACE" \
  get persistentvolumeclaims -o jsonpath='{.items[0].metadata.uid}')"

temp_dir="$(mktemp -d /tmp/devops-phase5-verify.XXXXXX)"
trap cleanup EXIT INT TERM

log 'starting temporary loopback-only Prometheus and Alertmanager access'
kubectl --context "$CONTEXT" --namespace "$MONITORING_NAMESPACE" port-forward \
  --address 127.0.0.1 "service/$PROMETHEUS_SERVICE" \
  "$PROMETHEUS_PORT:9090" >"$temp_dir/prometheus-port-forward.log" 2>&1 &
prometheus_pid="$!"
kubectl --context "$CONTEXT" --namespace "$MONITORING_NAMESPACE" port-forward \
  --address 127.0.0.1 "service/$ALERTMANAGER_SERVICE" \
  "$ALERTMANAGER_PORT:9093" >"$temp_dir/alertmanager-port-forward.log" 2>&1 &
alertmanager_pid="$!"
wait_for_http "$PROMETHEUS_URL/-/ready" 30
wait_for_http "$ALERTMANAGER_URL/-/ready" 30

log 'checking Target discovery, loaded rules, and initial inactive state'
backend_target_is_up || fail 'backend Prometheus Target is not UP'
for rule_name in \
  BackendTargetMissing \
  DeploymentReplicasUnavailable \
  ContainerRestartingFrequently; do
  curl --fail --silent "$PROMETHEUS_URL/api/v1/rules" \
    | jq -e --arg rule_name "$rule_name" '
        [.data.groups[].rules[]
          | select(.name == $rule_name and .health == "ok" and .state != "firing")]
        | length == 1
      ' >/dev/null || fail "rule $rule_name is missing, unhealthy, or already firing"
done
alertmanager_has_alert absent \
  || fail "$ALERT_NAME is unexpectedly active before fault injection"

log 'checking application and Kubernetes metric families'
require_prometheus_series 'backend Target UP' \
  'up{namespace="devops-platform",service="backend"} == 1'
require_prometheus_series 'Flask request Counter' 'devops_http_requests_total'
require_prometheus_series 'Flask P95 latency' \
  'histogram_quantile(0.95, sum by (le) (rate(devops_http_request_duration_seconds_bucket[5m])))'
require_prometheus_series 'Deployment replicas' \
  'kube_deployment_status_replicas_available{namespace="devops-platform"}'
require_prometheus_series 'Pod readiness' \
  'kube_pod_status_ready{namespace="devops-platform",condition="true"}'
require_prometheus_series 'Container restarts' \
  'kube_pod_container_status_restarts_total{namespace="devops-platform"}'
require_prometheus_series 'Container CPU' \
  'container_cpu_usage_seconds_total{namespace="devops-platform",container=~"frontend|backend",image!=""}'
require_prometheus_series 'Container memory' \
  'container_memory_working_set_bytes{namespace="devops-platform",container=~"frontend|backend",image!=""}'

log 'creating a real persistence marker through NGINX Ingress'
persistence_response="$(curl --fail --silent \
  --header 'Content-Type: application/json' \
  --data "{\"title\":\"Phase 5 alert persistence\",\"description\":\"Created by verify-phase5.sh at $(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"status\":\"pending\"}" \
  "$APPLICATION_URL/api/items")"
persistence_id="$(jq -r '.id' <<<"$persistence_response")"
[[ "$persistence_id" =~ ^[0-9]+$ ]] \
  || fail 'persistence marker response has no numeric id'
item_exists "$persistence_id" || fail "persistence marker $persistence_id cannot be read"
log "persistence marker created with id=$persistence_id"

log "scaling backend from $original_replicas to 0 to trigger $ALERT_NAME"
kubectl --context "$CONTEXT" --namespace "$APPLICATION_NAMESPACE" \
  scale deployment/"$BACKEND_DEPLOYMENT" --replicas=0 >/dev/null
backend_scaled=true
kubectl --context "$CONTEXT" --namespace "$APPLICATION_NAMESPACE" \
  wait pod --selector "$BACKEND_SELECTOR" --for=delete --timeout=120s >/dev/null
wait_for_rule_state firing 36
alert_fired_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
wait_for_alertmanager present 24
log "$ALERT_NAME is Firing in Prometheus and active in Alertmanager"

log "restoring backend to $original_replicas replicas"
kubectl --context "$CONTEXT" --namespace "$APPLICATION_NAMESPACE" \
  scale deployment/"$BACKEND_DEPLOYMENT" --replicas="$original_replicas" >/dev/null
kubectl --context "$CONTEXT" --namespace "$APPLICATION_NAMESPACE" \
  rollout status deployment/"$BACKEND_DEPLOYMENT" --timeout=180s >/dev/null
backend_scaled=false
wait_for_http "$APPLICATION_URL/readyz" 60
wait_for_backend_target 36
wait_for_rule_state inactive 36
wait_for_alertmanager absent 36
alert_resolved_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
log "$ALERT_NAME is Inactive and absent from Alertmanager after recovery"

log 'verifying CRUD, persistence, and unchanged MySQL PVC identity'
item_exists "$persistence_id" \
  || fail "persistence marker $persistence_id was lost during the alert drill"
update_response="$(curl --fail --silent --request PUT \
  --header 'Content-Type: application/json' \
  --data '{"title":"Phase 5 alert persistence","description":"Survived Firing to Resolved acceptance","status":"completed"}' \
  "$APPLICATION_URL/api/items/$persistence_id")"
[[ "$(jq -r '.status' <<<"$update_response")" == completed ]] \
  || fail "persistence marker $persistence_id could not be updated"
transient_response="$(curl --fail --silent \
  --header 'Content-Type: application/json' \
  --data '{"title":"Phase 5 CRUD delete check","description":"Deleted by verify-phase5.sh","status":"pending"}' \
  "$APPLICATION_URL/api/items")"
transient_id="$(jq -r '.id' <<<"$transient_response")"
delete_status="$(curl --silent --output /dev/null --write-out '%{http_code}' \
  --request DELETE "$APPLICATION_URL/api/items/$transient_id")"
[[ "$delete_status" == 204 ]] || fail "CRUD delete returned HTTP $delete_status"
[[ "$(kubectl --context "$CONTEXT" --namespace "$APPLICATION_NAMESPACE" \
  get persistentvolumeclaims -o jsonpath='{.items[0].metadata.uid}')" == "$pvc_uid_before" ]] \
  || fail 'MySQL PVC identity changed during the alert drill'
curl --fail --silent "$APPLICATION_URL/healthz" >/dev/null \
  || fail 'application health endpoint failed after recovery'
curl --fail --silent "$APPLICATION_URL/readyz" >/dev/null \
  || fail 'application readiness endpoint failed after recovery'

restore_backend
backend_scaled=false
trap - EXIT INT TERM
for process_id in "$prometheus_pid" "$alertmanager_pid"; do
  kill "$process_id" >/dev/null 2>&1 || true
  wait "$process_id" >/dev/null 2>&1 || true
done
rm -rf -- "$temp_dir"

log "PASS: alert_fired_at=$alert_fired_at alert_resolved_at=$alert_resolved_at persistence_id=$persistence_id pvc_uid=${pvc_uid_before:0:8}"
