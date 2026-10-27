#!/usr/bin/env bash
# Write k3s/.secrets/deployer.kubeconfig for the restricted `deployer` account.
# Needs admin access (run without KANSO_KUBECONFIG). Prints only the file path.
# Usage: ./make-deployer-kubeconfig.sh
set -euo pipefail
unset KANSO_KUBECONFIG
. "$(dirname "$0")/lib.sh"

# The token controller fills the Secret in asynchronously: wait for it.
token_b64=""
for _ in $(seq 1 30); do
  token_b64="$(kc -n ci get secret deployer-token -o jsonpath='{.data.token}' 2>/dev/null || true)"
  [ -n "${token_b64}" ] && break
  sleep 1
done
[ -n "${token_b64}" ] || { echo "deployer-token has no token yet (run setup.sh first?)" >&2; exit 1; }

ca_b64="$(kc -n ci get secret deployer-token -o jsonpath='{.data.ca\.crt}')"
token="$(printf '%s' "${token_b64}" | base64 -d)"

mkdir -p "${HERE}/.secrets"
out="${HERE}/.secrets/deployer.kubeconfig"
(umask 077; cat > "${out}" <<KUBECONFIG
apiVersion: v1
kind: Config
clusters:
  - name: k3s
    cluster:
      server: https://127.0.0.1:6443
      certificate-authority-data: ${ca_b64}
users:
  - name: deployer
    user:
      token: ${token}
contexts:
  - name: deployer
    context:
      cluster: k3s
      user: deployer
current-context: deployer
KUBECONFIG
)
echo "${out}"
