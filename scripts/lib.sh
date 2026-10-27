#!/usr/bin/env bash
# Shared helpers for the platform scripts (scripts/ and ci/).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Run kubectl. With DEPLOYER_KUBECONFIG set, use host kubectl with that kubeconfig;
# otherwise exec inside the k3s container as admin (-i so piped stdin works).
# MSYS_NO_PATHCONV: stop Git Bash on Windows rewriting arguments like /readyz
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

# load_env <env>: read environments/<env>/env.conf (NAMESPACE, HOST, BASIC_AUTH)
load_env() {
  local file="${ROOT}/environments/${1:-}/env.conf"
  if ! [[ "${1:-}" =~ ^[a-z0-9][a-z0-9-]*$ ]] || [ ! -f "${file}" ]; then
    echo "Unknown environment '${1:-}'. Known: $(ls "${ROOT}/environments" | tr '\n' ' ')" >&2
    exit 2
  fi
  . "${file}"
}

# load_app <app>: read apps/<app>/app.env (IMAGE_REPO, INITIAL_IMAGE, PATH_PREFIX, ...)
load_app() {
  local file="${ROOT}/apps/${1:-}/app.env"
  if ! [[ "${1:-}" =~ ^[a-z0-9][a-z0-9-]*$ ]] || [ ! -f "${file}" ]; then
    echo "Unknown app '${1:-}'. Known: $(ls "${ROOT}/apps" | tr '\n' ' ')" >&2
    exit 2
  fi
  . "${file}"
}

# env_ns <env>: print the namespace of an environment
env_ns() { ( load_env "$1"; echo "${NAMESPACE}" ); }

# env_apps <env>: print the apps listed in environments/<env>/apps.txt, one per line
env_apps() {
  sed -e 's/#.*//' "${ROOT}/environments/$1/apps.txt" | tr -s ' \t\r' '\n' | sed '/^$/d'
}

# render <file>...: print the files with ${APP}, ${NAMESPACE}, ... filled in
# MSYS_NO_PATHCONV: stop Git Bash rewriting values like PATH_PREFIX=/ into Windows paths
render() {
  local file
  for file in "$@"; do
    echo "---"
    MSYS_NO_PATHCONV=1 envsubst '${APP} ${NAMESPACE} ${HOST} ${IMAGE} ${REPLICAS} ${PORT} ${PATH_PREFIX} ${HEALTH_PATH}' < "${file}"
  done
}

# current_image <ns> <app>: print the image the app's Deployment runs (empty if none)
current_image() {
  kc -n "$1" get "deploy/$2" -o jsonpath='{.spec.template.spec.containers[?(@.name=="app")].image}'
}

# roll <ns> <app> <image> <change-cause>: set the image and wait until it is healthy
roll() {
  kc -n "$1" set image "deploy/$2" app="$3"
  kc -n "$1" annotate "deploy/$2" kubernetes.io/change-cause="$4" --overwrite
  kc -n "$1" rollout status "deploy/$2" --timeout=120s
}
