#!/usr/bin/env bash

set -Eeuo pipefail

readonly CI_NAMESPACE='devops-platform'
readonly CI_RELEASE='devops-platform'
readonly CI_CHART_DIR='deploy/helm/devops-web-platform'
readonly CI_FRONTEND_DEPLOYMENT='devops-platform-devops-web-platform-frontend'
readonly CI_BACKEND_DEPLOYMENT='devops-platform-devops-web-platform-backend'
readonly CI_MYSQL_STATEFULSET='devops-platform-devops-web-platform-mysql'
readonly CI_DATABASE_SECRET='devops-platform-db'
readonly CI_FRONTEND_REPOSITORY='zingzin/devops-web-platform-frontend'
readonly CI_BACKEND_REPOSITORY='zingzin/devops-web-platform-backend'

export CI_NAMESPACE CI_RELEASE CI_CHART_DIR
export CI_FRONTEND_DEPLOYMENT CI_BACKEND_DEPLOYMENT CI_MYSQL_STATEFULSET
export CI_DATABASE_SECRET CI_FRONTEND_REPOSITORY CI_BACKEND_REPOSITORY

ci_fail() {
  printf '[phase4-ci] ERROR: %s\n' "$1" >&2
  exit 1
}

ci_log() {
  printf '[phase4-ci] %s\n' "$1"
}

ci_require_command() {
  command -v "$1" >/dev/null 2>&1 || ci_fail "$1 is missing"
}

ci_require_variable() {
  [[ -n "${!1:-}" ]] || ci_fail "$1 is empty"
}

ci_validate_image_tag() {
  [[ "$1" =~ ^git-[0-9a-f]{12}$ ]] \
    || ci_fail 'IMAGE_TAG must match git-<12 lowercase hex>'
}
