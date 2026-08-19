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

EXPECTED_REVISION="$(git rev-parse HEAD)"
readonly EXPECTED_REVISION
[[ "${IMAGE_TAG#git-}" == "${EXPECTED_REVISION:0:12}" ]] \
  || ci_fail 'IMAGE_TAG does not match the checked-out Git revision'

readonly FRONTEND_IMAGE="$CI_FRONTEND_REPOSITORY:$IMAGE_TAG"
readonly BACKEND_IMAGE="$CI_BACKEND_REPOSITORY:$IMAGE_TAG"

for image_name in "$FRONTEND_IMAGE" "$BACKEND_IMAGE"; do
  docker image inspect "$image_name" >/dev/null 2>&1 \
    || ci_fail "local image is missing: $image_name"
  actual_revision="$(docker image inspect --format \
    '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$image_name")"
  [[ "$actual_revision" == "$EXPECTED_REVISION" ]] \
    || ci_fail "revision label mismatch for $image_name"

  runtime_uid="$(docker run --rm --entrypoint id "$image_name" -u)"
  [[ "$runtime_uid" =~ ^[0-9]+$ && "$runtime_uid" != '0' ]] \
    || ci_fail "image runs as root: $image_name"
done

ci_log 'Validating the frontend Nginx configuration'
docker run --rm --add-host backend:127.0.0.1 \
  --entrypoint nginx "$FRONTEND_IMAGE" -t

ci_log 'Validating the backend application import'
docker run --rm --entrypoint python "$BACKEND_IMAGE" \
  -c 'from app import create_app; assert create_app'

ci_log 'Confirming pytest is absent from the backend production image'
if docker run --rm --entrypoint python "$BACKEND_IMAGE" \
  -m pytest --version >/dev/null 2>&1; then
  ci_fail 'pytest must not be installed in the backend production image'
fi

ci_log 'Frontend and backend production image checks passed'
