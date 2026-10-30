#!/usr/bin/env bash
# Set up each environment on its own cluster: the cluster itself, the environment and its apps.
# Safe to re-run:
# - never changes the image an app already runs (only ci/deploy.sh does that)
# - an app that was removed and is listed again returns to the image it ran, from the ledger
# - removes apps that are no longer listed in environments/<env>/apps.txt
# Start the clusters first: cd cluster && docker compose up -d
# Usage: ./scripts/setup.sh [env] [--initial <app>|--initial all]
#   no env: every environment
#   --initial: start these apps on INITIAL_IMAGE. Needed the first time an app is added,
#     and after a cluster rebuild took the ledger with it. Without it, an app that is
#     listed but has no Deployment and no ledger entry stops the run instead of being
#     guessed at: guessing silently reverts production to a day-one version.
set -euo pipefail
unset DEPLOYER_KUBECONFIG   # setup always needs admin
. "$(dirname "$0")/lib.sh"

allow_initial=""
positional=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --initial)
      allow_initial="${allow_initial} ${2:?--initial needs an app name, or all}"
      shift 2
      ;;
    *) positional="${positional} $1"; shift ;;
  esac
done
set -- ${positional}

# allow_for <app>: yes when --initial named this app (or all)
allow_for() {
  case " ${allow_initial} " in
    *" all "*|*" $1 "*) echo yes ;;
    *) echo no ;;
  esac
}

if [ "$#" -gt 0 ]; then
  ( load_env "$1" )   # exits with the list of known environments if unknown
  envs="$1"
else
  envs="$(ls "${ROOT}/environments")"
fi

for env in ${envs}; do
  (
    use_cluster "${env}"
    env_dir="${ROOT}/environments/${env}/"

    echo "==> [${env}] Waiting for the k3s API"
    wait_for 120 kc get --raw /readyz
    wait_for 60 kc wait node --all --for=condition=Ready --timeout=5s

    echo "==> [${env}] Waiting for Traefik (bundled with k3s)"
    wait_for 180 kc -n kube-system get deploy/traefik
    kc -n kube-system rollout status deploy/traefik --timeout=180s

    echo "==> [${env}] Applying cluster manifests"
    HEADLAMP_HOST="${HEADLAMP_HOST}" render "${ROOT}"/cluster/manifests/*.yaml | kc apply -f -
    kc -n headlamp rollout status deploy/headlamp --timeout=180s

    apps="$(env_apps "${env}")"
    echo "==> [${env}] Applying deployer accounts (one per app)"
    for app in ${apps}; do
      APP="${app}" render "${ROOT}/ci/deployer-account.yaml" | kc apply -f -
    done

    echo "==> [${env}] Environment (${NAMESPACE}, ${HOST})"
    kc apply -f - < "${env_dir}namespace.yaml"

    # The read-only account the prod deploy uses to check staging
    if [ "${env}" = staging ]; then
      NAMESPACE="${NAMESPACE}" render "${ROOT}/ci/staging-reader.yaml" | kc apply -f -
    fi

    # The Secret must exist before the middleware that uses it. Never overwritten;
    # the plain password is kept in git-ignored .secrets/.
    if [ "${BASIC_AUTH}" = yes ] && ! kc -n "${NAMESPACE}" get secret basic-auth >/dev/null 2>&1; then
      password="$(openssl rand -hex 8)"
      mkdir -p "${ROOT}/.secrets"
      (umask 077; printf '%s\n' "${password}" > "${ROOT}/.secrets/${env}-password.txt")
      echo "    creating basic-auth (user ${env}, password in .secrets/${env}-password.txt)"
      printf '%s:%s\n' "${env}" "$(openssl passwd -apr1 "${password}")" \
        | kc -n "${NAMESPACE}" create secret generic basic-auth --from-file=users=/dev/stdin
    fi
    kc apply -f - < "${env_dir}middleware.yaml"

    # Remember what everything runs before anything is applied or removed. Removal deletes
    # the Deployment, which is otherwise the only record of the image it was on.
    for app in $(kc -n "${NAMESPACE}" get deploy -l app.kubernetes.io/managed-by=kanso-platform \
      -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true); do
      ledger_record "${NAMESPACE}" "${app}" "$(current_image "${NAMESPACE}" "${app}")"
    done

    for app in ${apps}; do
      (
        load_app "${app}"
        export APP="${app}" NAMESPACE HOST PORT PATH_PREFIX HEALTH_PATH
        IMAGE="$(choose_image "${NAMESPACE}" "${app}" "${INITIAL_IMAGE}" "$(allow_for "${app}")")"
        export IMAGE
        replicas_var="REPLICAS_${env^^}"
        export REPLICAS="${!replicas_var:-1}"
        export MEMORY_LIMIT="${MEMORY_LIMIT:-128Mi}"
        echo "    app ${app}: ${IMAGE}, ${REPLICAS} replica(s), path ${PATH_PREFIX}, memory ${MEMORY_LIMIT}"
        render "${ROOT}/apps/${app}"/base/*.yaml "${ROOT}/ci/deployer-role.yaml" \
          | kc -n "${NAMESPACE}" apply -f - >/dev/null
      )
    done

    # Remove apps that run here but are no longer listed
    running="$(kc -n "${NAMESPACE}" get deploy -l app.kubernetes.io/managed-by=kanso-platform \
      -o jsonpath='{.items[*].metadata.name}')"
    for app in ${running}; do
      if ! grep -qx "${app}" <<< "${apps}"; then
        echo "    removing ${app} (not in apps.txt)"
        kc -n "${NAMESPACE}" delete deploy,svc,ingress,role,rolebinding -l "app.kubernetes.io/name=${app}"
      fi
    done

    for app in ${apps}; do
      kc -n "${NAMESPACE}" rollout status "deploy/${app}" --timeout=120s
    done
  )
done
