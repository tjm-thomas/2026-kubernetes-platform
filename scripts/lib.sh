#!/usr/bin/env bash
# Shared helpers for the platform scripts.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"

# Run kubectl. With DEPLOYER_KUBECONFIG set, use host kubectl with that kubeconfig;
# otherwise exec inside the k3s container (-i so piped stdin works).
# MSYS_NO_PATHCONV: stop Git Bash on Windows rewriting container paths like /platform
kc() {
  if [ -n "${DEPLOYER_KUBECONFIG:-}" ]; then
    kubectl --kubeconfig "${DEPLOYER_KUBECONFIG}" "$@"
  else
    MSYS_NO_PATHCONV=1 docker exec -i k3s kubectl "$@"
  fi
}

# wait_for <seconds> <command...>: retry a command once a second until it succeeds
wait_for() {
  local timeout="$1"; shift
  for _ in $(seq 1 "${timeout}"); do
    "$@" >/dev/null 2>&1 && return 0
    sleep 1
  done
  echo "Timed out after ${timeout}s waiting for: $*" >&2
  return 1
}
