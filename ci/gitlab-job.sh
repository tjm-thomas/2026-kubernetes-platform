#!/usr/bin/env bash
# GitLab job wrapper: the .gitlab-ci.yml jobs run this and nothing else.
# Env in: ACTION (deploy|rollback, default deploy), APP, ENV, IMAGE, SOURCE (optional),
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

key_var="DEPLOYER_KUBECONFIG_$(printf '%s' "${APP}" | tr 'a-z-' 'A-Z_')"
if [ -z "${!key_var:-}" ]; then
  echo "variable ${key_var} is not set for ${ENV}" >&2
  exit 1
fi
export DEPLOYER_KUBECONFIG="${!key_var}"
if [ -n "${STAGING_READER_KUBECONFIG:-}" ]; then
  export STAGING_READER_KUBECONFIG
fi
export DEPLOY_SOURCE="${SOURCE:-}"

case "${ACTION}" in
  deploy)   exec ci/deploy.sh "${APP}" "${ENV}" "${IMAGE:?variable IMAGE is not set}" ;;
  rollback) exec scripts/rollback.sh "${APP}" "${ENV}" ;;
  *) echo "Unknown ACTION: ${ACTION} (deploy|rollback)" >&2; exit 2 ;;
esac
