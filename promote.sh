#!/usr/bin/env bash
# Put the exact image staging runs on production. Does not build anything.
# Usage: ./promote.sh
set -euo pipefail
. "$(dirname "$0")/lib.sh"

STAGING="$(env_ns staging)"
PROD="$(env_ns prod)"
echo "==> Checking staging is healthy"
kc -n "${STAGING}" rollout status deploy/kanso-web --timeout=10s
IMAGE="$(current_image "${STAGING}")"

if [ "$(current_image "${PROD}")" = "${IMAGE}" ]; then
  echo "prod already runs ${IMAGE}; nothing to do"
  exit 0
fi

echo "==> Promoting ${IMAGE} from staging to prod"
roll "${PROD}" "${IMAGE}" "promote ${IMAGE} from staging"
