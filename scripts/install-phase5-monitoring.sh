#!/usr/bin/env bash

set -Eeuo pipefail

readonly EXPECTED_CONTEXT='k3d-devops-platform'
readonly NAMESPACE='monitoring'
readonly RELEASE='kube-prometheus-stack'
readonly CHART='prometheus-community/kube-prometheus-stack'
readonly CHART_VERSION='87.21.0'
readonly VALUES_FILE='deploy/monitoring/kube-prometheus-stack-values.yaml'

fail() {
  printf '[phase5-install] ERROR: %s\n' "$1" >&2
  exit 1
}

diagnostics() {
  exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    printf '[phase5-install] Installation failed; preserving resources and collecting status.\n' >&2
    kubectl get pods,pvc -n "$NAMESPACE" -o wide >&2 || true
    kubectl get events -n "$NAMESPACE" --sort-by=.lastTimestamp >&2 || true
  fi
  exit "$exit_code"
}
trap diagnostics EXIT

for command_name in helm kubectl grep; do
  command -v "$command_name" >/dev/null 2>&1 || fail "$command_name is missing"
done

[[ -f "$VALUES_FILE" ]] || fail "$VALUES_FILE is missing"
current_context="$(kubectl config current-context)"
[[ "$current_context" == "$EXPECTED_CONTEXT" ]] \
  || fail "expected context $EXPECTED_CONTEXT, got $current_context"
kubectl get secret grafana-admin -n "$NAMESPACE" >/dev/null 2>&1 \
  || fail 'monitoring/grafana-admin is missing; run make phase5-grafana-secret first'

helm repo add prometheus-community \
  https://prometheus-community.github.io/helm-charts --force-update >/dev/null
helm repo update prometheus-community >/dev/null

printf '[phase5-install] Installing pinned chart %s with local trimmed values.\n' \
  "$CHART_VERSION"
helm upgrade --install "$RELEASE" "$CHART" \
  --version "$CHART_VERSION" \
  --namespace "$NAMESPACE" \
  --create-namespace \
  --values "$VALUES_FILE" \
  --wait \
  --timeout 12m

while IFS= read -r workload; do
  [[ -n "$workload" ]] || continue
  kubectl rollout status -n "$NAMESPACE" "$workload" --timeout=5m
done < <(kubectl get deployment,statefulset -n "$NAMESPACE" \
  -l app.kubernetes.io/instance="$RELEASE" -o name)

kubectl wait pvc -n "$NAMESPACE" --all \
  --for=jsonpath='{.status.phase}'=Bound --timeout=5m
kubectl get pods,pvc -n "$NAMESPACE"
printf '[phase5-install] Monitoring stack is ready.\n'
