# Defect Fixes Implementation Plan (A: `/api` 404, B: `DEPLOY_SYSTEM` guard, C: GitLab actor)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close three defects found in a live test run: the frontend answering `200 text/html` for `/api/*` when the backend is gone, the `DEPLOY_SYSTEM` switch skipping silently on any value it does not recognise byte-for-byte, and manual GitLab deploys recording no actor in the rollout history.

**Architecture:** Two repos, no shared code between them. A and B are fixes in the app repo `2026-kanso-fe-main-user` (its `nginx.conf` and its CI entry points), each with a test in a new `tests/` directory there, in the platform repo's test style. C is a one-line fix in the platform repo's `ci/gitlab-job.sh` with an offline test. A final task pushes both branches (USER-approved) and reads the fixes back from the live clusters. The pending image-ledger work already on the platform branch is committed first, untouched.

**Tech Stack:** bash (Git Bash on Windows, `ubuntu-latest` on GitHub), nginx 1.27, Docker, GitHub Actions, GitLab CI (gitlab.com group `tjm-thomas`), the two local k3s clusters (`k3s-staging`, `k3s`).

**Spec:** none. The defects come from a live test run (2026-10-30); the source for this plan is the brief that run produced plus the **Gaps in the platform code** section of `docs/guide/airgap-runbook.md`. Facts the brief stated as measured (LF in git, CRLF in the Windows working copy, `core.autocrlf=true`, GitHub's gate on `ubuntu-latest`) were re-checked against the repos while writing this plan and hold. One fact did not: the brief said `2026-kanso-be-main` and `2026-kanso-fe-dashboard` carry the same `gate` job; they carry **no** gate and **no** `DEPLOY_SYSTEM` file (checked on every branch of both). Task 3 says what that means.

**Repos and branches:**
- Platform: `C:\Users\user\Documents\GitHub\kubernetes-test\2026-kubernetes-platform`, branch `defect-fixes` (from `main` at 3ab0b0b). Tasks 1, 4 and the platform half of 5 run here.
- App: `C:\Users\user\Documents\GitHub\kubernetes-test\2026-kanso-fe-main-user`, branch `defect-fixes` (from `staging` at b207022). Tasks 2, 3 and the app half of 5 run here.

## Global Constraints

- **Commit only when the user says "commit"; push only when they say "push".** Both repos are public. Every "Commit" step below is presented and waits for that word; every push is a **USER** step.
- Never print secrets. `.secrets/` and `kubeconfig/` are git-ignored. The staging basic-auth password is read with `pw=$(cat .secrets/staging-password.txt)` and used as `-u "staging:$pw"`; it is never echoed, and no file in `.secrets/` is ever printed.
- Anything needing the user's GitHub/GitLab login (tokens, CI variables, settings, pressing play) → exact steps for the user; the agent does not do it.
- Windows 11, Git Bash. CI jobs use `shell: C:\PROGRA~1\Git\bin\bash.exe --noprofile --norc -eo pipefail {0}`; plain `bash` at the runner level is WSL. `MSYS_NO_PATHCONV=1` only on `docker exec` with container paths; never exported.
- GitLab job script lines keep the `$env:BASH_ENV=$null;` prefix (the runner shell is PowerShell and non-interactive bash expands `BASH_ENV`).
- Do not widen the restricted per-app deployer RBAC. Those keys may patch exactly one Deployment.
- Verify before claiming: curl through the ingress, `/version.txt` per host, `rollout history`.
- Scripts in both repos are stored `100644` (no executable bit) and are invoked as `bash <path>`; new scripts follow that, so they also run on `ubuntu-latest`.
- Tests: `set -uo pipefail`, `cd "$(dirname "$0")/.."`, `fail() { echo "FAIL: $1" >&2; exit 1; }`, assertions, `echo PASS`; a comment block at the top naming the bug the test guards against. Run as `bash tests/<name>.sh` from the repo root.
- Commit messages: imperative, capitalised, no type prefix (house style: "Harden the GitLab jobs after review"), ending with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

## Review Focus

Inputs the brief implies but does not spell out, most likely to bite first. Each has its test pinned in the owning task.

1. `GET /api` with no trailing slash. The backend Ingress is `pathType: Prefix` on `/api`, which matches `/api` itself; an nginx `location ^~ /api/` alone would let `/api` fall through to the SPA and answer 200. Expected: 404. → Task 2 test, `/api` case.
2. A real SPA deep link after the fix, e.g. `/release` (served by `try_files $uri.html`) and an unknown path like `/no/such/page`. Expected: still `200 text/html`; the fix must not turn the SPA fallback off. → Task 2 test.
3. `DEPLOY_SYSTEM` that exists but is empty, or says ` GitLab ` with spaces and capitals. Expected: empty fails loudly (a file that says nothing is a mistake, not "github"); whitespace and case are normalised. → Task 3 test.
4. The GitHub `gate` step when the script exits non-zero. `echo "system=$(...)"` would exit 0 with an empty output and `build-deploy` would skip exactly as before. Expected: the step fails. → Task 3, step 6 wording, and the test's static check that no caller still uses the inline `cat`.
5. A manual GitLab "Run pipeline" where the user typed `SOURCE` into the form but left it blank, so `SOURCE` is set and empty. Expected: the actor is recorded, not an empty source. → Task 4 test.

---

### Task 1: Commit the image-ledger work already on the platform branch

The branch carries verified, uncommitted work: `scripts/lib.sh` (`IMAGE_LEDGER`, `ledger_record`, `ledger_lookup`, `choose_image`), `scripts/setup.sh` (`--initial`, ledger write before removal), `tests/image-ledger.sh`, `docs/guide/add-an-app.md`, and the new `docs/guide/airgap-runbook.md`. This task only lands it, so later tasks diff cleanly. Do not re-plan or edit it.

**Files:**
- Commit (no edits): `scripts/lib.sh`, `scripts/setup.sh`, `tests/image-ledger.sh`, `docs/guide/add-an-app.md`, `docs/guide/airgap-runbook.md`

**Interfaces:**
- Produces: a clean `defect-fixes` tree; Task 3 step 8 edits `docs/guide/airgap-runbook.md` on top of this commit.

- [ ] **Step 1: Confirm the work still passes**

Run: `bash tests/image-ledger.sh`
Expected: `PASS`

- [ ] **Step 2: Confirm nothing else is pending**

Run: `git status --short`
Expected: exactly ` M docs/guide/add-an-app.md`, ` M scripts/lib.sh`, ` M scripts/setup.sh`, `?? docs/guide/airgap-runbook.md`, `?? tests/image-ledger.sh` (plus this plan file). Anything else: stop and ask.

- [ ] **Step 3: Commit in two pieces (when the USER says commit)**

```bash
git add scripts/lib.sh scripts/setup.sh tests/image-ledger.sh docs/guide/add-an-app.md
git commit -m "Remember each app's image in a ledger so a re-added app keeps its version

setup.sh used to bring a removed-then-relisted app back on INITIAL_IMAGE, because a
deleted Deployment and a never-deployed app look the same. A ConfigMap per namespace
(kanso-image-ledger) now records what each app ran before anything is removed, and an
app with neither a Deployment nor a record stops the run unless --initial names it.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
git add docs/guide/airgap-runbook.md docs/superpowers/plans/2026-10-30-defect-fixes.md
git commit -m "Add the airgap runbook and the defect-fixes plan

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Defect A — the frontend answers 404 for `/api`, never the SPA page

**Repo:** `2026-kanso-fe-main-user`

`nginx.conf` has `location / { try_files $uri $uri.html $uri/ /index.html; }`. With `be-main` removed from an environment its Ingress goes, Traefik's longest-prefix match sends `/api/*` to this app (prefix `/`), and the fallback answers `200 text/html`. Fix: two locations that return 404 for `/api` and `/api/...`. 404, not 502: this server genuinely does not serve `/api` and knows nothing about a backend.

`^~` check: nginx picks the longest matching prefix location, so `/api/` already beats `/`; `^~` adds "and do not consult regex locations", which protects the rule if a regex location is ever added. There are none today (`= /version.txt` and `= /healthz` are exact matches). So `^~` is right, and harmless. The exact `= /api` location is needed because `location ^~ /api/` does not match `/api` itself, while the backend Ingress (`pathType: Prefix`, path `/api`) does (Review Focus 1).

Test placement: the app repo gets a `tests/` directory, same house style as the platform's. Reason: `nginx.conf` and the Dockerfile are app-repo artifacts; a platform test would have to `cd` into a sibling checkout and would break the moment the repos are laid out differently (the airgapped target gets them by export). The test runs the image locally with Docker, not against the cluster: no secrets, no cluster state, and it fails before the image is ever pushed.

Overrule, recorded: the brief suggested running the image through `docker-compose.yml`. That file pins `container_name: fe-main-user` and port `8088`, so a test using it would collide with a dev container the user may have up, and `docker compose -p` cannot rename a fixed `container_name`. The test uses `docker build` + `docker run` with its own name and port instead; same image, same Dockerfile.

**Files:**
- Modify: `nginx.conf` (insert before the `location /` block)
- Create: `tests/api-404.sh`

**Interfaces:**
- Produces: `GET /api` and `GET /api/<anything>` → `404`, body from nginx's default 404 page. Every other path unchanged. The test container is `fe-main-user-test` on `127.0.0.1:18088`; image tag `fe-main-user:test`.

- [ ] **Step 1: Write the failing test** `tests/api-404.sh`

```bash
#!/usr/bin/env bash
# The frontend must never answer for /api. The bug this guards: when be-main is removed
# from an environment its Ingress goes too, Traefik sends /api/* to this app (prefix /),
# and the SPA fallback (try_files ... /index.html) answered 200 text/html: a dead backend
# that looked alive. Builds the image and runs it locally; no cluster, no secrets.
set -uo pipefail
cd "$(dirname "$0")/.."
fail() { echo "FAIL: $1" >&2; exit 1; }

name=fe-main-user-test port=18088
cleanup() { docker rm -f "${name}" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup
docker build -q -t fe-main-user:test . >/dev/null || fail "image build failed"
docker run -d --name "${name}" -p "127.0.0.1:${port}:80" fe-main-user:test >/dev/null || fail "container did not start"
for _ in $(seq 1 30); do
  curl -sf "http://127.0.0.1:${port}/healthz" >/dev/null && break
  sleep 1
done
curl -sf "http://127.0.0.1:${port}/healthz" >/dev/null || fail "/healthz never came up"

# status <path>: prints "<http code> <content-type without charset>"
status() { curl -s -o /dev/null -w '%{http_code} %{content_type}' "http://127.0.0.1:${port}$1" | sed 's/;.*//'; }

# The defect: API paths must not get the SPA page
for p in /api /api/ /api/status /api/companies/count; do
  got="$(status "${p}")"
  [ "${got%% *}" = 404 ] || fail "${p} should be 404, got: ${got}"
done
# ...and the SPA fallback still works for everything else
[ "$(status /)" = "200 text/html" ]              || fail "/ should be the SPA page, got: $(status /)"
[ "$(status /release)" = "200 text/html" ]       || fail "/release (release.html) should serve, got: $(status /release)"
[ "$(status /no/such/page)" = "200 text/html" ]  || fail "unknown paths should fall back to index.html, got: $(status /no/such/page)"
[ "$(status /version.txt)" = "200 text/plain" ]  || fail "/version.txt should serve, got: $(status /version.txt)"
[ "$(status /apix)" = "200 text/html" ]          || fail "/apix is not an API path and should fall back, got: $(status /apix)"

echo PASS
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/api-404.sh`
Expected: `FAIL: /api should be 404, got: 200 text/html`

- [ ] **Step 3: Add the two locations to `nginx.conf`**

Insert immediately before `location / {`:

```nginx
    # This server has no backend. Without these, a missing be-main made Traefik route
    # /api/* here and the SPA fallback below answered 200 text/html, so a dead backend
    # looked alive. 404, not 502: this server simply does not serve /api.
    # = /api as well: the backend's Ingress prefix /api matches /api itself.
    location = /api { return 404; }
    location ^~ /api/ { return 404; }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/api-404.sh`
Expected: `PASS`

- [ ] **Step 5: Commit (when the USER says commit)**

```bash
git add nginx.conf tests/api-404.sh
git commit -m "Answer 404 for /api instead of the SPA page

Without a backend Ingress, Traefik routed /api/* to this app and try_files
served index.html with 200, so a dead backend reported success.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: Defect B — one place reads `DEPLOY_SYSTEM`, normalises it, and refuses the unknown

**Repo:** `2026-kanso-fe-main-user` (plus one doc line in the platform repo)

Today both `ci/gitlab-build-deploy.sh` and the GitHub `gate` job do `system="$(cat DEPLOY_SYSTEM 2>/dev/null || echo github)"` and compare exactly. This is latent, not broken: the file is LF in git, Git Bash strips the `\r` from the CRLF working copy, and GitHub reads the LF checkout. It breaks on a Linux runner handed a CRLF copy, which is how files arrive in the airgapped target (export, not a normalising checkout). And a typo today makes **both** systems skip, with no error anywhere.

Design, as the brief suggested and here accepted: a small `ci/deploy-system.sh` that prints the normalised value and exits 1 on anything else; both entry points call it. One testable place instead of the same logic in a shell script and a YAML string. Three refinements, recorded:
- Callers run it as `bash ci/deploy-system.sh`, not `ci/deploy-system.sh`: the repo stores scripts `100644`, and `ubuntu-latest` would refuse to exec a non-executable file. Inside Git Bash, `bash` is Git's bash (the WSL caveat is for the PowerShell runner level only).
- It takes an optional repo-root argument so the test can point it at scratch files; default is the script's parent directory, so callers pass nothing.
- Case is folded too (`GitLab` → `gitlab`): free once whitespace is being stripped, and one less way to deploy nothing.

Sibling repos (`2026-kanso-be-main`, `2026-kanso-fe-dashboard`): **nothing changes.** Contrary to the brief, neither has a `gate` job or a `DEPLOY_SYSTEM` file on any branch; GitHub deploys them unconditionally, which is the documented default (missing = github). If a gate is ever added there, copy `ci/deploy-system.sh` and the two-line gate step from this task with it.

`.gitattributes`: new file in the app repo. It pins `DEPLOY_SYSTEM` and `*.sh` to LF, matching the platform repo's own `.gitattributes` (`*.sh text eol=lf` and friends). The index already holds LF for both, so no renormalisation commit results; the working copy flips to LF on the next checkout.

**Files:**
- Create: `ci/deploy-system.sh`
- Create: `.gitattributes`
- Create: `tests/deploy-system.sh`
- Modify: `ci/gitlab-build-deploy.sh:11-15`
- Modify: `.github/workflows/build-deploy.yml:33-36` (the `gate` job's `read` step)
- Modify (platform repo): `docs/guide/airgap-runbook.md:163-164` (the Gaps bullet), `docs/guide/github-to-gitlab.md:8-9`

**Interfaces:**
- Produces: `bash ci/deploy-system.sh [repo-root]` → prints `github` or `gitlab` followed by a newline, exit 0. Missing file → `github`. File present but, after `tr -d '[:space:]'` and lower-casing, not one of the two → message on stderr naming `DEPLOY_SYSTEM` and the value, exit 1.
- Consumed by: `ci/gitlab-build-deploy.sh` (skips with exit 0 when the value is `github`), the GitHub `gate` job (output `system`, read by `build-deploy`'s `if:`).

- [ ] **Step 1: Write the failing test** `tests/deploy-system.sh`

```bash
#!/usr/bin/env bash
# ci/deploy-system.sh decides which CI system deploys this app. The bug this guards:
# both CI systems compared the DEPLOY_SYSTEM file byte-for-byte and treated anything that
# was not their own name as "skip", so a CRLF copy (a Linux runner reading an exported
# Windows tree) or a typo deployed nothing anywhere, with no error on either side.
# Pure logic on scratch files; no cluster, no CI.
set -uo pipefail
cd "$(dirname "$0")/.."
fail() { echo "FAIL: $1" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "${tmp}"' EXIT
# with <printf format>: run the script against a scratch root whose DEPLOY_SYSTEM holds it
with() { printf "$1" > "${tmp}/DEPLOY_SYSTEM"; bash ci/deploy-system.sh "${tmp}" 2>&1; }

[ "$(with 'gitlab\n')" = gitlab ]     || fail "LF gitlab not read"
[ "$(with 'gitlab\r\n')" = gitlab ]   || fail "CRLF gitlab not read (the airgap case)"
[ "$(with ' GitHub \r\n')" = github ] || fail "whitespace and case not normalised"
[ "$(with 'github')" = github ]       || fail "file without a trailing newline not read"
rm -f "${tmp}/DEPLOY_SYSTEM"
[ "$(bash ci/deploy-system.sh "${tmp}" 2>&1)" = github ] || fail "a missing file should mean github"

out="$(with 'gitlub\n')" && fail "a typo was accepted: ${out}"
grep -q DEPLOY_SYSTEM <<<"${out}" || fail "the refusal should name the file: ${out}"
out="$(with '')" && fail "an empty file was accepted: ${out}"

[ "$(bash ci/deploy-system.sh)" = gitlab ] || fail "this repo's own DEPLOY_SYSTEM should read gitlab"

# Both CI entry points go through the script; neither reads the file inline any more
for f in ci/gitlab-build-deploy.sh .github/workflows/build-deploy.yml; do
  grep -q 'bash ci/deploy-system.sh' "${f}" || fail "${f} does not call ci/deploy-system.sh"
  grep -q 'cat DEPLOY_SYSTEM' "${f}" && fail "${f} still reads DEPLOY_SYSTEM inline"
done
grep -qx 'DEPLOY_SYSTEM text eol=lf' .gitattributes || fail ".gitattributes does not pin DEPLOY_SYSTEM to LF"

echo PASS
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/deploy-system.sh`
Expected: `FAIL: LF gitlab not read` (the script does not exist yet, so `with` prints bash's "No such file" and the comparison fails).

- [ ] **Step 3: Create `ci/deploy-system.sh`**

Header comment: what it prints, missing = github, why an unknown value exits 1 (both systems used to skip silently), usage `bash ci/deploy-system.sh [repo-root]`. `set -euo pipefail`. `root="${1:-$(dirname "$0")/..}"`. Read with `tr -d '[:space:]' < "${root}/DEPLOY_SYSTEM"` only if the file exists, lower-case with `${var,,}`, then a `case` on `github|gitlab` that prints the value; the `*` arm writes `DEPLOY_SYSTEM must say github or gitlab (missing = github); it says '<value>'` to stderr and exits 1.

- [ ] **Step 4: Create `.gitattributes`**

```
# Read by bash in CI (Linux runners and Git Bash alike): a CR at line end would end up in the value
DEPLOY_SYSTEM text eol=lf
*.sh text eol=lf
```

- [ ] **Step 5: Replace the inline read in `ci/gitlab-build-deploy.sh:11-15`**

```bash
# ci/deploy-system.sh exits 1 on a value it does not know; set -e stops the job there
system="$(bash ci/deploy-system.sh)"
if [ "${system}" != gitlab ]; then
  echo "DEPLOY_SYSTEM is ${system}, not gitlab; skipping"
  exit 0
fi
```

- [ ] **Step 6: Replace the `gate` job's read step in `.github/workflows/build-deploy.yml`**

Two lines, not one: `echo "system=$(...)"` would exit 0 with an empty value when the script fails, and `build-deploy` would skip exactly as before (Review Focus 4). GitHub's default Linux shell is `bash -e {0}`, so a failing assignment fails the step.

```yaml
      - id: read
        # bash ci/...: scripts are stored without the executable bit. An unknown value
        # fails this job instead of skipping the deploy on both systems.
        run: |
          system="$(bash ci/deploy-system.sh)"
          echo "system=${system}" >> "${GITHUB_OUTPUT}"
```

Also update the job's comment above `gate:` (lines 27-28) to add: `An unrecognised value fails here.`

- [ ] **Step 7: Run the test to verify it passes**

Run: `bash tests/deploy-system.sh`
Expected: `PASS`

Also run, from the repo root, the one check the test cannot make for the workflow YAML: `git diff --check` (no whitespace errors) and `bash -n ci/gitlab-build-deploy.sh ci/deploy-system.sh`. Expected: no output.

- [ ] **Step 8: Update the two platform docs** (platform repo, branch `defect-fixes`)

- `docs/guide/airgap-runbook.md:163-164`: delete the bullet `**`DEPLOY_SYSTEM`** is compared byte-for-byte, so a stray CRLF makes both CI systems skip silently.` — it is no longer a gap.
- `docs/guide/github-to-gitlab.md:8-9`: after `the other one's pipeline sees the file and skips.` add one sentence: `Both read it through the app repo's `ci/deploy-system.sh`, which ignores whitespace (a CRLF copy included) and case, and fails the job on any value other than `github` or `gitlab` rather than letting both systems skip.`

- [ ] **Step 9: Commit (when the USER says commit)** — one commit per repo

App repo:
```bash
git add ci/deploy-system.sh .gitattributes tests/deploy-system.sh ci/gitlab-build-deploy.sh .github/workflows/build-deploy.yml
git commit -m "Read DEPLOY_SYSTEM in one place; fail on an unknown value

Both CI systems compared the file byte-for-byte and skipped on anything that
was not their own name, so a CRLF copy or a typo deployed nothing anywhere.
ci/deploy-system.sh trims and lower-cases the value and exits 1 otherwise;
.gitattributes keeps the file LF.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```
Platform repo:
```bash
git add docs/guide/airgap-runbook.md docs/guide/github-to-gitlab.md
git commit -m "Docs: DEPLOY_SYSTEM is now normalised and guarded

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: Defect C — a manual GitLab deploy records who pressed the button

**Repo:** `2026-kubernetes-platform`

`ci/gitlab-job.sh:48` does `export DEPLOY_SOURCE="${SOURCE:-}"`. A trigger from an app repo sets `SOURCE=<repo>@<sha>`; "Run pipeline" in the UI sets nothing, so `ci/deploy.sh` writes `promote <image>` with no name. GitHub already writes `manual by <github.actor>` (`.github/workflows/deploy.yml:33`).

Which variable: GitLab's predefined-variables page (checked 2026-10-30) documents `GITLAB_USER_LOGIN` as "the unique username of the user who started the pipeline, **unless the job is a manual job. In manual jobs, the value is the username of the user who started the job.**" The same exception is stated for `GITLAB_USER_NAME`, `GITLAB_USER_ID` and `GITLAB_USER_EMAIL`. So `GITLAB_USER_LOGIN` is the documented answer for both `deploy-staging` (a web pipeline, the starter) and `deploy-prod` (`when: manual`, the presser). **This plan does not assert it behaves that way**; Task 5 step 6 reads the real history back, and its Expected line says what to do if the name is wrong.

Fallback when `GITLAB_USER_LOGIN` is unset (only outside GitLab): `manual by unknown`. The change-cause is a record, not a gate; failing a deploy over a missing informational variable would be the wrong trade. A caller can already set `SOURCE` to anything, which `ci/gitlab-job.sh`'s header acknowledges, so this adds no new trust in trigger variables.

`scripts/rollback.sh` writes `rollback to <image>` with no actor on both systems; unchanged here (see Not in this plan).

**Files:**
- Modify: `ci/gitlab-job.sh:48`
- Create: `tests/gitlab-actor.sh`
- Modify: `docs/guide/github-to-gitlab.md` (one table row after line 19)

**Interfaces:**
- Produces: `DEPLOY_SOURCE` exported as `SOURCE` when it is non-empty, else `manual by ${GITLAB_USER_LOGIN}`, else `manual by unknown`. `ci/deploy.sh` is unchanged and renders it as ` (<DEPLOY_SOURCE>)` after `deploy <image>` / `promote <image>`.

- [ ] **Step 1: Write the failing test** `tests/gitlab-actor.sh`

Offline: `ci/gitlab-job.sh` is copied into a scratch tree laid out like a runner checkout, with a stub `ci/deploy.sh` that prints `DEPLOY_SOURCE`, and a dummy key file placed where `check_key_file` expects File-type variables (`<CI_PROJECT_DIR>.tmp/`, as `tests/gitlab-job-guard.sh` does).

```bash
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
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/gitlab-actor.sh`
Expected: `FAIL: manual run should record the actor: ` (empty value after the colon).

- [ ] **Step 3: Change `ci/gitlab-job.sh:48`**

Replace `export DEPLOY_SOURCE="${SOURCE:-}"` with:

```bash
# A trigger from an app repo sets SOURCE (repo@commit). "Run pipeline" in the UI does not:
# record who did it instead, as the GitHub workflow does ("manual by <actor>"). GitLab
# documents GITLAB_USER_LOGIN as the pipeline's starter, except in manual jobs, where it
# is whoever pressed play.
export DEPLOY_SOURCE="${SOURCE:-manual by ${GITLAB_USER_LOGIN:-unknown}}"
```

Also add `GITLAB_USER_LOGIN` to the header comment's `Env in:` list (line 3).

- [ ] **Step 4: Run the tests to verify they pass, and that the guard test is untouched**

Run: `bash tests/gitlab-actor.sh && bash tests/gitlab-job-guard.sh && bash tests/gitlab-ci-config.sh`
Expected: `PASS` three times.

- [ ] **Step 5: Add the mapping row** in `docs/guide/github-to-gitlab.md`, after line 19:

`| `github.actor` in the change-cause (`manual by <actor>`) when a Deploy run has no `source` | `GITLAB_USER_LOGIN` in `ci/gitlab-job.sh` when the pipeline has no `SOURCE` | GitLab documents it as the pipeline's starter, or the job's starter for a manual job (`deploy-prod`). Read it back with `kubectl rollout history`. |`

- [ ] **Step 6: Commit (when the USER says commit)**

```bash
git add ci/gitlab-job.sh tests/gitlab-actor.sh docs/guide/github-to-gitlab.md
git commit -m "Record who ran a manual GitLab deploy in the change-cause

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: Live proof on both clusters (the user pushes and presses play)

**Files:** none; runs and checks. Both clusters up (`docker ps` shows `k3s` and `k3s-staging`). Before this task, staging runs fe-main-user `8a6edb3bddef`; the new app tree hash is called `T` below (`git rev-parse --short=12 'HEAD^{tree}'` on the app's `staging` after the merge). Every `curl` uses `127.0.0.1:8082` + `Host: staging.kanso.localhost` for staging and `127.0.0.1:8081` + `Host: kanso.localhost` for prod.

**Interfaces:**
- Consumes: Tasks 2-4 committed on both `defect-fixes` branches.

- [ ] **Step 1: USER: land and push the app branch.** In the app repo: `git checkout staging && git merge --ff-only defect-fixes`, then (on "push") `git push origin staging && git push gitlab staging`.

- [ ] **Step 2: Defect B, live (GitHub skips, GitLab builds).** Expected on GitHub (Actions → the `staging` run): `gate` succeeded with its log showing the `read` step ran `bash ci/deploy-system.sh`, `build-deploy` skipped. Expected on GitLab (app project → Pipelines): `build-deploy` built `registry.gitlab.com/tjm-thomas/2026-kanso-fe-main-user:T`, then the platform project's `deploy-staging` ran and passed.

- [ ] **Step 3: Defect A, live on staging.**

```bash
pw=$(cat .secrets/staging-password.txt)
curl -s -u "staging:$pw" -H 'Host: staging.kanso.localhost' http://127.0.0.1:8082/version.txt
curl -s -o /dev/null -w '%{http_code} %{content_type}\n' -u "staging:$pw" -H 'Host: staging.kanso.localhost' http://127.0.0.1:8082/api/status
curl -s -o /dev/null -w '%{http_code} %{content_type}\n' -u "staging:$pw" -H 'Host: staging.kanso.localhost' http://127.0.0.1:8082/no/such/page
MSYS_NO_PATHCONV=1 docker exec k3s-staging kubectl -n kanso-staging exec deploy/fe-main-user -- wget -S -q -O /dev/null http://localhost/api/status 2>&1 | head -1
```
Expected, line by line: `T`; `200 application/json` (be-main is present, so Traefik still routes `/api` to it: the fix must not change that); `200 text/html` (SPA fallback intact through the ingress); a line containing `404 Not Found` (busybox wget prints either the `-S` header or `server returned error: HTTP/1.1 404 Not Found`; both carry it). That last one is the frontend pod itself, asked directly, refusing `/api` — the case that used to answer 200, proven without removing be-main.

- [ ] **Step 4: USER: land and push the platform branch.** In the platform repo: `git checkout main && git merge --ff-only defect-fixes`, then (on "push") `git push origin main && git push gitlab main`. Expected: no pipeline on GitLab (a plain push creates none; `workflow:rules` allows only `trigger` and `web`).

- [ ] **Step 5: USER: promote `T` to prod by hand, through the truly manual job.** Platform project → Build → Pipelines → **Run pipeline**, ref `main`, variables `ACTION=deploy`, `APP=fe-main-user`, `ENV=prod`, `IMAGE=registry.gitlab.com/tjm-thomas/2026-kanso-fe-main-user:T`. Leave `SOURCE` out. Press play on `deploy-prod`. If a second GitLab account with Maintainer rights on the project is available, have **account 1 start the pipeline and account 2 press play**: that is the only way to tell the two documented behaviours apart.

- [ ] **Step 6: Defect C, read back.**

```bash
MSYS_NO_PATHCONV=1 docker exec k3s kubectl -n kanso-prod rollout history deploy/fe-main-user
curl -s -H 'Host: kanso.localhost' http://127.0.0.1:8081/version.txt
curl -s -o /dev/null -w '%{http_code} %{content_type}\n' -H 'Host: kanso.localhost' http://127.0.0.1:8081/api/status
MSYS_NO_PATHCONV=1 docker exec k3s kubectl -n kanso-prod exec deploy/fe-main-user -- wget -S -q -O /dev/null http://localhost/api/status 2>&1 | head -1
```
Expected: the newest revision's CHANGE-CAUSE is `promote registry.gitlab.com/tjm-thomas/2026-kanso-fe-main-user:T (manual by <login>)` where `<login>` is **the account that pressed play** (with one account: that account; the name must be non-empty and not `unknown`). Then `T`, `200 application/json`, a line containing `404 Not Found` (Defect A now in prod too).
If `<login>` is the pipeline starter and not the presser (only observable with two accounts), `GITLAB_USER_LOGIN` is wrong for this job despite the docs: switch `ci/gitlab-job.sh` to the job's own record, `curl -sS -f -H "JOB-TOKEN: ${CI_JOB_TOKEN}" "${CI_API_V4_URL}/job"` and take `.user.username` from the JSON (Git Bash on the runner has no `jq`; use `sed -n 's/.*"username":"\([^"]*\)".*/\1/p'`), keep `GITLAB_USER_LOGIN` as the fallback, extend `tests/gitlab-actor.sh` with a stubbed `curl` on `PATH`, and record the finding in the `github-to-gitlab.md` row from Task 4 step 5. If `<login>` is empty or `unknown`, the variable did not reach the job: check the job log's variable section first, then the same fallback.

- [ ] **Step 7: USER: bring the app's `main` level with `staging`.** In the app repo: `git checkout main && git merge --ff-only staging`, push both remotes on "push". Expected: the app pipeline on `main` builds nothing and triggers `deploy-prod`; pressing play ends in `fe-main-user in prod already runs ...:T; nothing to do` (exit 0, history unchanged). This keeps the branch model honest after the by-hand promote.

- [ ] **Step 8: Log-hygiene check.** In the GitLab job logs for steps 2 and 5, search for `BEGIN CERTIFICATE`, `glptt`, `glrt` and the staging password's first four characters (read them with `pw=$(cat .secrets/staging-password.txt); echo "${pw:0:4}"` only into your own terminal). Expected: no hits. Nothing to commit.

---

## Not in this plan

- **Governing `setup.sh` through a manual CI job with a narrowed `platform-admin` service account.** A new privileged identity and a new RBAC surface; it needs its own design, and none of the three defects depends on it.
- **Post-deploy verification of what the ingress actually serves.** The right end-state for Defect A, but it means the deploy job curling through the ingress with environment credentials; a separate feature with its own secret handling.
- **`imagePullSecrets` for an authenticated registry.** Blocked on the airgap registry owner's answers (runbook, "Still to confirm" 1-2).
- **Recording deployed images in git for automatic disaster recovery.** The ledger (Task 1) lives in the cluster by design; moving the record to git changes the push model's source of truth and is a roadmap decision, not a defect.
- **Letting `ci/deploy.sh` write the image ledger.** Needs a ConfigMap `patch` verb on the per-app deployer keys, which the Global Constraints forbid widening.
- **An actor on rollbacks** (`scripts/rollback.sh` writes `rollback to <image>` on both systems). Same shape as Defect C but not in the test run's findings; one line, if wanted, after Task 5 confirms which variable is right.
- **Adding the `DEPLOY_SYSTEM` gate to `be-main` and `fe-dashboard`.** They have none and are GitHub-only; adding one is a feature, not a fix. The brief assumed they had it; they do not.

## Self-review

1. **Coverage.** Defect A → Task 2 (both locations, `^~` reasoning, local Docker test, live proof Task 5 steps 3 and 6). Defect B → Task 3 (strip/normalise, `.gitattributes`, non-zero exit, both callers, sibling repos answered, runbook gap removed, live proof Task 5 step 2). Defect C → Task 4 (documented variable, offline test, uncertainty carried to Task 5 steps 5-6 with the two-account check and the job-API fallback). Commit of pending work → Task 1. Test placement for A and B justified in Task 2. "Not in this plan" has the five requested lines plus two found while reading.
2. **Steps.** Each test is full code; each code step gives file, exact lines or insertion point, and the exact text or a one-line approach. `ci/deploy-system.sh` is specified by interface plus the test, body left to the implementer. No "TBD".
3. **Names.** `ci/deploy-system.sh`, `tests/api-404.sh`, `tests/deploy-system.sh`, `tests/gitlab-actor.sh`, `fe-main-user-test`/`18088`, `DEPLOY_SOURCE`, `GITLAB_USER_LOGIN`, `T` are used consistently across tasks.
4. **Review Focus.** All five pinned: 1-2 in Task 2's test (`/api`, `/release`, `/no/such/page`, `/apix`), 3 in Task 3's test (empty, ` GitHub \r\n`), 4 in Task 3 step 6 plus the static grep, 5 in Task 4's test (`SOURCE=` empty).
5. **Proportion.** Three fixes of a few lines each; the plan is mostly tests, verification commands and recorded decisions, which is where the judgement in this change lives.
