#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
readonly REPO_ROOT

# shellcheck source=scripts/ci/common.sh
source "$SCRIPT_DIR/common.sh"

cd "$REPO_ROOT"
ci_require_command python3

if [[ -e '.venv-ci' ]]; then
  ci_log 'Removing the previous isolated CI virtual environment'
  rm -r -- '.venv-ci'
fi

ci_log 'Creating an isolated CI virtual environment'
python3 -m venv '.venv-ci'

ci_log 'Installing pinned application and test dependencies'
PIP_DISABLE_PIP_VERSION_CHECK=1 .venv-ci/bin/python -m pip install \
  --requirement app/backend/requirements-dev.txt

mkdir -p reports
ci_log 'Running backend unit tests and writing reports/pytest.xml'
.venv-ci/bin/python -m pytest app/backend/tests -v \
  --junitxml=reports/pytest.xml
