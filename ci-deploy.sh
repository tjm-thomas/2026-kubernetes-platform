#!/usr/bin/env bash
# CI: roll an environment to the registry image for the committed frontend/.
# staging: deploy it. prod: only if staging already runs that exact image (no rebuild).
# Usage: KANSO_KUBECONFIG=<deployer kubeconfig> ./ci-deploy.sh <staging|prod>
set -euo pipefail
. "$(dirname "$0")/lib.sh"

NS="$(env_ns "${1:-}")"
IMAGE="$(registry_image)"
COMMIT="$(git -C "${HERE}/.." rev-parse --short HEAD)"

if [ "$(current_image "${NS}")" = "${IMAGE}" ]; then
  echo "${1} already runs ${IMAGE}; nothing to do"
  exit 0
fi

if [ "${1}" = prod ]; then
  STAGING="$(env_ns staging)"
  echo "==> Checking staging is healthy and runs ${IMAGE}"
  kc -n "${STAGING}" rollout status deploy/kanso-web --timeout=10s
  if [ "$(current_image "${STAGING}")" != "${IMAGE}" ]; then
    echo "staging runs $(current_image "${STAGING}"), not ${IMAGE}." >&2
    echo "Only images tested on staging go to prod: push this change to the staging branch first." >&2
    exit 1
  fi
  CAUSE="promote ${IMAGE} (main ${COMMIT})"
else
  CAUSE="deploy ${IMAGE} (staging ${COMMIT})"
fi

echo "==> Rolling ${1} to ${IMAGE}"
roll "${NS}" "${IMAGE}" "${CAUSE}"
