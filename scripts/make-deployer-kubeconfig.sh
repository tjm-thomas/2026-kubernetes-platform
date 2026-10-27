#!/usr/bin/env bash
# Write .secrets/deploy-<app>.kubeconfig for the app's restricted deployer account.
# Needs admin access (DEPLOYER_KUBECONFIG is ignored). Prints only the file path.
# Usage: ./scripts/make-deployer-kubeconfig.sh <app>
set -euo pipefail
unset DEPLOYER_KUBECONFIG
. "$(dirname "$0")/lib.sh"

if [ "$#" -ne 1 ]; then
  echo "Usage: $(basename "$0") <app>" >&2
  exit 2
fi
APP="$1"
load_app "${APP}"
SECRET="deploy-${APP}-token"

# The token controller fills the Secret in asynchronously: wait for it.
token_b64=""
for _ in $(seq 1 30); do
  token_b64="$(kc -n ci get secret "${SECRET}" -o jsonpath='{.data.token}' 2>/dev/null || true)"
  [ -n "${token_b64}" ] && break
  sleep 1
done
[ -n "${token_b64}" ] || { echo "${SECRET} has no token yet (run setup.sh first?)" >&2; exit 1; }

ca_b64="$(kc -n ci get secret "${SECRET}" -o jsonpath='{.data.ca\.crt}')"
token="$(printf '%s' "${token_b64}" | base64 -d)"

mkdir -p "${ROOT}/.secrets"
out="${ROOT}/.secrets/deploy-${APP}.kubeconfig"
(umask 077; cat > "${out}" <<KUBECONFIG
apiVersion: v1
kind: Config
clusters:
  - name: k3s
    cluster:
      server: https://127.0.0.1:6443
      certificate-authority-data: ${ca_b64}
users:
  - name: deploy-${APP}
    user:
      token: ${token}
contexts:
  - name: deploy-${APP}
    context:
      cluster: k3s
      user: deploy-${APP}
current-context: deploy-${APP}
KUBECONFIG
)
echo "${out}"
