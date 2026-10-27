#!/usr/bin/env bash
# One-time setup (and config changes): headlamp, staging and prod environments.
# Safe to re-run: never changes the image a running environment uses.
# Usage: ./setup.sh
set -euo pipefail
unset KANSO_KUBECONFIG   # setup always needs admin
. "$(dirname "$0")/lib.sh"

if ! docker exec k3s ctr images ls -q | grep -q 'kanso-web:1.0.0$'; then
  import_image 1.0.0
fi

echo "==> Applying headlamp"
kc apply -f /manifests/headlamp.yaml

# Staging password: the Secret must exist before the staging Ingress is applied.
# Never overwritten; the plain password is kept in git-ignored k3s/.secrets/.
kc create namespace kanso-staging --dry-run=client -o yaml | kc apply -f - >/dev/null
if ! kc -n kanso-staging get secret staging-auth >/dev/null 2>&1; then
  password="${STAGING_PASSWORD:-$(openssl rand -hex 8)}"
  mkdir -p "${HERE}/.secrets"
  printf '%s\n' "${password}" > "${HERE}/.secrets/staging-password.txt"
  echo "==> Creating staging-auth secret (user staging, password in k3s/.secrets/staging-password.txt)"
  printf 'staging:%s\n' "$(openssl passwd -apr1 "${password}")" \
    | kc -n kanso-staging create secret generic staging-auth --from-file=users=/dev/stdin
fi

for env in staging prod; do
  ns="$(env_ns "${env}")"
  image="kanso-web:1.0.0"
  if kc -n "${ns}" get deploy/kanso-web >/dev/null 2>&1; then
    image="$(current_image "${ns}")"
  fi
  echo "==> Applying ${env} (${image})"
  kc kustomize "/manifests/kanso/${env}" \
    | sed "s#image: kanso-web:1.0.0#image: ${image}#" \
    | kc apply -f -
done

echo "==> Applying deployer account"
kc apply -f /manifests/deployer.yaml

echo "==> Removing old kanso namespace"
kc delete namespace kanso --ignore-not-found

for env in staging prod; do
  kc -n "$(env_ns "${env}")" rollout status deploy/kanso-web --timeout=120s
done
