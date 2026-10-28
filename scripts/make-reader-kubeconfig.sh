#!/usr/bin/env bash
# Write .secrets/staging/staging-reader.kubeconfig: the read-only account the prod deploy uses to
# check what staging runs (ci/staging-reader.yaml). Needs admin access. Prints only the file path.
# Usage: ./scripts/make-reader-kubeconfig.sh
set -euo pipefail
unset DEPLOYER_KUBECONFIG
. "$(dirname "$0")/lib.sh"

use_cluster staging
out="${ROOT}/.secrets/staging/staging-reader.kubeconfig"
write_kubeconfig staging staging-reader "${out}"
echo "${out}"
