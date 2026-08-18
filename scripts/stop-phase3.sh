#!/usr/bin/env bash

set -Eeuo pipefail

readonly CLUSTER_NAME='devops-platform'

fail() {
  printf '[phase3-stop] ERROR: %s\n' "$1" >&2
  exit 1
}

for command_name in k3d jq; do
  command -v "$command_name" >/dev/null 2>&1 || fail "$command_name is missing"
done

if k3d cluster list -o json | jq -e --arg name "$CLUSTER_NAME" '.[] | select(.name == $name)' >/dev/null; then
  k3d cluster stop "$CLUSTER_NAME"
  printf '[phase3-stop] Cluster stopped; the cluster definition and PVC data were preserved.\n'
else
  printf '[phase3-stop] Cluster does not exist; nothing was changed.\n'
fi
