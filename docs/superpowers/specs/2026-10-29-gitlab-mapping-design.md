# GitLab Mapping Design (Phase 6)

**Date:** 2026-10-29
**Status:** draft, awaiting approval

## Intent

Map the kanso platform's push-model CD from GitHub Actions/GHCR onto public
gitlab.com, group `tjm-thomas`, so the same working method carries over to the
real target: an airgapped, enterprise-grade self-managed GitLab. The pilot
proves the method; the adjustments doc records everything the airgapped side
must change.

Success is visible, not abstract: the user watches a push to `staging` land on
the staging cluster, and an admin-pressed button land the same image on prod,
all through GitLab.

## Who it's for

Developers on the airgapped side. They push freely to an app's `staging`
branch and it deploys itself; getting to prod requires a merge to `main` plus
an explicit admin action. Same as GitHub today.

## Goals

- Platform repo and `fe-main-user` on GitLab with working pipelines:
  deploy to staging on push, gated deploy to prod, rollback.
- Free-tier features only, so everything works unchanged on Premium/Ultimate.
- GitHub keeps working alongside as the fallback; one system deploys a given
  app at a time.
- `docs/guide/github-to-gitlab.md`: every GitHub→GitLab difference, and the
  optional enterprise upgrades (protected environments, deployment approvals).

## Non-goals

- Moving `be-main` and `fe-dashboard` (later, same recipe).
- Premium features (deployment approvals, protected environments, group-level
  variable scoping) — documented, not built.
- Mirroring automation between GitHub and GitLab; pushing to both remotes by
  hand is fine for the pilot.
- Quality gates before the staging deploy (code scanning, Parasoft) — a later
  phase. The pipeline shape leaves room: they become stages before the
  deploy-trigger stage, inside the app repo's pipeline.
- Touching the clusters' design: the k3s setup, scripts, RBAC stay as they are.

## Anti-goals

- A GitLab port that drifts from GitHub. The shell scripts stay single,
  shared copies; CI files are thin wrappers around them.
- Both systems deploying the same app and fighting over images.
- Secrets in public projects' code or logs; prod keys reachable from a
  `staging` pipeline.

## Decisions already made (the user's)

- Public projects in group `tjm-thomas` (the real deployment is airgapped, so
  gitlab.com visibility hardly matters).
- Prod gate stays admin-approval-shaped, like GitHub.
- GitHub runs alongside as fallback.
- Order: platform repo first, then `fe-main-user`.

## Design (the builder's how — my calls)

### One repo, two homes

Each repo keeps one local working copy with two remotes (`origin` = GitHub,
`gitlab` = GitLab). `.github/workflows/` and `.gitlab-ci.yml` sit side by
side; each system ignores the other's files. Shared bash scripts
(`ci/deploy.sh`, `scripts/*`) are the single source of behaviour for both.

### Images: GitLab container registry

App pipelines build to `registry.gitlab.com/tjm-thomas/<repo>:<git tree hash>`
— same tagging scheme as GHCR. Public projects ⇒ public registry ⇒ clusters
pull anonymously, no pull secret.

**My call — the image-provenance guard allows both registries.** `ci/deploy.sh`
rejects images whose repo differs from `IMAGE_REPO` in `apps/<app>/app.env`;
as-is, the first GitLab deploy would be refused. `IMAGE_REPO` becomes a
space-separated allow-list (the app's GHCR repo and its GitLab-registry repo,
both under tjm-thomas control). Chosen over flipping `IMAGE_REPO` together
with `DEPLOY_SYSTEM`, because that would make the GitHub fallback a
flip-and-commit instead of a button press — and the fallback being instant is
the point of keeping GitHub. The airgapped side has one registry, so its list
has one entry; noted in the adjustments doc.

### Triggering the platform deploy

GitHub: app repo calls `workflow_dispatch` with `PLATFORM_DEPLOY_TOKEN`.
GitLab: app repo starts the platform project's pipeline with a **pipeline
trigger token** (free tier), passing `APP`, `ENV`, `IMAGE`, `SOURCE` as
variables. The trigger token is a masked, **protected** CI/CD variable in each
app project.

**My call — `staging` becomes a protected branch in GitLab app repos**
(allowed to push: Developers; allowed to force-push: no one). A protected
variable is only handed to pipelines on protected refs, so an unprotected
`staging` would never receive the trigger token; the alternative — an
unprotected token — would let any Developer exfiltrate it from a throwaway
branch pipeline and start prod-targeted platform pipelines. "Push freely"
survives: Developers still push to `staging` without review; they just can't
force-push or delete it, which matches normal enterprise practice anyway.
Goes in the adjustments doc as part of the mapping.

### Platform pipeline (`.gitlab-ci.yml` in the platform repo)

Jobs mirror the GitHub workflows:

- `deploy` — runs `ci/deploy.sh "$APP" "$ENV" "$IMAGE"`; runs when triggered
  (trigger token) or started by hand ("Run pipeline" with variables = the
  Actions-tab equivalent).
- `rollback` — manual, runs `scripts/rollback.sh "$APP" "$ENV"`.

Runner chosen by tag `k3s-staging` / `k3s-prod` (same labels as GitHub).

### Prod gate on the free tier

Protected environments and approvals are Premium, so free uses protected
branches + protected variables:

- `main` is a protected branch; only Maintainers/Owners can merge or push.
- The prod deploy path is a **manual job** attached to environment `prod`.
- Prod keys (`DEPLOYER_KUBECONFIG_*` for prod, `STAGING_READER_KUBECONFIG`)
  are **protected** variables scoped to environment `prod`: GitLab hands them
  only to jobs on protected refs, so a `staging` pipeline can never read them.
- `ci/deploy.sh` keeps its own guards regardless of CI system: prod only
  accepts the image staging runs, and only if staging is healthy.

**Pilot must confirm:** that a non-Maintainer cannot run the prod manual job
on the protected ref. If free-tier GitLab lets any Developer press it, the
gate is the protected variables (the job runs but has no prod key and fails) —
weaker but still safe; the finding goes in the adjustments doc either way.

On enterprise: add protected environment `prod` + a deployment approval rule.
Settings change only; no code change. Documented as the upgrade path.

### Runner

`gitlab-runner` installed on this PC next to the GitHub Actions runner,
registered to the platform project with tags `k3s-staging,k3s-prod`, shell
executor. Builder must verify Git Bash works as the shell (gitlab-runner on
Windows defaults to PowerShell; it supports `shell = "bash"` config — if that
fights with path mangling, fall back to a thin PowerShell step that execs
`bash ci/deploy.sh ...`). App projects use the shared gitlab.com SaaS runners
for builds (docker images, no cluster access needed).

### Which system deploys an app

One switch per **app** repo, visible and dumb: a committed file
`DEPLOY_SYSTEM` (contents `github` or `gitlab`) at the repo root. Both CI
configs in the app repo read it as their first step and exit cleanly (skip
build+deploy) if they're not the chosen system. A missing file means
`github`, so `be-main` and `fe-dashboard` need no edits. Pilot setting:
`fe-main-user` → `gitlab`; the others stay on GitHub.

**My call — the platform repo itself has no switch.** It serves both systems
at once: its GitHub workflows keep deploying `be-main` and `fe-dashboard`,
its GitLab pipeline deploys `fe-main-user`. Routing is enforced where the
deploy starts (the app repo's switch); a manual run of either platform
pipeline is an admin action and is trusted, same as today's Actions tab.

### Secrets inventory (GitLab side)

| Where | Variable | Equivalent on GitHub |
|---|---|---|
| platform project | `DEPLOYER_KUBECONFIG_<APP>` (scoped to env `staging` / `prod`, protected for prod) | environment secrets |
| platform project | `STAGING_READER_KUBECONFIG` (scoped env `prod`, protected) | prod environment secret |
| each app project | `PLATFORM_TRIGGER_TOKEN` (masked, protected) | `PLATFORM_DEPLOY_TOKEN` |

All set by the user in the GitLab UI; I never see values.

### Adjustments doc

`docs/guide/github-to-gitlab.md` — one row per difference: GitHub thing →
GitLab thing → why → what the airgapped side must additionally change
(registry URL, runner tags, enterprise upgrades, trigger tokens).

## Constraints

- gitlab.com free tier; features must exist on Premium/Ultimate unchanged.
- Windows host; runner executes bash scripts via Git Bash.
- Public repos: no secrets in code, logs, or committed files.
- The user performs every action needing their GitLab login (creating
  projects, setting variables, pressing prod deploy); I get read-only `glab`.
- gitlab.com requires one-time account validation (credit-card check, not a
  charge) before the free shared SaaS runners run pipelines. The app build
  job needs a runner: either the user validates the account, or our own PC
  runner also takes app builds (it has Docker). User decides when we hit it.

## What's left to the builder

- Exact `.gitlab-ci.yml` syntax, job names, rules.
- gitlab-runner install/registration mechanics on Windows and the bash-shell
  verification.
- Whether the platform Setup needs a pipeline at all (likely not for the
  pilot; it runs locally).
- How `fe-main-user`'s build job translates (its GitHub build steps → GitLab
  job), keeping the tree-hash tag identical.
