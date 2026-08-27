#!/usr/bin/env bash

set -Eeuo pipefail

readonly EXPECTED_CONTEXT='k3d-devops-platform'
readonly NAMESPACE='monitoring'

fail() {
  printf '[phase5-access] ERROR: %s\n' "$1" >&2
  exit 1
}

component="${1:-}"
case "$component" in
  prometheus) local_port=9090; remote_port=9090; service='kube-prometheus-stack-prometheus'; selector='app.kubernetes.io/name=prometheus' ;;
  grafana) local_port=3000; remote_port=80; service='kube-prometheus-stack-grafana'; selector='app.kubernetes.io/name=grafana' ;;
  alertmanager) local_port=9093; remote_port=9093; service='kube-prometheus-stack-alertmanager'; selector='app.kubernetes.io/name=alertmanager' ;;
  *) fail 'usage: phase5-port-forward.sh prometheus|grafana|alertmanager' ;;
esac

command -v kubectl >/dev/null 2>&1 || fail 'kubectl is missing'
current_context="$(kubectl config current-context)"
[[ "$current_context" == "$EXPECTED_CONTEXT" ]] \
  || fail "expected context $EXPECTED_CONTEXT, got $current_context"

kubectl wait pod --context "$EXPECTED_CONTEXT" --namespace "$NAMESPACE" \
  --selector "$selector" --for=condition=Ready --timeout=60s >/dev/null

printf '[phase5-access] %s is available at http://127.0.0.1:%s; press Ctrl+C to stop.\n' \
  "$component" "$local_port"
exec kubectl --context "$EXPECTED_CONTEXT" --namespace "$NAMESPACE" port-forward \
  --address 127.0.0.1 "service/$service" "$local_port:$remote_port"
