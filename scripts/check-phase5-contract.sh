#!/usr/bin/env bash

set -Eeuo pipefail

readonly CHART_DIR='deploy/helm/devops-web-platform'

fail() {
  printf '[phase5-contract] ERROR: %s\n' "$1" >&2
  exit 1
}

log() {
  printf '[phase5-contract] %s\n' "$1"
}

for command_name in helm grep mktemp; do
  command -v "$command_name" >/dev/null 2>&1 || fail "$command_name is missing"
done

tmp_dir="$(mktemp -d /tmp/devops-phase5-contract.XXXXXX)"
cleanup() {
  rm -rf -- "$tmp_dir"
}
trap cleanup EXIT

readonly monitoring_off="$tmp_dir/monitoring-off.yaml"
readonly monitoring_on="$tmp_dir/monitoring-on.yaml"

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

log 'Phase 5 monitoring discovery contract passed'
