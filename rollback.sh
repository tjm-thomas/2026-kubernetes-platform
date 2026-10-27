#!/usr/bin/env bash
# Roll an environment back to its previous revision.
# Usage: ./rollback.sh <staging|prod>
set -euo pipefail
. "$(dirname "$0")/lib.sh"

NS="$(env_ns "${1:-}")"

echo "==> Rolling back ${1}"
kc -n "${NS}" rollout undo deploy/kanso-web
kc -n "${NS}" rollout status deploy/kanso-web --timeout=120s
kc -n "${NS}" annotate deploy/kanso-web kubernetes.io/change-cause="rollback to $(current_image "${NS}")" --overwrite
echo "${1} now runs $(current_image "${NS}")"
