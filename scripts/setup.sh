#!/usr/bin/env bash
# Set up the cluster, the environments and their apps. Safe to re-run:
# - never changes the image an app already runs (only ci/deploy.sh does that)
# - removes apps that are no longer listed in environments/<env>/apps.txt
# Start the cluster first: cd cluster && docker compose up -d
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
cat "${ROOT}"/cluster/manifests/*.yaml | kc apply -f -
kc -n headlamp rollout status deploy/headlamp --timeout=180s

echo "==> Applying deployer accounts (one per app)"
for dir in "${ROOT}"/apps/*/; do
  APP="$(basename "${dir}")" render "${ROOT}/ci/deployer-account.yaml" | kc apply -f -
done

for env_dir in "${ROOT}"/environments/*/; do
  env="$(basename "${env_dir}")"
  (
    load_env "${env}"
    echo "==> Environment ${env} (${NAMESPACE}, ${HOST})"
    kc apply -f - < "${env_dir}namespace.yaml"

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

    apps="$(env_apps "${env}")"
    for app in ${apps}; do
      (
        load_app "${app}"
        export APP="${app}" NAMESPACE HOST PORT PATH_PREFIX HEALTH_PATH
        export IMAGE="$(current_image "${NAMESPACE}" "${app}" 2>/dev/null || true)"
        IMAGE="${IMAGE:-${INITIAL_IMAGE}}"
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
