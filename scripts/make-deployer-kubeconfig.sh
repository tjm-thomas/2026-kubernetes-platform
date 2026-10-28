#!/usr/bin/env bash
# Write .secrets/<env>/deploy-<app>.kubeconfig for the app's restricted deployer account on the
# env's cluster. Needs admin access (DEPLOYER_KUBECONFIG is ignored). Prints only the file path.
# Usage: ./scripts/make-deployer-kubeconfig.sh <app> <staging|prod>
set -euo pipefail
unset DEPLOYER_KUBECONFIG
. "$(dirname "$0")/lib.sh"

if [ "$#" -ne 2 ]; then
  echo "Usage: $(basename "$0") <app> <staging|prod>" >&2
  exit 2
fi
APP="$1" ENV="$2"
load_app "${APP}"
use_cluster "${ENV}"

out="${ROOT}/.secrets/${ENV}/deploy-${APP}.kubeconfig"
write_kubeconfig "${ENV}" "deploy-${APP}" "${out}"
echo "${out}"
