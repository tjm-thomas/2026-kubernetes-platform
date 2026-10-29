# GitLab Mapping Implementation Plan (Phase 6)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The platform repo and `2026-kanso-fe-main-user` deploy through public gitlab.com (group `tjm-thomas`) exactly as they do through GitHub today — push to `staging` deploys itself, prod needs an admin's button press — while GitHub keeps deploying `be-main` and `fe-dashboard`.

**Architecture:** One local repo, two remotes (`origin`=GitHub, `gitlab`=GitLab). `.gitlab-ci.yml` files are thin wrappers that call shared bash scripts via Git Bash; the deploy logic stays in `ci/deploy.sh`. Free-tier GitLab features only: protected branches + protected/scoped CI variables stand in for GitHub environments, a manual job stands in for required reviewers, a pipeline trigger token stands in for `workflow_dispatch`.

**Tech Stack:** GitLab CI (free tier), gitlab-runner (shell executor, Windows), GitLab container registry, bash (Git Bash), existing k3s clusters, `glab` (read-only) for verification.

**Spec:** `docs/superpowers/specs/2026-10-29-gitlab-mapping-design.md`

## Global Constraints

- Free-tier features only; nothing that exists only in Premium/Ultimate.
- Secrets never in code, logs, or committed files; the USER sets every secret value in the GitLab UI and performs every action needing their GitLab login. The executor's `glab` token is read-only.
- Commits are local per task; nothing is pushed to GitHub or GitLab except in steps marked push, and pushes to a remote are USER-approved actions (the four-stops rule covers them).
- Steps marked **USER:** are performed by the human partner; the executor presents them, waits, then verifies.
- Shared scripts (`ci/deploy.sh`, `scripts/*`) must keep working for GitHub unchanged — the GitHub path for `be-main`/`fe-dashboard` must never break.
- Windows runner: plain `bash` resolves to WSL; always invoke Git Bash as `C:\PROGRA~1\Git\bin\bash.exe --noprofile --norc -eo pipefail <script>`.
- gitlab-runner's shell executor on Windows only offers PowerShell shells, so every GitLab job's `script:` is a single line that calls a bash script; logic lives in the script.
- Image tags stay the git tree hash: `git rev-parse --short=12 'HEAD^{tree}'`.
- Both clusters must be up for the test steps (`cd cluster && docker compose up -d`).

## Review Focus

- A Developer (non-Maintainer) pressing the prod manual job: free tier may not block the button, and the backstop is that prod keys are protected variables an unprotected ref never receives — Task 6 step 8 exercises the no-key refusal; whether the button itself is blocked is confirmed by inspection and recorded in the adjustments doc.
- A plain `git push` to the platform repo on GitLab must create **no** pipeline (`workflow:rules` allows only `trigger` and `web`) — Task 3 step 5 verifies after the first push.
- Kubeconfig **file**-type variables on a Windows runner: GitLab hands a Windows path, possibly with CRLF content; `ci/gitlab-job.sh` must pass it to `kubectl` unmangled — exercised live by Task 6 step 3 (first staging deploy).
- The trigger token must never appear in job logs: masked variable, `curl -sS` without `set -x` in `ci/gitlab-build-deploy.sh` — Task 6 step 3 includes a log grep.
- A manual GitHub "Run workflow" for a GitLab-owned app can still overwrite its deployment (spec: admin actions are trusted) — documented in the adjustments doc (Task 7), not coded against.

---

### Task 1: Image guard accepts an allow-list of registries

`ci/deploy.sh:21-24` rejects any image whose repo isn't exactly `IMAGE_REPO`. Per the spec, `IMAGE_REPO` becomes a space-separated allow-list.

**Files:**
- Modify: `ci/deploy.sh:21-24`
- Modify: `apps/fe-main-user/app.env:5`
- Create: `tests/image-guard.sh` (committed; needs both clusters up)

**Interfaces:**
- Produces: `IMAGE_REPO` in `app.env` may hold several space-separated repos and must then be quoted: `IMAGE_REPO="repo1 repo2"`. `deploy.sh` accepts an image when `${IMAGE%:*}` equals any listed repo. Error message keeps its prefix: `<app> only runs images from: <list> ...`.

- [ ] **Step 1: Write the failing test** `tests/image-guard.sh`

```bash
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
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/image-guard.sh`
Expected: `FAIL: gitlab repo does not pass the guard: ... only runs images from ...` (first two checks already pass today; nothing on either cluster changes — the fake tags are refused by the prod gate).

- [ ] **Step 3: Implement the allow-list**

In `apps/fe-main-user/app.env`, replace line 5 with
`IMAGE_REPO="ghcr.io/tjm-thomas/2026-kanso-fe-main-user registry.gitlab.com/tjm-thomas/2026-kanso-fe-main-user"` (and extend its comment: space-separated allow-list, one entry per registry that may build this app).
In `ci/deploy.sh`, replace the `!=` comparison with a loop over the unquoted `${IMAGE_REPO}` words that sets a match flag; refusal message: `"${APP} only runs images from: ${IMAGE_REPO} (see apps/${APP}/app.env), not ${IMAGE}"`. `be-main` and `fe-dashboard` app.envs stay single-entry and untouched.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/image-guard.sh`
Expected: `PASS`

- [ ] **Step 5: Regression: a GitHub-shaped staging deploy still works**

Run: `ci/deploy.sh fe-dashboard staging "$(MSYS_NO_PATHCONV=1 docker exec k3s-staging kubectl -n kanso-staging get deploy fe-dashboard -o jsonpath='{.spec.template.spec.containers[0].image}')"`
Expected: `fe-dashboard in staging already runs ...; nothing to do` (guard passed, no change made).

- [ ] **Step 6: Commit**

```bash
git add ci/deploy.sh apps/fe-main-user/app.env tests/image-guard.sh
git commit -m "Allow a per-app list of image registries"
```

### Task 2: GitLab projects, second remotes, history pushed

**Files:** none changed (git config + remote state only)

**Interfaces:**
- Produces: remote `gitlab` = `https://gitlab.com/tjm-thomas/<repo>.git` in both local repos; GitLab projects hold the full `main` + `staging` history; later tasks push to both remotes.

- [ ] **Step 1: USER: create two blank projects in group `tjm-thomas`** — names exactly `2026-kubernetes-platform` and `2026-kanso-fe-main-user`, visibility Public, **no** README/initial commit.

- [ ] **Step 2: USER: create a git-push token** — gitlab.com → Personal access tokens → legacy/classic style, name `git-push`, scope `write_repository`, ~90 days. Store it with `git credential-manager` on first push (git prompts; username = `thomasjmtan`, password = the token). The executor never sees the value.

- [ ] **Step 3: Add the `gitlab` remote to both repos**

Run (in `2026-kubernetes-platform`, then in `../2026-kanso-fe-main-user`):
`git remote add gitlab https://gitlab.com/tjm-thomas/<repo>.git && git remote -v`
Expected: `gitlab` listed alongside `origin`.

- [ ] **Step 4: Push history to GitLab (USER approves; git may prompt for the token once)**

Run in each repo: `git push gitlab main staging`
Expected: both branches created on GitLab.

- [ ] **Step 5: Verify via glab**

Run: `& "$env:LOCALAPPDATA\Programs\glab\glab.exe" api projects/tjm-thomas%2F2026-kubernetes-platform | ConvertFrom-Json | % { $_.default_branch }` (and the same for the app project)
Expected: `main` for both; no errors.

### Task 3: Platform `.gitlab-ci.yml` + `ci/gitlab-job.sh`

**Files:**
- Create: `.gitlab-ci.yml` (platform repo root)
- Create: `ci/gitlab-job.sh`

**Interfaces:**
- Consumes: `ci/deploy.sh <app> <env> <image>` and `scripts/rollback.sh <app> <env>` (unchanged).
- Produces: a platform pipeline started by trigger token or by hand ("Run pipeline") with variables `APP`, `ENV`, `IMAGE`, `SOURCE` (optional), `ACTION` (`deploy` default / `rollback`). Jobs: `deploy-staging` (auto), `deploy-prod` (`when: manual`), `rollback` (`when: manual`). Task 5's trigger call relies on these variable names.

- [ ] **Step 1: Write `ci/gitlab-job.sh`**

Env in: `ACTION` (default `deploy`), `APP`, `ENV`, `IMAGE`, `SOURCE`, plus GitLab **file**-variables `DEPLOYER_KUBECONFIG_<APP tr a-z- A-Z_>` and `STAGING_READER_KUBECONFIG` (paths to temp files GitLab wrote). The script: validates `APP` against `^[a-z0-9][a-z0-9-]*$`; resolves the per-app variable name with bash indirect expansion; errors `"variable DEPLOYER_KUBECONFIG_<APP> is not set for ${ENV}"` (exit 1) when empty — this is the no-key refusal Review Focus relies on; exports `DEPLOYER_KUBECONFIG`, `STAGING_READER_KUBECONFIG` (when set), `DEPLOY_SOURCE="${SOURCE:-}"`; runs `ci/deploy.sh` or `scripts/rollback.sh` per `ACTION`. Never prints variable values.

- [ ] **Step 2: Test the wrapper locally (RED first)**

Run: `ACTION=deploy APP=fe-main-user ENV=staging IMAGE=x:y bash ci/gitlab-job.sh`
Expected before implementing: `bash: ci/gitlab-job.sh: No such file or directory`; after: `variable DEPLOYER_KUBECONFIG_FE_MAIN_USER is not set for staging`, exit 1.
Then with a real key: `ACTION=deploy APP=fe-main-user ENV=staging DEPLOYER_KUBECONFIG_FE_MAIN_USER="$(./scripts/make-deployer-kubeconfig.sh fe-main-user staging)" IMAGE="<image staging currently runs, from Task 1 step 5's jsonpath>" bash ci/gitlab-job.sh`
Expected: `... already runs ...; nothing to do`.

- [ ] **Step 3: Write `.gitlab-ci.yml`**

`workflow:rules`: create a pipeline only when `$CI_PIPELINE_SOURCE == "trigger" || $CI_PIPELINE_SOURCE == "web"`. Three jobs, each `script:` a single line `C:\PROGRA~1\Git\bin\bash.exe --noprofile --norc -eo pipefail ci/gitlab-job.sh`:
- `deploy-staging`: rules `$ACTION != "rollback" && $ENV == "staging"`; `tags: [k3s-staging]`; `environment: {name: staging}`; variables `ACTION: deploy`.
- `deploy-prod`: rules `$ACTION != "rollback" && $ENV == "prod"`, `when: manual`; `tags: [k3s-prod]`; `environment: {name: prod}`; variables `ACTION: deploy`.
- `rollback`: rules `$ACTION == "rollback"`, `when: manual`; `tags: ["k3s-${ENV}"]`; `environment: {name: "${ENV}"}`.
Comment the file the way `.github/workflows/deploy.yml` is commented (what may run it, where secrets live).

- [ ] **Step 4: Lint, commit, push both remotes (USER approves the pushes)**

Run: `git add .gitlab-ci.yml ci/gitlab-job.sh && git commit -m "Add GitLab pipeline: deploy and rollback jobs"` then `glab ci lint` (full path to glab.exe), then `git push origin main && git push gitlab main`.
Expected: lint `valid`; both pushes accepted; **no** workflow run on GitHub (deploy.yml is dispatch-only).

- [ ] **Step 5: Verify the push created no GitLab pipeline**

Run: `& "$env:LOCALAPPDATA\Programs\glab\glab.exe" api "projects/tjm-thomas%2F2026-kubernetes-platform/pipelines"`
Expected: `[]`.

### Task 4: gitlab-runner on this PC (group runner)

**Files:** none in the repos (runner config lives in the runner's install dir)

**Interfaces:**
- Produces: one group runner for `tjm-thomas`, shell executor (PowerShell), tags `k3s-staging,k3s-prod,builder`, `run_untagged=false`. Tasks 5–6 jobs select it by tag.

- [ ] **Step 1: Install gitlab-runner**

Run: `winget install --id GitLab.GitLabRunner -e` (or the documented manual binary install to `C:\GitLab-Runner`). Expected: `gitlab-runner --version` prints a version (new shell for PATH).

- [ ] **Step 2: USER: create the runner in GitLab** — group `tjm-thomas` → Build → Runners → New group runner; tags `k3s-staging, k3s-prod, builder`; untick "Run untagged jobs". Copy the `glrt-…` authentication token into the register command the executor prepares (USER pastes it; it is a secret).

- [ ] **Step 3: Register + start (USER runs; needs the token and admin shell)**

`gitlab-runner register --non-interactive --url https://gitlab.com --token <glrt-…> --executor shell --shell pwsh` (fall back to `--shell powershell` if pwsh is absent), then `gitlab-runner install && gitlab-runner start`.
Expected: `gitlab-runner verify` says alive; the group's runner page shows it online.

- [ ] **Step 4: Prove a job runs bash**

USER runs "Run pipeline" on the platform project (ref `main`) with `ACTION=deploy, APP=fe-main-user, ENV=staging, IMAGE=<image staging currently runs>`. No variables are set yet, so Expected: job `deploy-staging` runs on the new runner and **fails** with `variable DEPLOYER_KUBECONFIG_FE_MAIN_USER is not set for staging` — proving checkout, Git Bash invocation and the wrapper all work. Verify the log line via `glab ci trace` or the UI.

### Task 5: Variables, protections, and the fe-main-user GitLab pipeline

**Files (in `../2026-kanso-fe-main-user`):**
- Create: `.gitlab-ci.yml`, `ci/gitlab-build-deploy.sh`, `DEPLOY_SYSTEM` (content: `gitlab`)
- Modify: `.github/workflows/build-deploy.yml` (gate job)

**Interfaces:**
- Consumes: Task 3's pipeline contract (`APP`, `ENV`, `IMAGE`, `SOURCE` via trigger API, ref `main`).
- Produces: `DEPLOY_SYSTEM` file convention — missing file means `github`; both CI systems read it before building anything.

- [ ] **Step 1: USER: platform project settings** (Settings → CI/CD):
  - Variables, all **file** type except noted, Protected ✓, Masked where allowed: `DEPLOYER_KUBECONFIG_FE_MAIN_USER` scoped to env `staging` (value: contents of `./scripts/make-deployer-kubeconfig.sh fe-main-user staging`), a second variable with the same key scoped to env `prod` (prod key), `STAGING_READER_KUBECONFIG` scoped to env `prod` (from `./scripts/make-reader-kubeconfig.sh`). The executor generates the files and prints their paths; USER pastes contents.
  - Pipeline trigger tokens: add one, description `fe-main-user`; USER copies it for step 2.
  - Protected branches: `main` already protected by default — confirm Maintainers-only merge/push; protect `staging` too (allowed to merge/push: Developers + Maintainers, no force push).
- [ ] **Step 2: USER: app project settings** — variable `PLATFORM_TRIGGER_TOKEN` (masked, protected, plain not file); protect `staging` exactly as above. Also note the platform project's numeric ID (project home page) for step 3.

- [ ] **Step 3: Write `ci/gitlab-build-deploy.sh`**

A bash port of `.github/workflows/build-deploy.yml`'s steps, reading GitLab's predefined vars: gate first (`[ "$(cat DEPLOY_SYSTEM 2>/dev/null || echo github)" = gitlab ] || { echo "DEPLOY_SYSTEM is not gitlab; skipping"; exit 0; }`); `IMAGE_REPO="${CI_REGISTRY_IMAGE,,}"`; tag `$(git rev-parse --short=12 'HEAD^{tree}')`; `ENV` = `prod` when `CI_COMMIT_BRANCH=main`, else `staging`; build+push only on staging and only if `docker manifest inspect` misses (login: `docker login -u gitlab-ci-token -p "${CI_JOB_TOKEN}" "${CI_REGISTRY}"`); anonymous-pull check with `docker logout`; trigger via `curl -sS -X POST "https://gitlab.com/api/v4/projects/${PLATFORM_PROJECT_ID}/trigger/pipeline" -F "token=${PLATFORM_TRIGGER_TOKEN}" -F ref=main -F "variables[APP]=fe-main-user" -F "variables[ENV]=${ENV}" -F "variables[IMAGE]=${IMAGE}" -F "variables[SOURCE]=${CI_PROJECT_PATH}@${CI_COMMIT_SHORT_SHA}"` — never echo the token, no `set -x`. `PLATFORM_PROJECT_ID` is a plain variable in `.gitlab-ci.yml`.

- [ ] **Step 4: Write the app `.gitlab-ci.yml`**

One job `build-deploy`: `rules` on `$CI_COMMIT_BRANCH == "staging" || $CI_COMMIT_BRANCH == "main"`, `tags: [builder]`, script = the one-line Git Bash invocation of `ci/gitlab-build-deploy.sh`, variable `PLATFORM_PROJECT_ID: "<ID from step 2>"`, `GIT_DEPTH: "0"` (tree hash needs real objects, not a shallow stub — builder verifies and may drop it).

- [ ] **Step 5: Gate the GitHub workflow**

In `.github/workflows/build-deploy.yml`: new first job `gate` (ubuntu-latest) that checks out and sets output `system=$(cat DEPLOY_SYSTEM 2>/dev/null || echo github)`; existing job gets `needs: gate` and `if: needs.gate.outputs.system == 'github'`. Create `DEPLOY_SYSTEM` containing `gitlab`.

- [ ] **Step 6: Commit on `staging` (do not push yet — Task 6 starts with this push)**

```bash
git checkout staging
git add .gitlab-ci.yml ci/gitlab-build-deploy.sh DEPLOY_SYSTEM .github/workflows/build-deploy.yml
git commit -m "Move deploys to GitLab (DEPLOY_SYSTEM=gitlab)"
```

### Task 6: End-to-end proof (the user watches)

**Files:** none; this task is runs and checks. Both clusters up.

- [ ] **Step 1: Push Task 5's commit to both remotes (USER approves)** — `git push origin staging && git push gitlab staging`.
- [ ] **Step 2: GitHub skips.** Check the `gate` job: run concluded success with `build-deploy` skipped. Expected: no GHCR build, no platform Deploy run on GitHub.
- [ ] **Step 3: GitLab deploys staging.** App pipeline on `staging` builds `registry.gitlab.com/tjm-thomas/2026-kanso-fe-main-user:<tree hash>`, triggers the platform; `deploy-staging` runs. Verify: `curl.exe -s -u staging:<password> -H "Host: staging.kanso.localhost" http://127.0.0.1:8082/version.txt` returns the new tree hash; `glab ci trace` of both jobs shows no token/secret values (grep the logs for the token prefix `glptt`/`glrt` and the word `BEGIN CERTIFICATE` — expect no hits).
- [ ] **Step 4: USER: merge `staging` → `main`** in the app repo, push both remotes. App pipeline on `main` builds nothing, triggers platform with `ENV=prod`.
- [ ] **Step 5: USER: press play on `deploy-prod`** in the platform project's pipeline. Expected: `ci/deploy.sh` prod gate passes (staging runs that image), prod rolls; `curl.exe -s -H "Host: kanso.localhost" http://127.0.0.1:8081/version.txt` returns the same tree hash; rollout history change-cause starts `promote `.
- [ ] **Step 6: Rollback via GitLab.** USER: Run pipeline (ref `main`) with `ACTION=rollback, APP=fe-main-user, ENV=prod`, press play. Expected: prod `version.txt` shows the previous hash; history change-cause starts `rollback to `.
- [ ] **Step 7: Promote again.** USER: Run pipeline with `ACTION=deploy, APP=fe-main-user, ENV=prod, IMAGE=<the tree-hash image>`, press play. Expected: prod back on the new hash.
- [ ] **Step 8: No-key refusal (Review Focus).** USER: Run pipeline on ref **`staging`** of the platform repo (web source; unprotected ref gets no protected variables) with `ACTION=deploy, APP=fe-main-user, ENV=prod, IMAGE=<same image>`; press play on `deploy-prod`. Expected: job fails with `variable DEPLOYER_KUBECONFIG_FE_MAIN_USER is not set for prod`; prod untouched. Also confirm by inspection (UI: who may run the manual job) whether a Developer could press play at all, and record the answer for Task 7.
- [ ] **Step 9: Ledger the results.** No commit (nothing changed).

### Task 7: Docs — the adjustments guide and pointers

**Files:**
- Create: `docs/guide/github-to-gitlab.md`
- Modify: `README.md` (remotes + "two CI systems" paragraph + GitLab URLs), `docs/guide/how-deploys-work.md` (one paragraph: the same push model on GitLab), `docs/guide/add-an-app.md` (pointer line to the new guide), `docs/CLAUDE.kanso-platform.md` (GitLab facts: group, registry, runner tags)

**Interfaces:**
- Consumes: Task 6 step 8's finding about who can press the prod button.

- [ ] **Step 1: Write `docs/guide/github-to-gitlab.md`** — a mapping table, one row per difference, columns *GitHub → GitLab → why → what the airgapped side changes*. Rows at minimum: workflows→`.gitlab-ci.yml`+wrapper scripts; `workflow_dispatch`+PAT→trigger token; environment secrets→protected variables scoped to environments (file type); required reviewers→manual `deploy-prod` job + protected `main` (+ the step-8 finding; enterprise upgrade: protected environments + deployment approvals, settings only); GHCR→GitLab registry (and the `IMAGE_REPO` allow-list, one entry when airgapped); runner labels→runner tags (airgapped: existing enterprise runners, see phase-8 questions); `staging` branch now protected (Developers may push, nobody force-pushes); DEPLOY_SYSTEM switch (missing = github); account validation or own runner for builds; build-from-source vs image-import variant (scan stages slot before the trigger stage).
- [ ] **Step 2: Update the three existing docs + CLAUDE file** as listed under Files; keep each change short and in the file's existing voice.
- [ ] **Step 3: Commit; push both remotes when USER says push**

```bash
git add docs/guide/github-to-gitlab.md README.md docs/guide/how-deploys-work.md docs/guide/add-an-app.md docs/CLAUDE.kanso-platform.md
git commit -m "Document the GitHub-to-GitLab mapping"
```
