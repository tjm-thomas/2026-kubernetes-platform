#!/usr/bin/env bash
# choose_image decides which image an app starts on when setup.sh applies it.
# The bug this guards: an app that was removed and re-added used to come back on
# INITIAL_IMAGE (its day-one version) because a deleted Deployment and a never-deployed
# app look identical. The ledger is the second signal that tells them apart, and an app
# with neither a Deployment nor a ledger entry must stop the run, not be guessed at.
# Pure logic: current_image and ledger_lookup are stubbed, so no cluster is needed.
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh
fail() { echo "FAIL: $1" >&2; exit 1; }

LIVE="" RECORDED=""
current_image() { [ -n "${LIVE}" ] && printf '%s' "${LIVE}"; }
ledger_lookup()  { [ -n "${RECORDED}" ] && printf '%s' "${RECORDED}"; }

# Running app: keep what it runs, whatever the ledger or app.env say.
LIVE=repo/app:live RECORDED=repo/app:recorded
got="$(choose_image ns app repo/app:initial no 2>&1)" \
  || fail "a running app should not stop the run: ${got}"
[ "${got}" = repo/app:live ] || fail "running app should keep repo/app:live, got ${got}"

# Removed app returning: the ledger remembers what it ran. This is the defect.
LIVE="" RECORDED=repo/app:recorded
got="$(choose_image ns app repo/app:initial no 2>&1)" \
  || fail "a recorded app should come back without stopping the run: ${got}"
[ "${got}" = repo/app:recorded ] || fail "re-added app should return to repo/app:recorded, got ${got}"
[ "${got}" != repo/app:initial ] || fail "re-added app silently reverted to INITIAL_IMAGE"

# Neither signal: genuinely new, or a record lost with the cluster. Refuse to guess.
LIVE="" RECORDED=""
got="$(choose_image ns app repo/app:initial no 2>&1)" \
  && fail "an app with no Deployment and no record was guessed at: ${got}"
grep -q -- --initial <<<"${got}" || fail "refusal should name the --initial flag: ${got}"
# The routes it offers must work with no Deployment present: writing the ledger does;
# ci/deploy.sh on its own does not (it needs an existing Deployment to set the image on).
grep -q "${IMAGE_LEDGER}" <<<"${got}" || fail "refusal should show how to record the image in the ledger: ${got}"
grep -q "deploy an image with ci/deploy.sh first" <<<"${got}" && fail "refusal still sends the operator to ci/deploy.sh, which fails without a Deployment"

# ...unless the operator says so, which is how a new app is added.
got="$(choose_image ns app repo/app:initial yes 2>&1)" \
  || fail "--initial should allow a new app through: ${got}"
[ "${got}" = repo/app:initial ] || fail "new app should start on repo/app:initial, got ${got}"

echo PASS
