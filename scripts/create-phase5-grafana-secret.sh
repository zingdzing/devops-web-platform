#!/usr/bin/env bash

set -Eeuo pipefail

readonly EXPECTED_CONTEXT='k3d-devops-platform'
readonly NAMESPACE='monitoring'
readonly SECRET_NAME='grafana-admin'

fail() {
  printf '[phase5-secret] ERROR: %s\n' "$1" >&2
  exit 1
}

for command_name in kubectl mktemp; do
  command -v "$command_name" >/dev/null 2>&1 || fail "$command_name is missing"
done

current_context="$(kubectl config current-context)"
[[ "$current_context" == "$EXPECTED_CONTEXT" ]] \
  || fail "expected context $EXPECTED_CONTEXT, got $current_context"

read -r -s -p 'Grafana admin password (at least 12 characters): ' password
printf '\n'
read -r -s -p 'Repeat Grafana admin password: ' password_repeat
printf '\n'

[[ ${#password} -ge 12 ]] || fail 'password must contain at least 12 characters'
[[ "$password" == "$password_repeat" ]] || fail 'passwords do not match'

tmp_dir="$(mktemp -d /tmp/devops-phase5-grafana.XXXXXX)"
cleanup() {
  unset password password_repeat
  rm -rf -- "$tmp_dir"
}
trap cleanup EXIT
chmod 700 "$tmp_dir"
printf '%s' 'admin' >"$tmp_dir/admin-user"
printf '%s' "$password" >"$tmp_dir/admin-password"
chmod 600 "$tmp_dir/admin-user" "$tmp_dir/admin-password"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml \
  | kubectl apply -f - >/dev/null
kubectl create secret generic "$SECRET_NAME" \
  --namespace "$NAMESPACE" \
  --from-file=admin-user="$tmp_dir/admin-user" \
  --from-file=admin-password="$tmp_dir/admin-password" \
  --dry-run=client -o yaml \
  | kubectl apply -f - >/dev/null

printf '[phase5-secret] Secret %s/%s created or updated without printing its value.\n' \
  "$NAMESPACE" "$SECRET_NAME"
