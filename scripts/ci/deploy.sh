#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
readonly REPO_ROOT

# shellcheck source=scripts/ci/common.sh
source "$SCRIPT_DIR/common.sh"

cd "$REPO_ROOT"
for command_name in helm kubectl; do
  ci_require_command "$command_name"
done
ci_require_variable IMAGE_TAG
ci_require_variable KUBECONFIG
ci_validate_image_tag "$IMAGE_TAG"
[[ -r "$KUBECONFIG" ]] || ci_fail 'KUBECONFIG is not a readable file'

mode="${1:-deploy}"
[[ "$mode" == 'deploy' || "$mode" == '--verify-only' ]] \
  || ci_fail 'usage: deploy.sh [--verify-only]'

readonly EXPECTED_CONTEXT='jenkins-deployer@devops-platform'
current_context="$(kubectl --kubeconfig "$KUBECONFIG" config current-context)"
[[ "$current_context" == "$EXPECTED_CONTEXT" ]] \
  || ci_fail "kubeconfig context must be $EXPECTED_CONTEXT"

configured_namespace="$(kubectl --kubeconfig "$KUBECONFIG" config view \
  --minify --output 'jsonpath={.contexts[0].context.namespace}')"
[[ "$configured_namespace" == "$CI_NAMESPACE" ]] \
  || ci_fail "kubeconfig namespace must be $CI_NAMESPACE"
helm status "$CI_RELEASE" --kubeconfig "$KUBECONFIG" \
  --namespace "$CI_NAMESPACE" >/dev/null \
  || ci_fail "existing Helm release $CI_RELEASE was not found"
kubectl --kubeconfig "$KUBECONFIG" get secret "$CI_DATABASE_SECRET" \
  --namespace "$CI_NAMESPACE" --output name >/dev/null \
  || ci_fail "external database Secret $CI_DATABASE_SECRET was not found"

bound_pvc="$(kubectl --kubeconfig "$KUBECONFIG" get persistentvolumeclaims \
  --namespace "$CI_NAMESPACE" \
  --selector "app.kubernetes.io/instance=$CI_RELEASE,app.kubernetes.io/component=mysql" \
  --output 'jsonpath={range .items[?(@.status.phase=="Bound")]}{.metadata.name}{"\n"}{end}')"
[[ -n "$bound_pvc" ]] || ci_fail 'no Bound MySQL PVC was found'

if [[ "$mode" == 'deploy' ]]; then
  ci_log "Deploying $IMAGE_TAG with protected Helm image-only overrides"
  helm upgrade --install "$CI_RELEASE" "$CI_CHART_DIR" \
    --kubeconfig "$KUBECONFIG" --namespace "$CI_NAMESPACE" \
    --set-string images.frontend.repository="$CI_FRONTEND_REPOSITORY" \
    --set-string images.frontend.tag="$IMAGE_TAG" \
    --set-string images.backend.repository="$CI_BACKEND_REPOSITORY" \
    --set-string images.backend.tag="$IMAGE_TAG" \
    --rollback-on-failure --wait=watcher --timeout 5m
fi

kubectl --kubeconfig "$KUBECONFIG" rollout status \
  "deployment/$CI_FRONTEND_DEPLOYMENT" --namespace "$CI_NAMESPACE" --timeout=5m
kubectl --kubeconfig "$KUBECONFIG" rollout status \
  "deployment/$CI_BACKEND_DEPLOYMENT" --namespace "$CI_NAMESPACE" --timeout=5m

mysql_ready="$(kubectl --kubeconfig "$KUBECONFIG" get \
  "statefulset/$CI_MYSQL_STATEFULSET" --namespace "$CI_NAMESPACE" \
  --output 'jsonpath={.status.readyReplicas}')"
[[ "$mysql_ready" == '1' ]] || ci_fail 'MySQL StatefulSet does not have one ready replica'

verify_deployment_image() {
  local component="$1"
  local deployment="$2"
  local expected_image="$3"
  local deployment_image

  deployment_image="$(kubectl --kubeconfig "$KUBECONFIG" get \
    "deployment/$deployment" --namespace "$CI_NAMESPACE" \
    --output 'jsonpath={.spec.template.spec.containers[0].image}')"
  [[ "$deployment_image" == "$expected_image" ]] \
    || ci_fail "$component Deployment image is $deployment_image; expected $expected_image"
}

verify_deployment_image frontend "$CI_FRONTEND_DEPLOYMENT" \
  "$CI_FRONTEND_REPOSITORY:$IMAGE_TAG"
verify_deployment_image backend "$CI_BACKEND_DEPLOYMENT" \
  "$CI_BACKEND_REPOSITORY:$IMAGE_TAG"
ci_log 'Helm rollout and Deployment template image checks passed'
