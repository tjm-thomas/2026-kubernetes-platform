#!/usr/bin/env bash
# The image-provenance guard in ci/deploy.sh: wrong registries are refused,
# every allow-listed registry gets past the guard (then fails at the prod gate,
# which proves the guard passed without changing anything).
set -uo pipefail
cd "$(dirname "$0")/.."
fail() { echo "FAIL: $1" >&2; exit 1; }

out="$(ci/deploy.sh fe-main-user prod docker.io/evil/kanso:x 2>&1)" \
  && fail "evil registry was accepted"
grep -q "only runs images from" <<<"${out}" || fail "wrong refusal: ${out}"

out="$(ci/deploy.sh fe-main-user prod ghcr.io/tjm-thomas/2026-kanso-fe-main-user:000000000000 2>&1)" \
  && fail "unknown ghcr tag reached prod"
grep -q "staging runs" <<<"${out}" || fail "ghcr repo no longer passes the guard: ${out}"

out="$(ci/deploy.sh fe-main-user prod registry.gitlab.com/tjm-thomas/2026-kanso-fe-main-user:000000000000 2>&1)" \
  && fail "unknown gitlab tag reached prod"
grep -q "staging runs" <<<"${out}" || fail "gitlab repo does not pass the guard: ${out}"

echo PASS
