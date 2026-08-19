#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
readonly REPO_ROOT

# shellcheck source=scripts/ci/common.sh
source "$SCRIPT_DIR/common.sh"

cd "$REPO_ROOT"
mkdir -p reports
readonly REPORT_FILE='reports/kubernetes-diagnostics.txt'

{
  printf 'Phase 4 Kubernetes diagnostics\n'
  printf 'git_commit=%s\n' "$(git rev-parse HEAD 2>/dev/null || printf unknown)"
  printf 'build_number=%s\n' "${BUILD_NUMBER:-unknown}"
  printf 'image_tag=%s\n' "${IMAGE_TAG:-unknown}"
  printf 'generated_at=%s\n\n' "$(date --iso-8601=seconds)"

  if [[ -z "${KUBECONFIG:-}" || ! -r "$KUBECONFIG" ]]; then
    printf 'Kubernetes credential was unavailable; live diagnostics skipped.\n'
  else
    printf '%s\n' '--- helm status ---'
    helm status "$CI_RELEASE" --kubeconfig "$KUBECONFIG" \
      --namespace "$CI_NAMESPACE" 2>&1 || true
    printf '%s\n' '--- workload and network resources ---'
    kubectl --kubeconfig "$KUBECONFIG" get \
      deployment,statefulset,pod,service,ingress,persistentvolumeclaim \
      --namespace "$CI_NAMESPACE" --output wide 2>&1 || true
    printf '%s\n' '--- recent events ---'
    kubectl --kubeconfig "$KUBECONFIG" get events \
      --namespace "$CI_NAMESPACE" --sort-by=.lastTimestamp 2>&1 | tail -n 80 || true
    printf '%s\n' '--- frontend logs (tail 100) ---'
    kubectl --kubeconfig "$KUBECONFIG" logs \
      "deployment/$CI_FRONTEND_DEPLOYMENT" --namespace "$CI_NAMESPACE" \
      --tail=100 2>&1 || true
    printf '%s\n' '--- backend logs (tail 100) ---'
    kubectl --kubeconfig "$KUBECONFIG" logs \
      "deployment/$CI_BACKEND_DEPLOYMENT" --namespace "$CI_NAMESPACE" \
      --tail=100 2>&1 || true
  fi
} >"$REPORT_FILE"

ci_log "Secret-safe diagnostics written to $REPORT_FILE"
exit 0
