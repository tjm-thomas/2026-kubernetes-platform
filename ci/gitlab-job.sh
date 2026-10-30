#!/usr/bin/env bash
# GitLab job wrapper: the .gitlab-ci.yml jobs run this and nothing else.
# Env in: ACTION (deploy|rollback, default deploy), APP, ENV, IMAGE, SOURCE (optional),
# GITLAB_USER_LOGIN (predefined; recorded when SOURCE is absent),
# and the keys as GitLab *file* variables (values are paths to files GitLab wrote):
#   DEPLOYER_KUBECONFIG_<APP in caps, - as _>   this app's restricted key for ${ENV}
#   STAGING_READER_KUBECONFIG                   read-only staging key (prod only)
# The variables are Protected, so only pipelines on a protected ref (main) receive them.
# Never prints secret values.
set -euo pipefail

ACTION="${ACTION:-deploy}"
APP="${APP:?variable APP is not set}"
ENV="${ENV:?variable ENV is not set}"
if ! [[ "${APP}" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
  echo "Bad app name: ${APP}" >&2
  exit 2
fi

# A key must be the PATH GitLab wrote for a File-type variable: never the key's content
# (a plain variable would reach kubectl, which echoes it into the public job log), and never
# a caller-supplied path (trigger variables override project variables, so a caller could
# point a key at any file on the runner). File variables land in <CI_PROJECT_DIR>.tmp\.
# check_key_file <name> <value>: exits 1 with the name (never the value) when invalid.
check_key_file() {
  if [ ! -f "$2" ]; then
    echo "$1 must be a File-type variable (its value is not a file GitLab wrote)" >&2
    exit 1
  fi
  if [ -n "${CI_PROJECT_DIR:-}" ]; then
    local v="${2//\\//}" d="${CI_PROJECT_DIR//\\//}"
    if [[ "${v,,}" != "${d,,}.tmp/"* ]]; then
      echo "$1 must be a File-type variable (its value is not in the file-variable directory)" >&2
      exit 1
    fi
  fi
}

key_var="DEPLOYER_KUBECONFIG_$(printf '%s' "${APP}" | tr 'a-z-' 'A-Z_')"
if [ -z "${!key_var:-}" ]; then
  echo "variable ${key_var} is not set for ${ENV}" >&2
  exit 1
fi
check_key_file "${key_var}" "${!key_var}"
export DEPLOYER_KUBECONFIG="${!key_var}"
if [ -n "${STAGING_READER_KUBECONFIG:-}" ]; then
  check_key_file STAGING_READER_KUBECONFIG "${STAGING_READER_KUBECONFIG}"
  export STAGING_READER_KUBECONFIG
fi
# A trigger from an app repo sets SOURCE (repo@commit). "Run pipeline" in the UI does not:
# record who did it instead, as the GitHub workflow does ("manual by <actor>"). GitLab
# documents GITLAB_USER_LOGIN as the pipeline's starter, except in manual jobs, where it
# is whoever pressed play.
export DEPLOY_SOURCE="${SOURCE:-manual by ${GITLAB_USER_LOGIN:-unknown}}"

case "${ACTION}" in
  deploy)   exec ci/deploy.sh "${APP}" "${ENV}" "${IMAGE:?variable IMAGE is not set}" ;;
  rollback) exec scripts/rollback.sh "${APP}" "${ENV}" ;;
  *) echo "Unknown ACTION: ${ACTION} (deploy|rollback)" >&2; exit 2 ;;
esac
