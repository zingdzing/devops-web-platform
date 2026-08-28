#!/usr/bin/env bash

set -Eeuo pipefail

fail() {
  printf '[phase6-contract] ERROR: %s\n' "$1" >&2
  exit 1
}

readonly PHASE6_DIR='scripts/phase6'
readonly DRILL_SCRIPT="$PHASE6_DIR/failure-drill.sh"
readonly COMMON_SCRIPT="$PHASE6_DIR/common.sh"
readonly VERIFY_SCRIPT='scripts/verify-phase6.sh'
readonly JENKINS_RBAC='deploy/kubernetes/jenkins-rbac.yaml'
readonly KUBECONFIG_SCRIPT='scripts/create-phase4-kubeconfig.sh'

for file in "$COMMON_SCRIPT" "$DRILL_SCRIPT" "$VERIFY_SCRIPT"; do
  [[ -f "$file" ]] || fail "$file is missing"
  grep -Fq 'set -Eeuo pipefail' "$file" \
    || fail "$file must use strict Bash mode"
done

grep -Fq 'phase6-contract:' Makefile \
  || fail 'Makefile phase6-contract target is missing'
grep -Fq 'phase6-verify:' Makefile \
  || fail 'Makefile phase6-verify target is missing'

grep -Fq 'name: jenkins-monitoring-observer' "$JENKINS_RBAC" \
  || fail 'monitoring observer Role is missing'
grep -Fq 'resources: ["pods/portforward"]' "$JENKINS_RBAC" \
  || fail 'monitoring observer cannot create a temporary port-forward'
grep -Fq 'Jenkins identity unexpectedly reads monitoring Secrets' \
  "$KUBECONFIG_SCRIPT" \
  || fail 'monitoring Secret denial check is missing'

for required_text in \
  'failure-drill-${BUILD_NUMBER}-does-not-exist' \
  '--rollback-on-failure' \
  '--wait=watcher' \
  '--timeout 5m' \
  'trap recovery_guard EXIT INT TERM' \
  'EXPECTED_DRILL_FAILURE' \
  'RECOVERY_FAILURE' \
  'phase6-baseline.txt' \
  'phase6-failure.txt' \
  'phase6-recovery.txt'; do
  grep -Fq -- "$required_text" "$DRILL_SCRIPT" \
    || fail "failure drill contract is missing: $required_text"
done

if grep -Ev '^[[:space:]]*#' "$PHASE6_DIR"/*.sh \
  | grep -Eq 'kubectl[[:space:]]+delete[[:space:]]+(namespace|pvc|persistentvolumeclaim|secret)|helm[[:space:]]+uninstall|docker[[:space:]]+(system|image)[[:space:]]+prune'; then
  fail 'Phase 6 scripts contain a forbidden destructive command'
fi

printf '[phase6-contract] Phase 6 file boundary passed\n'
