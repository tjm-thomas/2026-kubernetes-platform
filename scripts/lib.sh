#!/usr/bin/env bash
# Shared helpers for the platform scripts (scripts/ and ci/).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# set -e also inside $(...): a failed check there must stop the script, not be ignored
shopt -s inherit_errexit

# use_cluster <env>: point kc at the environment's cluster (environments/<env>/env.conf).
# DEPLOYER_KUBECONFIG set: that restricted key. Otherwise admin: CLUSTER_CONTAINER, or
# CLUSTER_ADMIN_KUBECONFIG when no container is named.
use_cluster() {
  local CLUSTER_CONTAINER="" CLUSTER_ADMIN_KUBECONFIG=""
  load_env "$1"
  KC_KUBECONFIG="" KC_CONTAINER=""
  if [ -n "${DEPLOYER_KUBECONFIG:-}" ]; then
    KC_KUBECONFIG="${DEPLOYER_KUBECONFIG}"
  elif [ -n "${CLUSTER_CONTAINER}" ]; then
    KC_CONTAINER="${CLUSTER_CONTAINER}"
  elif [ -n "${CLUSTER_ADMIN_KUBECONFIG}" ]; then
    KC_KUBECONFIG="${ROOT}/${CLUSTER_ADMIN_KUBECONFIG}"
  else
    echo "environments/$1/env.conf names no CLUSTER_CONTAINER or CLUSTER_ADMIN_KUBECONFIG" >&2
    exit 2
  fi
}

# Run kubectl against the cluster chosen by use_cluster: host kubectl with a kubeconfig,
# or exec inside the k3s container as admin (-i so piped stdin works).
# MSYS_NO_PATHCONV: stop Git Bash on Windows rewriting arguments like /readyz
kc() {
  if [ -n "${KC_KUBECONFIG:-}" ]; then
    kubectl --kubeconfig "${KC_KUBECONFIG}" "$@"
  elif [ -n "${KC_CONTAINER:-}" ]; then
    MSYS_NO_PATHCONV=1 docker exec -i "${KC_CONTAINER}" kubectl "$@"
  else
    echo "kc: call use_cluster <env> first" >&2
    return 2
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
    MSYS_NO_PATHCONV=1 envsubst '${APP} ${NAMESPACE} ${HOST} ${IMAGE} ${REPLICAS} ${PORT} ${PATH_PREFIX} ${HEALTH_PATH} ${MEMORY_LIMIT} ${HEADLAMP_HOST}' < "${file}"
  done
}

# current_image <ns> <app>: print the image the app's Deployment runs (empty if none)
current_image() {
  kc -n "$1" get "deploy/$2" -o jsonpath='{.spec.template.spec.containers[?(@.name=="app")].image}'
}

# write_kubeconfig <env> <serviceaccount> <out-file>: write a kubeconfig for a service account in
# namespace ci of the env's cluster (admin access via use_cluster first). Never prints the token.
write_kubeconfig() {
  local env="$1" sa="$2" out="$3" token_b64="" ca_b64 token
  # The token controller fills the Secret in asynchronously: wait for it.
  for _ in $(seq 1 30); do
    token_b64="$(kc -n ci get secret "${sa}-token" -o jsonpath='{.data.token}' 2>/dev/null || true)"
    [ -n "${token_b64}" ] && break
    sleep 1
  done
  [ -n "${token_b64}" ] || { echo "${sa}-token has no token yet in ${env} (run setup.sh first?)" >&2; exit 1; }
  ca_b64="$(kc -n ci get secret "${sa}-token" -o jsonpath='{.data.ca\.crt}')"
  token="$(printf '%s' "${token_b64}" | base64 -d)"

  mkdir -p "$(dirname "${out}")"
  (umask 077; cat > "${out}" <<KUBECONFIG
apiVersion: v1
kind: Config
clusters:
  - name: k3s-${env}
    cluster:
      server: $( load_env "${env}"; echo "${API_SERVER}" )
      certificate-authority-data: ${ca_b64}
users:
  - name: ${sa}
    user:
      token: ${token}
contexts:
  - name: ${sa}
    context:
      cluster: k3s-${env}
      user: ${sa}
current-context: ${sa}
KUBECONFIG
  )
}

# roll <ns> <app> <image> <change-cause>: set the image and wait until it is healthy
roll() {
  kc -n "$1" set image "deploy/$2" app="$3"
  kc -n "$1" annotate "deploy/$2" kubernetes.io/change-cause="$4" --overwrite
  kc -n "$1" rollout status "deploy/$2" --timeout=120s
}
