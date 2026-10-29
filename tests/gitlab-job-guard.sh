#!/usr/bin/env bash
# ci/gitlab-job.sh must only accept keys as the file PATHS GitLab writes for File-type
# variables. Content instead of a path (a plain variable) would reach kubectl, which echoes
# it into the public job log; a caller-supplied path (trigger variables override project
# variables) could point a key at any file on the runner. Runs offline except the last check,
# which needs the prod key file and stops at the reader-key guard.
set -uo pipefail
cd "$(dirname "$0")/.."
fail() { echo "FAIL: $1" >&2; exit 1; }

# 1. Key content instead of a path: refused, and the content is never echoed
out="$(ACTION=deploy APP=fe-main-user ENV=prod IMAGE=x:y \
  DEPLOYER_KUBECONFIG_FE_MAIN_USER=$'apiVersion: v1\nkind: Config\ntoken: LEAKCANARY' \
  bash ci/gitlab-job.sh 2>&1)" && fail "key content was accepted"
grep -q "must be a File-type variable" <<<"${out}" || fail "wrong refusal: ${out}"
grep -q LEAKCANARY <<<"${out}" && fail "the key content was echoed"

# 2. A real file outside GitLab's file-variable directory: refused when CI_PROJECT_DIR is set
tmp="$(mktemp)"; echo canary > "${tmp}"
out="$(CI_PROJECT_DIR=/c/builds/group/project ACTION=deploy APP=fe-main-user ENV=prod IMAGE=x:y \
  DEPLOYER_KUBECONFIG_FE_MAIN_USER="${tmp}" bash ci/gitlab-job.sh 2>&1)" \
  && { rm -f "${tmp}"; fail "a path outside the file-variable directory was accepted"; }
rm -f "${tmp}"
grep -q "must be a File-type variable" <<<"${out}" || fail "wrong refusal: ${out}"

# 3. The real file-variable location passes the guard (then stops at the reader-key check)
sim=/tmp/kanso-guard-test
mkdir -p "${sim}.tmp" && cp .secrets/prod/deploy-fe-main-user.kubeconfig "${sim}.tmp/KEY"
out="$(CI_PROJECT_DIR="${sim}" ACTION=deploy APP=fe-main-user ENV=prod \
  IMAGE=ghcr.io/tjm-thomas/2026-kanso-fe-main-user:000000000000 \
  DEPLOYER_KUBECONFIG_FE_MAIN_USER="${sim}.tmp/KEY" bash ci/gitlab-job.sh 2>&1)" \
  && { rm -rf "${sim}.tmp"; fail "missing reader key was not refused"; }
rm -rf "${sim}.tmp"
grep -q "STAGING_READER_KUBECONFIG is not set" <<<"${out}" || fail "guard blocked a real file variable: ${out}"

echo PASS
