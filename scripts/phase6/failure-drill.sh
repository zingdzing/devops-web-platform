#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
readonly REPO_ROOT

# shellcheck source=scripts/phase6/common.sh
source "$SCRIPT_DIR/common.sh"

baseline_revision=''
baseline_backend_image=''
baseline_frontend_image=''
baseline_pvc_name=''
baseline_pvc_uid=''
marker_id=''
prometheus_pid=''
temp_dir=''
cluster_mutated=false
drill_succeeded=false

cleanup_port_forward() {
  if [[ -n "$prometheus_pid" ]]; then
    kill "$prometheus_pid" >/dev/null 2>&1 || true
    wait "$prometheus_pid" >/dev/null 2>&1 || true
    prometheus_pid=''
  fi
}

start_prometheus_access() {
  cleanup_port_forward
  kubectl --kubeconfig "$KUBECONFIG" --namespace "$PHASE6_MONITORING_NAMESPACE" \
    port-forward --address 127.0.0.1 \
    "service/$PHASE6_PROMETHEUS_SERVICE" \
    "$PHASE6_PROMETHEUS_PORT:9090" \
    >"$temp_dir/prometheus-port-forward.log" 2>&1 &
  prometheus_pid="$!"

  local attempt
  for ((attempt = 1; attempt <= 20; attempt += 1)); do
    if curl --fail --silent --output /dev/null \
      "http://127.0.0.1:${PHASE6_PROMETHEUS_PORT}/-/ready"; then
      return 0
    fi
    sleep 1
  done
  cat "$temp_dir/prometheus-port-forward.log" >&2 || true
  phase6_fail 'Prometheus port-forward did not become ready'
}

monitoring_is_healthy() {
  kubectl --kubeconfig "$KUBECONFIG" --namespace "$PHASE6_MONITORING_NAMESPACE" \
    wait pod --all --for=condition=Ready --timeout=120s >/dev/null
}

backend_target_is_up() {
  curl --fail --silent --show-error \
    "http://127.0.0.1:${PHASE6_PROMETHEUS_PORT}/api/v1/targets" \
    | jq -e '
        [.data.activeTargets[]
          | select(.health == "up"
              and .labels.namespace == "devops-platform"
              and .labels.service == "backend")]
        | length == 1
      ' >/dev/null
}

application_is_healthy() {
  phase6_api '/healthz' --output /dev/null \
    && phase6_api '/readyz' --output /dev/null \
    && phase6_api '/api/items' --output /dev/null
}

workloads_are_ready() {
  kubectl --kubeconfig "$KUBECONFIG" --namespace "$PHASE6_NAMESPACE" \
    rollout status "deployment/$PHASE6_FRONTEND_DEPLOYMENT" --timeout=120s >/dev/null \
    && kubectl --kubeconfig "$KUBECONFIG" --namespace "$PHASE6_NAMESPACE" \
      rollout status "deployment/$PHASE6_BACKEND_DEPLOYMENT" --timeout=120s >/dev/null \
    && kubectl --kubeconfig "$KUBECONFIG" --namespace "$PHASE6_NAMESPACE" \
      rollout status "statefulset/$PHASE6_MYSQL_STATEFULSET" --timeout=180s >/dev/null
}

current_backend_image() {
  kubectl --kubeconfig "$KUBECONFIG" --namespace "$PHASE6_NAMESPACE" \
    get deployment "$PHASE6_BACKEND_DEPLOYMENT" \
    -o jsonpath='{.spec.template.spec.containers[0].image}'
}

current_frontend_image() {
  kubectl --kubeconfig "$KUBECONFIG" --namespace "$PHASE6_NAMESPACE" \
    get deployment "$PHASE6_FRONTEND_DEPLOYMENT" \
    -o jsonpath='{.spec.template.spec.containers[0].image}'
}

pvc_identity() {
  kubectl --kubeconfig "$KUBECONFIG" --namespace "$PHASE6_NAMESPACE" \
    get persistentvolumeclaims -l app.kubernetes.io/component=mysql -o json \
    | jq -r '
        [.items[] | select(.status.phase == "Bound")]
        | if length == 1 then "\(.[0].metadata.name)\t\(.[0].metadata.uid)" else empty end
      '
}

capture_baseline() {
  local context namespace image image_tag pvc_record target_response

  for command_name in curl date helm jq kubectl mktemp; do
    phase6_require_command "$command_name"
  done
  phase6_require_variable KUBECONFIG
  phase6_require_variable BUILD_NUMBER
  [[ -r "$KUBECONFIG" ]] || phase6_fail 'KUBECONFIG is not readable'

  context="$(kubectl --kubeconfig "$KUBECONFIG" config current-context)"
  [[ "$context" == 'jenkins-deployer@devops-platform' ]] \
    || phase6_fail "unexpected kubeconfig context: $context"
  namespace="$(kubectl --kubeconfig "$KUBECONFIG" config view --minify \
    -o jsonpath='{..namespace}')"
  [[ "$namespace" == "$PHASE6_NAMESPACE" ]] \
    || phase6_fail "unexpected kubeconfig namespace: $namespace"

  [[ "$(helm status "$PHASE6_RELEASE" --kubeconfig "$KUBECONFIG" \
    --namespace "$PHASE6_NAMESPACE" -o json | jq -r '.info.status')" == 'deployed' ]] \
    || phase6_fail 'Helm release is not deployed'
  baseline_revision="$(helm history "$PHASE6_RELEASE" --kubeconfig "$KUBECONFIG" \
    --namespace "$PHASE6_NAMESPACE" -o json \
    | jq -r '[.[] | select(.status == "deployed")][-1].revision')"
  [[ "$baseline_revision" =~ ^[1-9][0-9]*$ ]] \
    || phase6_fail 'last deployed Helm revision is invalid'

  workloads_are_ready || phase6_fail 'application workloads are not Ready'
  baseline_frontend_image="$(current_frontend_image)"
  baseline_backend_image="$(current_backend_image)"
  for image in "$baseline_frontend_image" "$baseline_backend_image"; do
    image_tag="${image##*:}"
    [[ "$image_tag" =~ ^git-[0-9a-f]{12}$ ]] \
      || phase6_fail "baseline image tag is not immutable: $image"
  done

  pvc_record="$(pvc_identity)"
  [[ -n "$pvc_record" ]] || phase6_fail 'expected exactly one Bound MySQL PVC'
  IFS=$'\t' read -r baseline_pvc_name baseline_pvc_uid <<<"$pvc_record"
  application_is_healthy || phase6_fail 'application endpoints are not healthy'
  monitoring_is_healthy || phase6_fail 'monitoring Pods are not Ready'

  start_prometheus_access
  target_response="$(phase6_prometheus_query 'up{namespace="devops-platform",service="backend"} == 1')"
  jq -e '.status == "success" and (.data.result | length == 1)' \
    <<<"$target_response" >/dev/null \
    || phase6_fail 'backend Prometheus metric is not UP'
  backend_target_is_up || phase6_fail 'backend Prometheus Target is not UP'

  mkdir -p "$PHASE6_REPORT_DIR"
  {
    printf 'Phase 6 baseline\n'
    printf 'generated_at=%s\n' "$(date --iso-8601=seconds)"
    printf 'build_number=%s\n' "$BUILD_NUMBER"
    printf 'helm_revision=%s\n' "$baseline_revision"
    printf 'frontend_image=%s\n' "$baseline_frontend_image"
    printf 'backend_image=%s\n' "$baseline_backend_image"
    printf 'mysql_pvc_name=%s\n' "$baseline_pvc_name"
    printf 'mysql_pvc_uid=%s\n' "$baseline_pvc_uid"
    printf 'application_healthy=true\n'
    printf 'monitoring_healthy=true\n'
  } >"$PHASE6_REPORT_DIR/phase6-baseline.txt"
  phase6_log "baseline captured at Helm revision $baseline_revision"
}

recovery_is_verified() {
  local pvc_record pvc_name pvc_uid

  [[ "$(current_backend_image)" == "$baseline_backend_image" ]] || return 1
  [[ "$(current_frontend_image)" == "$baseline_frontend_image" ]] || return 1
  workloads_are_ready || return 1
  application_is_healthy || return 1
  monitoring_is_healthy || return 1

  pvc_record="$(pvc_identity)"
  [[ -n "$pvc_record" ]] || return 1
  IFS=$'\t' read -r pvc_name pvc_uid <<<"$pvc_record"
  [[ "$pvc_name" == "$baseline_pvc_name" && "$pvc_uid" == "$baseline_pvc_uid" ]] \
    || return 1
  [[ -z "$marker_id" ]] || phase6_item_exists "$marker_id" || return 1

  start_prometheus_access
  backend_target_is_up || return 1
}

# ShellCheck SC2329 is disabled because recovery_guard is invoked by traps.
# shellcheck disable=SC2329
recovery_guard() {
  local exit_status="$?"
  trap - EXIT INT TERM
  set +e

  cleanup_port_forward
  if [[ "$cluster_mutated" == true && "$drill_succeeded" != true ]]; then
    phase6_collect_diagnostics "$PHASE6_REPORT_DIR/phase6-recovery.txt"
    if ! recovery_is_verified; then
      phase6_log "automatic recovery incomplete; rolling back to revision $baseline_revision"
      helm rollback "$PHASE6_RELEASE" "$baseline_revision" \
        --kubeconfig "$KUBECONFIG" --namespace "$PHASE6_NAMESPACE" \
        --wait=watcher --timeout 5m \
        >>"$PHASE6_REPORT_DIR/phase6-recovery.txt" 2>&1
    fi
    if ! recovery_is_verified; then
      {
        printf 'result=RECOVERY_FAILURE\n'
        printf 'manual_rollback_revision=%s\n' "$baseline_revision"
      } >>"$PHASE6_REPORT_DIR/phase6-recovery.txt"
      exit_status=1
    fi
  fi

  cleanup_port_forward
  [[ -z "$temp_dir" ]] || rm -rf -- "$temp_dir"
  exit "$exit_status"
}

create_marker() {
  local payload response
  payload="$(jq -n \
    --arg title "$PHASE6_MARKER_TITLE" \
    --arg description 'Created before Phase 6 failed-release drill' \
    '{title: $title, description: $description, status: "pending"}')"
  response="$(phase6_api '/api/items' \
    --request POST --header 'Content-Type: application/json' --data "$payload")"
  marker_id="$(jq -r '.id' <<<"$response")"
  [[ "$marker_id" =~ ^[1-9][0-9]*$ ]] || phase6_fail 'marker task ID is invalid'
  phase6_log "persistence marker created with ID $marker_id"
}

complete_marker() {
  local payload response
  payload="$(jq -n \
    --arg title "$PHASE6_MARKER_TITLE" \
    --arg description 'Survived Phase 6 failed-release rollback' \
    '{title: $title, description: $description, status: "completed"}')"
  response="$(phase6_api "/api/items/$marker_id" \
    --request PUT --header 'Content-Type: application/json' --data "$payload")"
  jq -e --arg title "$PHASE6_MARKER_TITLE" '
      .title == $title
      and .description == "Survived Phase 6 failed-release rollback"
      and .status == "completed"
    ' <<<"$response" >/dev/null \
    || phase6_fail 'persistence marker did not reach completed state'
}

run_drill() {
  local failure_tag upgrade_status
  failure_tag="failure-drill-${BUILD_NUMBER}-does-not-exist"

  create_marker
  trap recovery_guard EXIT INT TERM
  cluster_mutated=true
  cleanup_port_forward

  set +e
  helm upgrade "$PHASE6_RELEASE" "$PHASE6_CHART" \
    --kubeconfig "$KUBECONFIG" --namespace "$PHASE6_NAMESPACE" \
    --reuse-values \
    --set-string images.backend.repository="$PHASE6_BACKEND_REPOSITORY" \
    --set-string images.backend.tag="$failure_tag" \
    --rollback-on-failure --wait=watcher --timeout 5m \
    >"$PHASE6_REPORT_DIR/phase6-failure.txt" 2>&1
  upgrade_status="$?"
  set -e

  [[ "$upgrade_status" -ne 0 ]] \
    || phase6_fail 'failure drill unexpectedly deployed the nonexistent image'
  phase6_collect_diagnostics "$PHASE6_REPORT_DIR/phase6-failure.txt"
  grep -Eqi 'ErrImagePull|ImagePullBackOff|failed to pull|not found|pull access denied' \
    "$PHASE6_REPORT_DIR/phase6-failure.txt" \
    "$PHASE6_REPORT_DIR/kubernetes-events.txt" \
    || phase6_fail 'expected image pull failure evidence was not captured'

  recovery_is_verified || phase6_fail 'automatic rollback did not restore the baseline'
  complete_marker
  phase6_item_exists "$marker_id" || phase6_fail 'persistence marker is missing after rollback'

  {
    printf 'Phase 6 recovery verification\n'
    printf 'generated_at=%s\n' "$(date --iso-8601=seconds)"
    printf 'result=EXPECTED_DRILL_FAILURE\n'
    printf 'rollback_verified=true\n'
    printf 'persistence_verified=true\n'
    printf 'monitoring_verified=true\n'
    printf 'baseline_revision=%s\n' "$baseline_revision"
    printf 'marker_id=%s\n' "$marker_id"
  } >"$PHASE6_REPORT_DIR/phase6-recovery.txt"
  drill_succeeded=true
  phase6_log 'expected failed release was observed and recovery was verified'
}

usage() {
  printf 'Usage: %s --preflight|--run\n' "$0" >&2
  exit 2
}

[[ "$#" -eq 1 ]] || usage
cd "$REPO_ROOT"
mkdir -p "$PHASE6_REPORT_DIR"
temp_dir="$(mktemp -d /tmp/devops-phase6.XXXXXX)"

case "$1" in
  --preflight)
    trap recovery_guard EXIT INT TERM
    capture_baseline
    phase6_log 'preflight passed; no cluster change was made'
    ;;
  --run)
    capture_baseline
    run_drill
    ;;
  *) usage ;;
esac
