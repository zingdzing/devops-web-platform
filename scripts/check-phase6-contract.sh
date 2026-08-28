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

for file in "$COMMON_SCRIPT" "$DRILL_SCRIPT" "$VERIFY_SCRIPT"; do
  [[ -f "$file" ]] || fail "$file is missing"
  grep -Fq 'set -Eeuo pipefail' "$file" \
    || fail "$file must use strict Bash mode"
done

grep -Fq 'phase6-contract:' Makefile \
  || fail 'Makefile phase6-contract target is missing'
grep -Fq 'phase6-verify:' Makefile \
  || fail 'Makefile phase6-verify target is missing'

printf '[phase6-contract] Phase 6 file boundary passed\n'
