#!/usr/bin/env bash
# Build the frontend image, load it into k3s, and roll STAGING to it.
# Usage: ./deploy.sh <tag>
set -euo pipefail
. "$(dirname "$0")/lib.sh"

if [ $# -lt 1 ] || [ -z "$1" ]; then
  echo "Usage: $(basename "$0") <tag>" >&2
  exit 2
fi
TAG="$1"
IMAGE="kanso-web:${TAG}"
NS="$(env_ns staging)"

if [ "$(current_image "${NS}")" = "${IMAGE}" ]; then
  echo "staging already runs ${IMAGE}; nothing to do"
  exit 0
fi

if docker exec k3s ctr images ls -q | grep -x "docker.io/library/kanso-web:${TAG}" >/dev/null; then
  echo "==> ${IMAGE} already in k3s, reusing it (not rebuilding)"
else
  import_image "${TAG}"
fi

echo "==> Rolling staging to ${IMAGE}"
roll "${NS}" "${IMAGE}" "deploy ${IMAGE}"
