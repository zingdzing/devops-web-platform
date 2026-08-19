#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
readonly REPO_ROOT

# shellcheck source=scripts/ci/common.sh
source "$SCRIPT_DIR/common.sh"

cd "$REPO_ROOT"
ci_require_command git
ci_require_command docker
ci_require_variable IMAGE_TAG
ci_validate_image_tag "$IMAGE_TAG"

GIT_COMMIT_FULL="${GIT_COMMIT_FULL:-$(git rev-parse HEAD)}"
readonly GIT_COMMIT_FULL
[[ "$GIT_COMMIT_FULL" =~ ^[0-9a-f]{40}$ ]] \
  || ci_fail 'GIT_COMMIT_FULL must be a 40-character lowercase Git SHA'
[[ "${IMAGE_TAG#git-}" == "${GIT_COMMIT_FULL:0:12}" ]] \
  || ci_fail 'IMAGE_TAG does not match GIT_COMMIT_FULL'

docker info >/dev/null 2>&1 || ci_fail 'Docker Engine is unavailable'
mkdir -p reports

readonly SOURCE_URL='https://github.com/zingdzing/devops-web-platform'
readonly BUILD_LABEL="${BUILD_NUMBER:-local}"
readonly FRONTEND_IMAGE="$CI_FRONTEND_REPOSITORY:$IMAGE_TAG"
readonly BACKEND_IMAGE="$CI_BACKEND_REPOSITORY:$IMAGE_TAG"

ci_log "Building frontend image $FRONTEND_IMAGE"
docker build \
  --label "org.opencontainers.image.source=$SOURCE_URL" \
  --label "org.opencontainers.image.revision=$GIT_COMMIT_FULL" \
  --label "io.jenkins.build.number=$BUILD_LABEL" \
  --tag "$FRONTEND_IMAGE" \
  app/frontend

ci_log "Building backend image $BACKEND_IMAGE"
docker build \
  --label "org.opencontainers.image.source=$SOURCE_URL" \
  --label "org.opencontainers.image.revision=$GIT_COMMIT_FULL" \
  --label "io.jenkins.build.number=$BUILD_LABEL" \
  --tag "$BACKEND_IMAGE" \
  app/backend

{
  printf 'image=%s id=%s revision=%s\n' \
    "$FRONTEND_IMAGE" \
    "$(docker image inspect --format '{{.Id}}' "$FRONTEND_IMAGE")" \
    "$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$FRONTEND_IMAGE")"
  printf 'image=%s id=%s revision=%s\n' \
    "$BACKEND_IMAGE" \
    "$(docker image inspect --format '{{.Id}}' "$BACKEND_IMAGE")" \
    "$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$BACKEND_IMAGE")"
} >reports/images.txt

ci_log 'Image metadata written to reports/images.txt'
