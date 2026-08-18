#!/usr/bin/env bash

set -Eeuo pipefail

readonly CHART_DIR='deploy/helm/devops-web-platform'
readonly CANONICAL_SQL='app/database/init.sql'
readonly CHART_SQL='deploy/helm/devops-web-platform/files/init.sql'
rendered_file=''

fail() {
  printf '[phase3-manifests] ERROR: %s\n' "$1" >&2
  exit 1
}

log() {
  printf '[phase3-manifests] %s\n' "$1"
}

count_kind() {
  local kind="$1"
  awk -v expected="kind: ${kind}" '$0 == expected { count += 1 } END { print count + 0 }' "$rendered_file"
}

expect_kind_count() {
  local kind="$1"
  local expected="$2"
  local actual
  actual="$(count_kind "$kind")"
  [[ "$actual" == "$expected" ]] || fail "$kind count is $actual; expected $expected"
}

for command_name in helm git grep cmp mktemp awk; do
  command -v "$command_name" >/dev/null 2>&1 || fail "$command_name is missing"
done
[[ -f "$CANONICAL_SQL" ]] || fail "$CANONICAL_SQL is missing"
[[ -f "$CHART_SQL" ]] || fail "$CHART_SQL is missing"
[[ -f "$CHART_DIR/Chart.yaml" ]] || fail "$CHART_DIR/Chart.yaml is missing"

rendered_file="$(mktemp /tmp/devops-phase3-rendered.XXXXXX.yaml)"
cleanup() {
  rm -f -- "$rendered_file"
}
trap cleanup EXIT

log 'checking canonical SQL and Helm rendering'
cmp --silent "$CANONICAL_SQL" "$CHART_SQL" || fail 'Chart init.sql differs from app/database/init.sql'
helm lint "$CHART_DIR"
helm template devops-platform "$CHART_DIR" --namespace devops-platform >"$rendered_file"

expect_kind_count Deployment 2
expect_kind_count Service 3
expect_kind_count StatefulSet 1
expect_kind_count ConfigMap 2
expect_kind_count Ingress 1

grep -Fq 'ingressClassName: nginx' "$rendered_file" || fail 'IngressClass nginx is missing'
grep -Fq 'whenDeleted: Retain' "$rendered_file" || fail 'PVC deletion retention is missing'
grep -Fq 'whenScaled: Retain' "$rendered_file" || fail 'PVC scale retention is missing'
grep -Fq 'path: /healthz' "$rendered_file" || fail 'healthz probe or route is missing'
grep -Fq 'path: /readyz' "$rendered_file" || fail 'readyz probe or route is missing'

for expected_resource in 25m 100m 32Mi 64Mi 50m 250m 256Mi 500m 512Mi; do
  grep -Fq "$expected_resource" "$rendered_file" || fail "resource value $expected_resource is missing"
done

if grep -Eq 'type: (NodePort|LoadBalancer)|hostPort:|hostNetwork: true' "$rendered_file"; then
  fail 'application manifests expose a forbidden host or external Service port'
fi
if grep -Eq 'image:.*:latest|tag: latest|change-me-' "$rendered_file"; then
  fail 'rendered manifests contain latest or example credentials'
fi

if git ls-files | grep -Eq '(^|/)(\.env|kubeconfig([^/]*|/.*)|id_(rsa|ed25519)|.*\.(pem|key|p12|pfx)|.*secret.*\.ya?ml)$'; then
  fail 'Git tracks a forbidden secret-shaped file'
fi
if git grep -nEI '(ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|-----BEGIN (OPENSSH|RSA|EC) PRIVATE KEY-----)' -- .; then
  fail 'tracked content contains a token or private-key signature'
fi

log 'Phase 3 manifest checks passed'
