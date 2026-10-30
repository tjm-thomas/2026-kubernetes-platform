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

# The image ledger: a ConfigMap in the environment's namespace remembering what each app
# runs. The Deployment is otherwise the only record, so removing an app destroyed it and
# the app came back on INITIAL_IMAGE (its day-one version). setup.sh writes the ledger with
# admin access before it changes anything; the restricted CI keys never touch it.
IMAGE_LEDGER=kanso-image-ledger

# ledger_record <ns> <app> <image>: remember the image an app runs
ledger_record() {
  kc -n "$1" create configmap "${IMAGE_LEDGER}" >/dev/null 2>&1 || true
  kc -n "$1" patch configmap "${IMAGE_LEDGER}" --type merge -p "{\"data\":{\"$2\":\"$3\"}}" >/dev/null
}

# ledger_lookup <ns> <app>: print the recorded image, nothing if there is none
ledger_lookup() {
  kc -n "$1" get configmap "${IMAGE_LEDGER}" -o "jsonpath={.data['$2']}" 2>/dev/null || true
}

# choose_image <ns> <app> <initial-image> <allow-initial yes|no>: the image setup.sh applies.
# A running app keeps what it runs; a re-added app returns to what the ledger remembers.
# With neither, the run stops: a missing Deployment means either a brand-new app or one whose
# record went with its cluster, and guessing picks a version nobody asked for.
choose_image() {
  local ns="$1" app="$2" initial="$3" allow="$4" image
  image="$(current_image "${ns}" "${app}" 2>/dev/null || true)"
  [ -n "${image}" ] || image="$(ledger_lookup "${ns}" "${app}" 2>/dev/null || true)"
  if [ -z "${image}" ]; then
    if [ "${allow}" != yes ]; then
      echo "${app} is listed for ${ns} but is not running and has no recorded image." >&2
      echo "Pass --initial ${app} to start it on ${initial} (INITIAL_IMAGE from apps/${app}/app.env)," >&2
      echo "or deploy an image with ci/deploy.sh first." >&2
      return 1
    fi
    image="${initial}"
  fi
  printf '%s' "${image}"
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
