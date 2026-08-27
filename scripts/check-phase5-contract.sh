#!/usr/bin/env bash

set -Eeuo pipefail

readonly CHART_DIR='deploy/helm/devops-web-platform'
readonly MONITORING_VALUES='deploy/monitoring/kube-prometheus-stack-values.yaml'
readonly MONITORING_CHART='prometheus-community/kube-prometheus-stack'
readonly MONITORING_CHART_VERSION='87.21.0'
readonly JENKINS_RBAC='deploy/kubernetes/jenkins-rbac.yaml'
readonly CI_DEPLOY='scripts/ci/deploy.sh'
readonly CI_QUALITY='scripts/ci/quality-check.sh'

fail() {
  printf '[phase5-contract] ERROR: %s\n' "$1" >&2
  exit 1
}

log() {
  printf '[phase5-contract] %s\n' "$1"
}

for command_name in helm grep jq mktemp; do
  command -v "$command_name" >/dev/null 2>&1 || fail "$command_name is missing"
done

grep -Fq 'apiGroups: ["monitoring.coreos.com"]' "$JENKINS_RBAC" \
  || fail 'Jenkins Role is missing the monitoring.coreos.com API group'
grep -Fq 'resources: ["servicemonitors", "prometheusrules"]' "$JENKINS_RBAC" \
  || fail 'Jenkins Role is missing namespaced monitoring resources'
grep -Fq -- '--set monitoring.enabled=true' "$CI_DEPLOY" \
  || fail 'Jenkins deployment does not enable application monitoring resources'
grep -Fq 'make phase5-contract' "$CI_QUALITY" \
  || fail 'Jenkins quality gate does not run the Phase 5 contract'

tmp_dir="$(mktemp -d /tmp/devops-phase5-contract.XXXXXX)"
cleanup() {
  rm -rf -- "$tmp_dir"
}
trap cleanup EXIT

readonly monitoring_off="$tmp_dir/monitoring-off.yaml"
readonly monitoring_on="$tmp_dir/monitoring-on.yaml"
readonly monitoring_stack="$tmp_dir/monitoring-stack.yaml"

log 'rendering application chart with monitoring disabled and enabled'
helm lint "$CHART_DIR" >/dev/null
helm template devops-platform "$CHART_DIR" --namespace devops-platform \
  >"$monitoring_off"
helm template devops-platform "$CHART_DIR" --namespace devops-platform \
  --set monitoring.enabled=true >"$monitoring_on"

if grep -Fq 'monitoring.coreos.com/' "$monitoring_off"; then
  fail 'monitoring CRs render while monitoring.enabled is false'
fi

grep -Fq 'kind: ServiceMonitor' "$monitoring_on" \
  || fail 'ServiceMonitor is missing while monitoring.enabled is true'
grep -Fq 'release: "kube-prometheus-stack"' "$monitoring_on" \
  || fail 'ServiceMonitor release selector label is missing'
grep -Fq 'app.kubernetes.io/component: backend' "$monitoring_on" \
  || fail 'ServiceMonitor backend selector is missing'
grep -Fq 'port: http' "$monitoring_on" \
  || fail 'ServiceMonitor does not use the named http port'
grep -Fq 'path: /metrics' "$monitoring_on" \
  || fail 'ServiceMonitor metrics path is missing'
grep -Fq 'interval: 30s' "$monitoring_on" \
  || fail 'ServiceMonitor scrape interval is not 30s'

for alert_name in \
  BackendTargetMissing \
  DeploymentReplicasUnavailable \
  ContainerRestartingFrequently; do
  grep -Fq "alert: $alert_name" "$monitoring_on" \
    || fail "PrometheusRule alert $alert_name is missing"
done

[[ -f "$CHART_DIR/files/devops-web-platform-overview.json" ]] \
  || fail 'Grafana dashboard JSON is missing'
jq empty "$CHART_DIR/files/devops-web-platform-overview.json" \
  || fail 'Grafana dashboard JSON is invalid'
grep -Fq 'kind: ConfigMap' "$monitoring_on" \
  || fail 'Grafana dashboard ConfigMap is missing'
grep -Fq 'grafana_dashboard: "1"' "$monitoring_on" \
  || fail 'Grafana sidecar discovery label is missing'

for panel_title in \
  'Backend Target Status' \
  'Requests per Second' \
  'HTTP 5xx Error Rate' \
  'HTTP P95 Latency' \
  'Deployment Replicas' \
  'Pod Ready Status' \
  'Container Restarts' \
  'Pod CPU Usage' \
  'Pod Memory Working Set'; do
  jq --exit-status --arg title "$panel_title" \
    '.panels[] | select(.title == $title)' \
    "$CHART_DIR/files/devops-web-platform-overview.json" >/dev/null \
    || fail "Grafana panel $panel_title is missing"
done

[[ -f "$MONITORING_VALUES" ]] \
  || fail 'trimmed kube-prometheus-stack values are missing'
[[ -f scripts/create-phase5-grafana-secret.sh ]] \
  || fail 'Grafana Secret creation script is missing'
[[ -f scripts/install-phase5-monitoring.sh ]] \
  || fail 'monitoring stack installation script is missing'

grep -Fq "readonly CHART_VERSION='$MONITORING_CHART_VERSION'" \
  scripts/install-phase5-monitoring.sh \
  || fail 'monitoring installer does not pin chart version 87.21.0'
grep -Fq 'existingSecret: grafana-admin' "$MONITORING_VALUES" \
  || fail 'Grafana does not use the external admin Secret'
grep -Fq 'defaultDashboardsEnabled: false' "$MONITORING_VALUES" \
  || fail 'upstream default dashboards are not disabled'
grep -Fq 'retention: 2d' "$MONITORING_VALUES" \
  || fail 'Prometheus retention is not trimmed to two days'
grep -Fq 'storage: 2Gi' "$MONITORING_VALUES" \
  || fail 'Prometheus persistent storage is not limited to 2Gi'

log 'rendering pinned trimmed kube-prometheus-stack chart'
helm template kube-prometheus-stack "$MONITORING_CHART" \
  --version "$MONITORING_CHART_VERSION" \
  --namespace monitoring \
  --values "$MONITORING_VALUES" >"$monitoring_stack"

grep -Fq 'kind: Prometheus' "$monitoring_stack" \
  || fail 'trimmed stack does not render Prometheus'
grep -Fq 'kind: Alertmanager' "$monitoring_stack" \
  || fail 'trimmed stack does not render Alertmanager'
grep -Fq 'kind: Deployment' "$monitoring_stack" \
  || fail 'trimmed stack does not render its controllers'
if grep -Eq '^kind: (Ingress|Gateway)$|type: (NodePort|LoadBalancer)' "$monitoring_stack"; then
  fail 'monitoring stack exposes a public ingress or external service'
fi
if awk '
  /^---$/ { in_secret = 0 }
  /^kind: Secret$/ { in_secret = 1; next }
  in_secret && /^[[:space:]]+name: grafana-admin$/ { found = 1 }
  END { exit(found ? 0 : 1) }
' "$monitoring_stack"; then
  fail 'Grafana admin credential Secret must be created interactively, not rendered by Helm'
fi

log 'Phase 5 application monitoring contract passed'
