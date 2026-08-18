#!/usr/bin/env bash

set -Eeuo pipefail

failures=0

pass() {
  printf '[PASS] %s\n' "$1"
}

fail() {
  printf '[FAIL] %s\n' "$1" >&2
  failures=$((failures + 1))
}

required_commands=(
  curl
  docker
  git
  python3
  pip3
  jq
  make
  shellcheck
  kubectl
  helm
  k3d
)

for command_name in "${required_commands[@]}"; do
  if command -v "$command_name" >/dev/null 2>&1; then
    pass "$command_name is available"
  else
    fail "$command_name is missing"
  fi
done

if docker info >/dev/null 2>&1; then
  pass "Docker daemon is reachable"
else
  fail "Docker daemon is not reachable; start Docker Desktop"
fi

if compose_version="$(docker compose version --short 2>/dev/null)"; then
  pass "Docker Compose ${compose_version} is available"
else
  fail "Docker Compose is unavailable"
fi

if kubectl_version="$(kubectl version --client --output=json 2>/dev/null | jq -r '.clientVersion.gitVersion')" \
  && [[ "$kubectl_version" == v1.36.* ]]; then
  pass "kubectl ${kubectl_version} matches the v1.36 cluster family"
else
  fail "kubectl must be v1.36.x"
fi

if helm_version="$(helm version --short 2>/dev/null)" \
  && [[ "$helm_version" == v4.2.* ]]; then
  pass "Helm ${helm_version} matches the v4.2 family"
else
  fail "Helm must be v4.2.x"
fi

if k3d_version="$(k3d version 2>/dev/null | awk '/^k3d version/ { print $3 }')" \
  && [[ "$k3d_version" == v5.9.* ]]; then
  pass "k3d ${k3d_version} matches the v5.9 family"
else
  fail "k3d must be v5.9.x"
fi

if ((failures > 0)); then
  printf '\nPrerequisite check failed with %d problem(s).\n' "$failures" >&2
  exit 1
fi

printf '\nAll DevOps project prerequisites passed.\n'
