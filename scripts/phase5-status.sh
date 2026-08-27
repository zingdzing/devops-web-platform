#!/usr/bin/env bash

set -Eeuo pipefail

readonly CONTEXT='k3d-devops-platform'
readonly MONITORING_NAMESPACE='monitoring'
readonly APPLICATION_NAMESPACE='devops-platform'
readonly RELEASE='kube-prometheus-stack'

for command_name in helm jq kubectl; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf '[phase5-status] ERROR: %s is missing\n' "$command_name" >&2
    exit 1
  }
done

[[ "$(kubectl config current-context)" == "$CONTEXT" ]] || {
  printf '[phase5-status] ERROR: expected context %s\n' "$CONTEXT" >&2
  exit 1
}

printf '\n== Helm release ==\n'
helm status "$RELEASE" --namespace "$MONITORING_NAMESPACE" --output json \
  | jq -r '"name=\(.name) namespace=\(.namespace) status=\(.info.status) revision=\(.version)"'

printf '\n== Monitoring Pods and persistent volumes ==\n'
kubectl --context "$CONTEXT" --namespace "$MONITORING_NAMESPACE" \
  get pods,persistentvolumeclaims

printf '\n== Application monitoring discovery resources ==\n'
kubectl --context "$CONTEXT" --namespace "$APPLICATION_NAMESPACE" \
  get servicemonitors.monitoring.coreos.com,prometheusrules.monitoring.coreos.com

printf '\n== Application workloads ==\n'
kubectl --context "$CONTEXT" --namespace "$APPLICATION_NAMESPACE" \
  get deployments,statefulsets,services
