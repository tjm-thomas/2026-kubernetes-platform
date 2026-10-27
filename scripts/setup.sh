#!/usr/bin/env bash
# Set up the cluster layer: wait for k3s and Traefik, then apply Headlamp.
# Safe to re-run. Start the cluster first: cd cluster && docker compose up -d
# Usage: ./scripts/setup.sh
set -euo pipefail
unset DEPLOYER_KUBECONFIG   # setup always needs admin
. "$(dirname "$0")/lib.sh"

echo "==> Waiting for the k3s API"
wait_for 120 kc get --raw /readyz
wait_for 60 kc wait node --all --for=condition=Ready --timeout=5s

echo "==> Waiting for Traefik (bundled with k3s)"
wait_for 180 kc -n kube-system get deploy/traefik
kc -n kube-system rollout status deploy/traefik --timeout=180s

echo "==> Applying cluster manifests"
kc apply -f /platform/cluster/manifests/
kc -n headlamp rollout status deploy/headlamp --timeout=180s
