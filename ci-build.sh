#!/usr/bin/env bash
# CI: build the committed frontend/ and push it to the registry, once per content.
# Usage: ./ci-build.sh   (needs `docker login` to the registry first)
set -euo pipefail
. "$(dirname "$0")/lib.sh"

if ! git -C "${HERE}/.." diff --quiet HEAD -- frontend; then
  echo "frontend/ has uncommitted changes; the image tag would not match its content" >&2
  exit 1
fi
IMAGE="$(registry_image)"

if docker manifest inspect "${IMAGE}" >/dev/null 2>&1; then
  echo "==> ${IMAGE} already in the registry, not rebuilding"
  exit 0
fi

echo "==> Building ${IMAGE}"
docker build --build-arg "VERSION=${IMAGE##*:}" \
  --label "org.opencontainers.image.source=${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-thomasjmtan/2026-kubernetes-fe-test}" \
  -t "${IMAGE}" "${HERE}/../frontend"
echo "==> Pushing ${IMAGE}"
docker push "${IMAGE}"
