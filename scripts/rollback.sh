#!/usr/bin/env bash
# Roll one app in one environment back to its previous revision.
# Usage: ./scripts/rollback.sh <app> <staging|prod>
set -euo pipefail
. "$(dirname "$0")/lib.sh"

if [ "$#" -ne 2 ]; then
  echo "Usage: $(basename "$0") <app> <staging|prod>" >&2
  exit 2
fi
APP="$1" ENV="$2"
load_app "${APP}"
NS="$(env_ns "${ENV}")"

echo "==> Rolling back ${APP} in ${ENV}"
kc -n "${NS}" rollout undo "deploy/${APP}"
kc -n "${NS}" rollout status "deploy/${APP}" --timeout=120s
# undo copies the old revision's change-cause; record what actually happened
kc -n "${NS}" annotate "deploy/${APP}" kubernetes.io/change-cause="rollback to $(current_image "${NS}" "${APP}")" --overwrite
echo "${APP} in ${ENV} now runs $(current_image "${NS}" "${APP}")"
