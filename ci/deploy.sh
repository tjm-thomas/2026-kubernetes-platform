#!/usr/bin/env bash
# Roll one app in one environment to an image. Called by the deploy workflow.
# staging: deploy it. prod: only if staging is healthy and already runs that exact image.
# Usage: DEPLOYER_KUBECONFIG=<deployer kubeconfig> ci/deploy.sh <app> <staging|prod> <image>
# DEPLOY_SOURCE (optional, e.g. "repo@commit") is added to the rollout history.
set -euo pipefail
. "$(dirname "$0")/../scripts/lib.sh"

if [ "$#" -ne 3 ]; then
  echo "Usage: $(basename "$0") <app> <staging|prod> <image>" >&2
  exit 2
fi
APP="$1" ENV="$2" IMAGE="$3"
load_app "${APP}"
NS="$(env_ns "${ENV}")"
if ! env_apps "${ENV}" | grep -qx "${APP}"; then
  echo "${APP} is not listed in environments/${ENV}/apps.txt" >&2
  exit 1
fi
SOURCE="${DEPLOY_SOURCE:+ (${DEPLOY_SOURCE})}"

if [ "$(current_image "${NS}" "${APP}")" = "${IMAGE}" ]; then
  echo "${APP} in ${ENV} already runs ${IMAGE}; nothing to do"
  exit 0
fi

if [ "${ENV}" = prod ]; then
  STAGING="$(env_ns staging)"
  echo "==> Checking ${APP} in staging is healthy and runs ${IMAGE}"
  kc -n "${STAGING}" rollout status "deploy/${APP}" --timeout=10s
  STAGING_IMAGE="$(current_image "${STAGING}" "${APP}")"
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
