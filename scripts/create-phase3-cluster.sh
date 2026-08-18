#!/usr/bin/env bash

set -Eeuo pipefail

readonly CLUSTER_NAME='devops-platform'
readonly CLUSTER_CONTEXT='k3d-devops-platform'
readonly CLUSTER_CONFIG='deploy/k3d/cluster.yaml'
readonly NIC_NAMESPACE='nginx-ingress'
readonly NIC_RELEASE='nginx-ingress'
readonly NIC_CHART='oci://ghcr.io/nginx/charts/nginx-ingress'
readonly NIC_CHART_VERSION='2.6.4'

fail() {
  printf '[phase3-cluster] ERROR: %s\n' "$1" >&2
  exit 1
}

log() {
  printf '[phase3-cluster] %s\n' "$1"
}

for command_name in docker jq k3d kubectl helm; do
  command -v "$command_name" >/dev/null 2>&1 || fail "$command_name is missing"
done
docker info >/dev/null 2>&1 || fail 'Docker Desktop is not reachable'
[[ -f "$CLUSTER_CONFIG" ]] || fail "$CLUSTER_CONFIG is missing"

if k3d cluster list -o json | jq -e --arg name "$CLUSTER_NAME" '.[] | select(.name == $name)' >/dev/null; then
  log 'starting the existing cluster'
  k3d cluster start "$CLUSTER_NAME"
else
  if docker ps --format '{{.Names}} {{.Ports}}' | grep -Fq '127.0.0.1:8080->'; then
    fail '127.0.0.1:8080 is already published; stop Phase 2 with make phase2-down'
  fi
  log 'creating the pinned cluster'
  k3d cluster create --config "$CLUSTER_CONFIG"
fi

kubectl config use-context "$CLUSTER_CONTEXT" >/dev/null
kubectl wait --for=condition=Ready node --all --timeout=180s
if kubectl --namespace kube-system get deployment traefik >/dev/null 2>&1; then
  fail 'Traefik is present although the cluster config disables it'
fi

helm upgrade --install "$NIC_RELEASE" "$NIC_CHART" \
  --namespace "$NIC_NAMESPACE" \
  --create-namespace \
  --version "$NIC_CHART_VERSION" \
  --skip-crds \
  --set controller.enableCustomResources=false \
  --set controller.appprotect.enable=false \
  --set controller.appprotectdos.enable=false \
  --set controller.service.type=LoadBalancer \
  --rollback-on-failure --wait=watcher --timeout 5m

kubectl --namespace "$NIC_NAMESPACE" wait \
  --for=condition=Available deployment --all --timeout=180s
[[ "$(kubectl get ingressclass nginx -o jsonpath='{.spec.controller}')" == 'nginx.org/ingress-controller' ]] \
  || fail 'IngressClass nginx is not owned by the F5 controller'
log 'cluster and ingress controller are ready'
