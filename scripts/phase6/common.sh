#!/usr/bin/env bash

set -Eeuo pipefail

readonly PHASE6_NAMESPACE='devops-platform'
readonly PHASE6_RELEASE='devops-platform'
# Consumed by scripts that source this library.
# shellcheck disable=SC2034
readonly PHASE6_CHART='deploy/helm/devops-web-platform'
readonly PHASE6_BACKEND_DEPLOYMENT='devops-platform-devops-web-platform-backend'
readonly PHASE6_FRONTEND_DEPLOYMENT='devops-platform-devops-web-platform-frontend'
# shellcheck disable=SC2034
readonly PHASE6_MYSQL_STATEFULSET='devops-platform-devops-web-platform-mysql'
# shellcheck disable=SC2034
readonly PHASE6_BACKEND_REPOSITORY='zingzin/devops-web-platform-backend'
readonly PHASE6_APPLICATION_URL="${PHASE6_APPLICATION_URL:-http://host.docker.internal:8080}"
# shellcheck disable=SC2034
readonly PHASE6_MONITORING_NAMESPACE='monitoring'
# shellcheck disable=SC2034
readonly PHASE6_PROMETHEUS_SERVICE='kube-prometheus-stack-prometheus'
readonly PHASE6_PROMETHEUS_PORT="${PHASE6_PROMETHEUS_PORT:-29090}"
# shellcheck disable=SC2034
readonly PHASE6_MARKER_TITLE='Phase 6 rollback persistence'
readonly PHASE6_REPORT_DIR="${PHASE6_REPORT_DIR:-reports}"

phase6_log() {
  printf '[phase6] %s\n' "$1"
}

phase6_fail() {
  printf '[phase6] ERROR: %s\n' "$1" >&2
  exit 1
}

phase6_require_command() {
  command -v "$1" >/dev/null 2>&1 || phase6_fail "$1 is missing"
}

phase6_require_variable() {
  [[ -n "${!1:-}" ]] || phase6_fail "$1 is empty"
}

phase6_api() {
  local path="$1"
  shift
  curl --fail --silent --show-error \
    --connect-timeout 3 --max-time 10 \
    --header 'Host: localhost' \
    "$@" "${PHASE6_APPLICATION_URL}${path}"
}

phase6_prometheus_query() {
  local query="$1"
  curl --fail --silent --show-error --get \
    "http://127.0.0.1:${PHASE6_PROMETHEUS_PORT}/api/v1/query" \
    --data-urlencode "query=$query"
}

phase6_item_exists() {
  local item_id="$1"
  phase6_api '/api/items' \
    | jq -e --argjson item_id "$item_id" \
      'any(.[]; .id == $item_id)' >/dev/null
}

phase6_collect_diagnostics() {
  local report_file="$1"

  mkdir -p "$PHASE6_REPORT_DIR"
  {
    printf 'Phase 6 secret-safe diagnostics\n'
    printf 'generated_at=%s\n' "$(date --iso-8601=seconds)"
    printf 'build_number=%s\n\n' "${BUILD_NUMBER:-unknown}"
    printf '%s\n' '--- helm status ---'
    helm status "$PHASE6_RELEASE" --kubeconfig "$KUBECONFIG" \
      --namespace "$PHASE6_NAMESPACE" 2>&1 || true
    printf '%s\n' '--- deployments, replicasets, statefulsets and pods ---'
    kubectl --kubeconfig "$KUBECONFIG" --namespace "$PHASE6_NAMESPACE" \
      get deployments,replicasets,statefulsets,pods,persistentvolumeclaims \
      --output wide 2>&1 || true
    printf '%s\n' '--- workload descriptions ---'
    kubectl --kubeconfig "$KUBECONFIG" --namespace "$PHASE6_NAMESPACE" \
      describe deployment "$PHASE6_BACKEND_DEPLOYMENT" 2>&1 || true
    kubectl --kubeconfig "$KUBECONFIG" --namespace "$PHASE6_NAMESPACE" \
      describe pods -l app.kubernetes.io/component=backend 2>&1 || true
  } >>"$report_file"

  helm history "$PHASE6_RELEASE" --kubeconfig "$KUBECONFIG" \
    --namespace "$PHASE6_NAMESPACE" \
    >"$PHASE6_REPORT_DIR/helm-history.txt" 2>&1 || true
  kubectl --kubeconfig "$KUBECONFIG" --namespace "$PHASE6_NAMESPACE" \
    get events --sort-by=.lastTimestamp \
    >"$PHASE6_REPORT_DIR/kubernetes-events.txt" 2>&1 || true
  kubectl --kubeconfig "$KUBECONFIG" --namespace "$PHASE6_NAMESPACE" \
    get deployments "$PHASE6_FRONTEND_DEPLOYMENT" "$PHASE6_BACKEND_DEPLOYMENT" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.spec.template.spec.containers[0].image}{"\n"}{end}' \
    >"$PHASE6_REPORT_DIR/images.txt" 2>&1 || true
}
