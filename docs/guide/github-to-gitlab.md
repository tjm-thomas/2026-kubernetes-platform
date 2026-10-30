# GitHub to GitLab: the mapping

The platform runs the same push-model CD on GitHub and on GitLab (gitlab.com, group
`tjm-thomas`). The shell scripts are identical on both; only the thin CI layer differs.
This guide lists every difference, and what a self-managed (enterprise) GitLab changes
on top. Read [how-deploys-work.md](how-deploys-work.md) first for the model itself.

Both systems stay live. `DEPLOY_SYSTEM` (a one-line file in each app repo's root, missing =
`github`) says which one deploys that app; the other one's pipeline sees the file and skips.
Both read it through the app repo's `ci/deploy-system.sh`, which ignores whitespace (a CRLF
copy included) and case, and fails the job on any value other than `github` or `gitlab`
rather than letting both systems skip.
The switch gates the app repos only: a manual run of the platform's GitHub workflow can still
deploy a GitLab-owned app (and the other way round) — that is a trusted admin action, same as
any by-hand deploy. Each repo is one local working copy with two remotes — push to both, or
they drift.

## The mapping

| GitHub | GitLab | Why / notes |
|---|---|---|
| `.github/workflows/deploy.yml`, `rollback.yml` | `.gitlab-ci.yml` + `ci/gitlab-job.sh` | One pipeline, jobs `deploy-staging` (auto), `deploy-prod` (manual), `rollback` (manual, variable `ACTION=rollback`). Logic stays in `ci/deploy.sh` and `scripts/rollback.sh`, shared with GitHub. |
| App repo's `build-deploy.yml` | App repo's `.gitlab-ci.yml` + `ci/gitlab-build-deploy.sh` | Same flow: staging push builds once, main triggers a prod promote. Same tree-hash tag. |
| `workflow_dispatch` + `PLATFORM_DEPLOY_TOKEN` (a PAT) | Pipeline trigger token + `PLATFORM_TRIGGER_TOKEN` variable | The app repo starts the platform pipeline over the API. Trigger tokens are per project and can only start pipelines — narrower than a PAT. But unlike GitHub's typed inputs, a trigger can set **any** pipeline variable: the platform jobs clear `BASH_ENV` (non-interactive bash would execute it) and refuse key paths outside GitLab's file-variable directory for exactly this reason. |
| Environment secrets (`staging` / `prod` environments) | Protected CI/CD variables scoped to environment `staging` / `prod` | **Kubeconfig variables must be type File.** A plain variable hands the scripts the file's *content* where they expect a *path*; the error echoes the key into the public job log (this happened once — logs erased, key rotated). |
| Required reviewers on the `prod` environment | Manual `deploy-prod` job + protected `main` + protected variables | GitLab is documented to let only users who may merge/push to the protected branch run its pipelines and manual jobs (inferred, not tested with a Developer account — the pilot had only an Owner). The fence we **did** test: prod keys are protected variables, so a pipeline on an unprotected branch gets no key and fails. |
| Actions tab → Run workflow | Pipelines → New pipeline (ref `main`) + typed variables | `ACTION`/`APP`/`ENV`/`IMAGE`. Needs CI/CD setting "Minimum role to use pipeline variables" = Maintainer (new projects default to nobody). |
| GHCR (`ghcr.io/tjm-thomas/<repo>`) | GitLab registry (`registry.gitlab.com/tjm-thomas/<repo>`) | `IMAGE_REPO` in `apps/<app>/app.env` is a space-separated allow-list holding both. Public project ⇒ public registry ⇒ clusters pull anonymously. |
| Runner labels `k3s-staging`, `k3s-prod` | Runner tags `k3s-staging`, `k3s-prod`, `builder` | One group runner on the cluster PC (shell executor, PowerShell; every job is one line handing off to Git Bash). `builder` marks it for app image builds, so the gitlab.com shared runners (which need account validation) are never used. **Trust warning:** on GitHub, app builds ran on GitHub-hosted machines; here they run on the cluster PC as SYSTEM, with Docker (= admin on both clusters). Anyone who can make this runner run a job can bypass every fence above. Mark the runner **Protected** in its runner settings, so only jobs on protected branches reach it; the enterprise GitLab should keep cluster runners and build runners separate. |
| `staging` branch unprotected | `staging` branch protected: Developers may push, nobody force-pushes | Protected variables only reach protected refs, and the app's trigger token is protected. Pushing stays free. |

## What a self-managed (enterprise) GitLab changes

Settings, not code — the pipelines run unchanged:

- **Protected environments** (Premium): lock who may run `deploy-prod` at the environment
  level, independent of branch permissions.
- **Deployment approvals** (Premium): require a named approver before the job runs — the
  exact equivalent of GitHub's required reviewers.
- **Registry and host names:** `registry.gitlab.com` and `gitlab.com` become the internal
  names, in `app.env`'s `IMAGE_REPO` (one entry then; drop the public ones) and in
  `ci/gitlab-build-deploy.sh`'s trigger URL.
- **Runners exist already** there; ours are a stand-in. The questions to ask the admins are
  in the roadmap (phase 8): can runners reach the cluster APIs, which executor, own
  registration allowed, can clusters pull the internal registry.
- **Builds from source may become image imports:** development happens outside the airgap,
  so the build job's first half can be swapped for "verify the imported image exists in the
  internal registry", keeping the same trigger. Scan gates (code scanning, Parasoft) slot in
  as stages before the trigger stage.
- **Kubernetes agent** (all tiers): optional, gives GitLab a live view of workloads. The
  agent dials out from the cluster, so it suits closed networks; the airgapped side may
  already run it.

## Checklist to set up a new GitLab home

1. Blank public project per repo; push `main` (+ `staging` for app repos) to the new remote.
2. Platform project: the three File variables (two deployer keys, one reader key), a trigger
   token, pipeline-variables minimum role = Maintainer.
3. App project: `PLATFORM_TRIGGER_TOKEN` (masked, protected), protect `staging`, set
   `PLATFORM_PROJECT_ID` in its `.gitlab-ci.yml`, commit `DEPLOY_SYSTEM` = `gitlab`.
4. Register the runner (group level, tags above), service pointed at its own `config.toml`.
5. Prove it: push to staging, watch it deploy; merge to main, press play on `deploy-prod`;
   rollback pipeline; a pipeline on an unprotected branch must fail with "variable … is not
   set".
