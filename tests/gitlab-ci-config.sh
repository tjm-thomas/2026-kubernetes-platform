#!/usr/bin/env bash
# The platform pipeline file: every job is serialized per app+env (resource_group, like the
# GitHub workflows' concurrency groups), and every bash handoff clears BASH_ENV first
# (non-interactive bash expands BASH_ENV, command substitution included, so a caller-set
# variable would run code before ci/gitlab-job.sh starts).
set -uo pipefail
cd "$(dirname "$0")/.."
fail() { echo "FAIL: $1" >&2; exit 1; }

jobs=$(grep -c '^\S.*:$' .gitlab-ci.yml | cat)
rg=$(grep -c '^  resource_group:' .gitlab-ci.yml | cat)
be=$(grep -c 'BASH_ENV=\$null' .gitlab-ci.yml | cat)
[ "${rg}" = 3 ] || fail "expected resource_group on 3 jobs, found ${rg}"
[ "${be}" = 3 ] || fail "expected 3 script lines clearing BASH_ENV, found ${be}"
echo PASS
