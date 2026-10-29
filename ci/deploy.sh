#!/usr/bin/env bash
# Roll one app in one environment to an image. Called by the deploy workflow.
# staging: deploy it. prod: only if staging is healthy and already runs that exact image.
# Usage: DEPLOYER_KUBECONFIG=<deployer kubeconfig> ci/deploy.sh <app> <staging|prod> <image>
# Each environment runs on its own cluster. For prod, STAGING_READER_KUBECONFIG (the read-only
# staging account) is needed too, so the check can read staging. Without any keys, admin access.
# DEPLOY_SOURCE (optional, e.g. "repo@commit") is added to the rollout history.
set -euo pipefail
. "$(dirname "$0")/../scripts/lib.sh"

if [ "$#" -ne 3 ]; then
  echo "Usage: $(basename "$0") <app> <staging|prod> <image>" >&2
  exit 2
fi
APP="$1" ENV="$2" IMAGE="$3"
if ! [[ "${IMAGE}" =~ ^[a-z0-9./_-]+:[A-Za-z0-9._-]+$ ]]; then
  echo "Not an image reference: ${IMAGE} (expected registry/name:tag)" >&2
  exit 2
fi
load_app "${APP}"
# IMAGE_REPO may list several allowed repos (space-separated), e.g. GHCR and the GitLab registry
repo_ok=no
for repo in ${IMAGE_REPO}; do
  [ "${IMAGE%:*}" = "${repo}" ] && repo_ok=yes
done
if [ "${repo_ok}" != yes ]; then
  echo "${APP} only runs images from: ${IMAGE_REPO} (see apps/${APP}/app.env), not ${IMAGE}" >&2
  exit 1
fi
use_cluster "${ENV}"
NS="${NAMESPACE}"
if ! env_apps "${ENV}" | grep -qx "${APP}"; then
  echo "${APP} is not listed in environments/${ENV}/apps.txt" >&2
  exit 1
fi
if [ -n "${DEPLOYER_KUBECONFIG:-}" ]; then
  # A key for the other cluster would fail later, or worse; stop before any change
  server="$(kubectl config view --kubeconfig "${DEPLOYER_KUBECONFIG}" --minify -o jsonpath='{.clusters[0].cluster.server}')"
  if [ "${server}" != "${API_SERVER}" ]; then
    echo "The deployer kubeconfig points at ${server}, but ${ENV} is at ${API_SERVER}" >&2
    exit 1
  fi
  # Restricted runs must read staging with the read-only key, never fall back to admin
  if [ "${ENV}" = prod ] && [ -z "${STAGING_READER_KUBECONFIG:-}" ]; then
    echo "STAGING_READER_KUBECONFIG is not set: prod needs it to check what staging runs" >&2
    exit 1
  fi
fi
SOURCE="${DEPLOY_SOURCE:+ (${DEPLOY_SOURCE})}"

CURRENT_IMAGE="$(current_image "${NS}" "${APP}")"
if [ "${CURRENT_IMAGE}" = "${IMAGE}" ]; then
  echo "${APP} in ${ENV} already runs ${IMAGE}; nothing to do"
  exit 0
fi

if [ "${ENV}" = prod ]; then
  echo "==> Checking ${APP} in staging is healthy and runs ${IMAGE}"
  # On the staging cluster, with the read-only key (or admin when run without keys)
  STAGING_IMAGE="$(
    DEPLOYER_KUBECONFIG="${STAGING_READER_KUBECONFIG:-}"
    use_cluster staging
    kc -n "${NAMESPACE}" rollout status "deploy/${APP}" --timeout=10s >&2
    current_image "${NAMESPACE}" "${APP}"
  )"
  if [ "${STAGING_IMAGE}" != "${IMAGE}" ]; then
    echo "staging runs ${STAGING_IMAGE}, not ${IMAGE}." >&2
    echo "Only images tested on staging go to prod: deploy it to staging first." >&2
    exit 1
  fi
  CAUSE="promote ${IMAGE}${SOURCE}"
else
  CAUSE="deploy ${IMAGE}${SOURCE}"
fi

echo "==> Rolling ${APP} in ${ENV} to ${IMAGE}"
roll "${NS}" "${APP}" "${IMAGE}" "${CAUSE}"
