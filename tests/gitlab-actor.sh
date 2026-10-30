#!/usr/bin/env bash
# ci/gitlab-job.sh must record who caused a deploy. The bug this guards: a trigger from an
# app repo passes SOURCE (repo@commit), but a manual "Run pipeline" passes nothing, and the
# rollout history read "promote <image>" with no name. GITLAB_USER_LOGIN fills the gap, as
# github.actor does on GitHub ("manual by <actor>"). Offline: ci/deploy.sh is a stub that
# prints DEPLOY_SOURCE, in a scratch copy laid out like a runner's checkout.
set -uo pipefail
cd "$(dirname "$0")/.."
fail() { echo "FAIL: $1" >&2; exit 1; }

sim="$(mktemp -d)"; trap 'rm -rf "${sim}" "${sim}.tmp"' EXIT
mkdir -p "${sim}/ci" "${sim}.tmp"
cp ci/gitlab-job.sh "${sim}/ci/"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "${DEPLOY_SOURCE:-}"\n' > "${sim}/ci/deploy.sh"
chmod +x "${sim}/ci/deploy.sh"
echo not-a-key > "${sim}.tmp/KEY"   # only its location is checked; nothing reads it

# job <env assignments...>: run the wrapper as the runner would, print what deploy.sh saw
job() {
  ( cd "${sim}" && env -u SOURCE -u GITLAB_USER_LOGIN "$@" \
      CI_PROJECT_DIR="${sim}" ACTION=deploy APP=fe-main-user ENV=staging IMAGE=x:y \
      DEPLOYER_KUBECONFIG_FE_MAIN_USER="${sim}.tmp/KEY" bash ci/gitlab-job.sh 2>&1 )
}

got="$(job SOURCE=tjm-thomas/app@abc1234 GITLAB_USER_LOGIN=alice)"
[ "${got}" = "tjm-thomas/app@abc1234" ] || fail "a trigger's SOURCE should win: ${got}"

got="$(job GITLAB_USER_LOGIN=alice)"
[ "${got}" = "manual by alice" ] || fail "manual run should record the actor: ${got}"

got="$(job SOURCE= GITLAB_USER_LOGIN=alice)"
[ "${got}" = "manual by alice" ] || fail "an empty SOURCE from the form should count as absent: ${got}"

got="$(job)"
[ "${got}" = "manual by unknown" ] || fail "no login at all should still record something: ${got}"

echo PASS
