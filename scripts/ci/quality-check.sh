#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
readonly REPO_ROOT

# shellcheck source=scripts/ci/common.sh
source "$SCRIPT_DIR/common.sh"

cd "$REPO_ROOT"
for command_name in git bash shellcheck make cmp grep find sort; do
  ci_require_command "$command_name"
done

ci_log 'Checking whitespace and shell syntax'
git diff --check
mapfile -d '' shell_files < <(
  find scripts deploy/jenkins -type f -name '*.sh' -print0 | sort -z
)
[[ "${#shell_files[@]}" -gt 0 ]] || ci_fail 'no shell scripts were found'
bash -n "${shell_files[@]}"
shellcheck --severity=warning "${shell_files[@]}"

ci_log 'Checking Helm manifests and canonical database initialization SQL'
make phase3-manifests
cmp --silent app/database/init.sql "$CI_CHART_DIR/files/init.sql" \
  || ci_fail 'Helm init.sql differs from app/database/init.sql'

ci_log 'Checking tracked filenames and content for secret signatures'
if git ls-files | grep -Eq '(^|/)(\.env|kubeconfig([^/]*|/.*)|id_(rsa|ed25519)|.*\.(pem|key|p12|pfx)|.*secret.*\.ya?ml)$'; then
  ci_fail 'Git tracks a forbidden secret-shaped file'
fi
if git grep -nEI '(ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|-----BEGIN (OPENSSH|RSA|EC) PRIVATE KEY-----)' -- .; then
  ci_fail 'tracked content contains a token or private-key signature'
fi

ci_log 'Rejecting floating latest image tags from deployment and CI configuration'
floating_tag=':'
floating_tag+='latest'
search_paths=(deploy scripts/ci)
[[ -f Jenkinsfile ]] && search_paths+=(Jenkinsfile)
if grep -RInF -- "$floating_tag" "${search_paths[@]}"; then
  ci_fail 'deployment or CI configuration contains a floating latest image tag'
fi

ci_log 'Source and manifest quality checks passed'
