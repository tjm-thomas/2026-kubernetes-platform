# Standing this platform up on a different computer

For a person at a new computer — a second Windows PC, or a Mac — and for a Claude session
that has never seen this project and has to guide them, including when every key from the
old machine has been revoked. The Windows steps are the baseline; **Mac (Apple Silicon)**
near the end lists what changes there, and it is the more demanding test of the two.
Read `docs/CLAUDE.kanso-platform.md` first (fixed decisions and working rules), this page
second, [how-deploys-work.md](how-deploys-work.md) when you need the model behind a step.

Rebuilding elsewhere is a sanity check in its own right: anything that only worked because
of hidden state on the old machine fails here, visibly. Treat every failure as a finding
and note it; the notes are the output as much as the working system is.

## The one idea: three tiers, and what each proves

| Tier | What you prove | Needs from outside this PC | Conflicts with the old machine? |
|---|---|---|---|
| **1 — Local** | the clusters, `setup.sh`, the scripts and tests, the module swap | the public images on GHCR / GitLab | **No.** Both machines can run Tier 1 at once. |
| **2 — CI deploys** | a push deploys staging, a merge promotes prod, rollback, the refusal | GitHub + GitLab logins, runner registrations, re-uploaded keys | **Yes.** CI can target one machine's clusters at a time (why: below). |
| **3 — From scratch** | the whole setup, GitLab group included, from an export and the runbook alone | a fresh GitLab group | n/a — see [airgap-runbook.md](airgap-runbook.md) |

Do Tier 1 fully before touching Tier 2. Tier 1 is where most fresh-machine problems live and
it needs no secrets from anyone.

## Why keys do not travel

Every cluster credential in this platform is **bound to the cluster that issued it**: a
kubeconfig carries that cluster's CA certificate and a token for a service account that
exists only there. New machine ⇒ new clusters ⇒ every kubeconfig must be made again, and
every copy uploaded to GitHub and GitLab must be replaced. Once replaced, CI deploys to the
**new** machine and can no longer reach the old one. That is the Tier 2 conflict, and it is
by design — the keys are the thing that says which clusters are real.

The files on disk under `.secrets/` and `cluster/kubeconfig/` are git-ignored and never
leave the machine. Nothing in either repo lets another computer in.

## The registry: every key and registration, and how to make it again

The table a fresh session needs most. "Bound to" says what invalidates it.

| What | Made by / from | On disk (git-ignored) | Uploaded to | Bound to |
|---|---|---|---|---|
| Cluster admin kubeconfigs | k3s writes them on first start | `cluster/kubeconfig/kubeconfig.yaml` (prod), `staging.yaml` | nowhere | each cluster |
| Deployer key, one per app per env | `./scripts/make-deployer-kubeconfig.sh <app> <env>` after `setup.sh` | `.secrets/<env>/deploy-<app>.kubeconfig` | GitHub: platform repo → Settings → Environments → `staging` / `prod` → secret `DEPLOYER_KUBECONFIG_<APP>` (upper case, `-`→`_`, e.g. `DEPLOYER_KUBECONFIG_FE_MAIN_USER`). GitLab: platform project → Settings → CI/CD → Variables, same name, **type File**, Protected, scoped to the environment | that env's cluster |
| Staging reader key (the prod gate reads staging with it) | `./scripts/make-reader-kubeconfig.sh` | `.secrets/staging/staging-reader.kubeconfig` | GitHub: `prod` environment secret `STAGING_READER_KUBECONFIG`. GitLab: File variable, Protected, scoped `prod` | the staging cluster |
| Staging basic-auth password | `setup.sh` creates it on a fresh staging cluster | `.secrets/staging-password.txt` | nowhere | the staging cluster's `basic-auth` Secret |
| `PLATFORM_DEPLOY_TOKEN` | GitHub fine-grained PAT: resource owner `tjm-thomas`, only repo `2026-kubernetes-platform`, permission **Actions: Read and write**, nothing else, 90-day expiry | nowhere (deliberately) | each app repo → Settings → Secrets → Actions → `PLATFORM_DEPLOY_TOKEN` | the GitHub account; revoke from Settings → Developer settings → Fine-grained tokens |
| `PLATFORM_TRIGGER_TOKEN` | GitLab platform project → Settings → CI/CD → Pipeline trigger tokens → Add | nowhere | each GitLab app project → Settings → CI/CD → Variables, masked + protected | the platform project |
| GitHub self-hosted runner | platform repo → Settings → Actions → Runners → New self-hosted runner (Windows); labels **`k3s-staging,k3s-prod`**; install as a service when `config.cmd` offers | the runner folder you chose | — | **this machine**; one registration per machine |
| GitLab group runner | gitlab.com group `tjm-thomas` → Build → Runners → New group runner; tags **`k3s-staging,k3s-prod,builder`**; executor `shell`; tick **Protected**. Install: `winget install Gitlab.Runner`, then in an **Administrator** PowerShell `gitlab-runner register`, then `gitlab-runner install --working-directory C:\Users\<you>\GitLab-Runner --config C:\Users\<you>\GitLab-Runner\config.toml` and `gitlab-runner start` | `C:\Users\<you>\GitLab-Runner\config.toml` | — | **this machine** |
| `glab` CLI token (optional, read-only API checks) | gitlab.com → Edit profile → Access tokens, scope `read_api` | `.secrets/gitlab-cli-token.txt` | the Windows keyring via `glab auth login` | the GitLab account |
| Headlamp login | `docker exec k3s kubectl -n headlamp create token headlamp-admin` (and `k3s-staging`) | nowhere, ephemeral | — | each cluster |

Not on any machine and not in any repo, so nothing to carry over: GitHub environment
protection (required reviewers on `prod`), GHCR package visibility (public), GitLab branch
protection and the pipeline-variables role setting. They live in the two web UIs and survive
a machine change untouched.

## Prerequisites

Windows 11. Install, then confirm each line prints a path:

```bash
command -v docker kubectl git envsubst openssl base64 curl
```

- **Docker Desktop**, running. The clusters are two privileged containers.
- **Git for Windows.** Everything runs in Git Bash. `envsubst`, `openssl`, `base64` ship with it.
- **kubectl** on `PATH`. The scripts call it two ways: inside the k3s container for admin
  work (`docker exec`), and on the host with a kubeconfig path for the restricted keys and
  the tests.
- Both repos cloned side by side; the platform's docs assume
  `C:\Users\<you>\Documents\GitHub\kubernetes-test\2026-kubernetes-platform` and the app
  repos next to it, but nothing in the scripts depends on that path.
- A browser that routes `*.localhost` to loopback (Chrome, Edge, Firefox all do). The
  `curl` checks below need no DNS at all: they hit `127.0.0.1` with a `Host:` header.

Ports `6443`, `6444`, `8081`, `8082` must be free. `8080` is deliberately not used; it is
taken on the original machine.

## Tier 1 — local. No logins, no secrets from anyone.

```bash
cd 2026-kubernetes-platform/cluster && docker compose up -d && cd ..
./scripts/setup.sh --initial all
```

`--initial all` is required on a fresh cluster and **only** then: no app has a Deployment or
a ledger entry yet, and `setup.sh` refuses to guess. Every app starts on the `INITIAL_IMAGE`
in its `apps/<app>/app.env`, which is its day-one version, not the current one. To reach
the current versions, roll each app with the tag it currently runs elsewhere:

```bash
./ci/deploy.sh <app> staging <registry>/<repo>:<tag>
./ci/deploy.sh <app> prod    <registry>/<repo>:<tag>     # staging first: prod only takes what staging runs
```

Where to read the current tags from: the old machine (`docker exec k3s kubectl -n kanso-prod
get deploy -o custom-columns=NAME:.metadata.name,IMAGE:'.spec.template.spec.containers[0].image'`),
or the latest Deploy runs in the platform repo's GitHub Actions / GitLab pipelines. Before
leaving the old machine, paste that output into a note; it is the only place "what is
production running" exists once the clusters are gone.

**Pass / fail — all of these, or Tier 1 is not done:**

```bash
docker ps --format '{{.Names}} {{.Status}}'                     # k3s and k3s-staging, Up
for t in tests/*.sh; do printf '%-26s ' "$t"; bash "$t" >/dev/null 2>&1 && echo PASS || echo FAIL; done
pw=$(cat .secrets/staging-password.txt)                        # never echo it
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: kanso.localhost' http://127.0.0.1:8081/
curl -s -H 'Host: kanso.localhost' http://127.0.0.1:8081/version.txt; echo
curl -s -H 'Host: kanso.localhost' http://127.0.0.1:8081/api/status; echo
curl -s -o /dev/null -w '%{http_code}\n' -u "staging:$pw" -H 'Host: staging.kanso.localhost' http://127.0.0.1:8082/
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: kubernetes.localhost' http://127.0.0.1:8081/
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: staging.kubernetes.localhost' http://127.0.0.1:8082/
```

Expected: both containers `Up`; every test `PASS` (`tests/image-guard.sh` needs the clusters
up; the app repo's `tests/api-404.sh` needs Docker); `200`, a 12-hex tag, `{"version":...,"status":"ok"}`,
`200`, `200`, `200`.

Then the module swap, the one path that only a live run proves: delete `fe-dashboard` from
`environments/staging/apps.txt`, run `./scripts/setup.sh staging`, confirm
`/dashboard/version.txt` on staging no longer serves the dashboard (the `/` app answers for
it — check the `<title>`), put the line back, run setup again, and confirm
`/dashboard/version.txt` shows the **same tag as before** the removal. Prod must not have
changed at any point. Restore `apps.txt` to what git has.

## Tier 2 — CI deploys. Needs both logins, and it moves CI to this machine.

Before starting: on the **old** machine, stop its two runners (GitHub runner service,
`gitlab-runner stop`). Two machines registered with the same labels would each take jobs,
and a deploy would land on whichever picked it up. Its clusters can keep running; they are
simply no longer where CI points.

1. **Make the keys** (Tier 1 must be done — the accounts are created by `setup.sh`):
   ```bash
   for app in fe-main-user be-main fe-dashboard; do
     ./scripts/make-deployer-kubeconfig.sh "$app" staging
     ./scripts/make-deployer-kubeconfig.sh "$app" prod
   done
   ./scripts/make-reader-kubeconfig.sh
   ```
2. **(you, in the browser)** Replace every uploaded copy, per the registry table: six
   `DEPLOYER_KUBECONFIG_*` and one `STAGING_READER_KUBECONFIG` on GitHub (environment
   secrets on the platform repo), the same seven on GitLab (File variables, Protected,
   scoped). On GitLab the type **must be File**; a plain variable hands the scripts the key's
   content where they expect a path, and the error echoes the key into a public log.
3. **(you)** Register both runners on this machine, per the registry table. Confirm the
   GitLab service points at its own config: `sc.exe qc gitlab-runner` shows
   `--config C:\Users\<you>\GitLab-Runner\config.toml`, not `C:\WINDOWS\system32`.
4. **(you)** If `PLATFORM_DEPLOY_TOKEN` or `PLATFORM_TRIGGER_TOKEN` were revoked, make them
   again and store them per the table. They are not cluster-bound, so if they still exist
   they still work.

**Pass / fail — the same proof the platform has passed on every machine so far.** Pick a
GitHub-deployed app (`be-main` or `fe-dashboard`) and the GitLab-deployed one
(`fe-main-user`, `DEPLOY_SYSTEM=gitlab`):

| Step | Do | Expect |
|---|---|---|
| Deploy | add a comment to a file, commit, push to `staging` (both remotes for the GitLab app) | the app's CI builds a new tag; the platform deploys staging; `/version.txt` shows the new tag; prod unchanged |
| Promote | merge `staging` → `main`, push; approve on GitHub / press ▶ on GitLab | prod `/version.txt` shows the same tag; `kubectl rollout history` records `promote <image> (<source or actor>)` |
| Rollback | GitHub: Rollback workflow. GitLab: Run pipeline with `ACTION=rollback`, `APP`, `ENV`, press ▶ | prod returns to the previous tag; staging untouched |
| Refusal | on GitLab, run the platform pipeline from an unprotected branch with `ENV=prod` | fails with `variable DEPLOYER_KUBECONFIG_<APP> is not set for prod`; prod untouched |
| Hygiene | search the job logs for `BEGIN CERTIFICATE`, `glptt`, `glrt`, and the first four characters of the staging password | no hits |

## If a key was revoked and nothing says which

| Symptom | Which key | Make it again |
|---|---|---|
| App repo's GitHub run fails at *Ask the platform to deploy* with `403` or "Secret PLATFORM_DEPLOY_TOKEN is not set" | `PLATFORM_DEPLOY_TOKEN` | registry row; then update the secret in every app repo |
| GitLab app pipeline's trigger `curl` gets `404` or `401` | `PLATFORM_TRIGGER_TOKEN` | new trigger token on the platform project; update each app project's variable |
| Platform deploy job: `Unauthorized`, or `The deployer kubeconfig points at … but <env> is at …` | that app's deployer key for that env | `make-deployer-kubeconfig.sh <app> <env>`, re-upload to both systems |
| Prod deploy: `STAGING_READER_KUBECONFIG is not set` or an auth error while checking staging | the reader key | `make-reader-kubeconfig.sh`, re-upload to the `prod` scope on both |
| Platform job sits in *pending / no runner* | that system's runner registration | re-register on this machine; check labels/tags match exactly |
| `setup.sh` stops with *is listed … but is not running and has no recorded image* | not a key — a fresh cluster or a lost ledger | `--initial <app>` or write the ledger, as the message says |
| `curl` to staging returns `401` | not a key — basic auth | `pw=$(cat .secrets/staging-password.txt)` and `-u "staging:$pw"` |

## What is bound to Windows

Four places, all of them the CI layer rather than the platform:

- `.github/workflows/deploy.yml` and `rollback.yml`: `shell: C:\PROGRA~1\Git\bin\bash.exe --noprofile --norc -eo pipefail {0}` — the self-hosted runner's shell.
- `.gitlab-ci.yml` (platform) and the app repos' `.gitlab-ci.yml`: each job's one script line is PowerShell handing off to that same `bash.exe` after clearing `BASH_ENV`.

On a Linux or Mac host those lines become plain `bash ci/gitlab-job.sh` (with `unset BASH_ENV` first on GitLab), the runners install as that OS's services, and `cluster/docker-compose.yml` runs unchanged. Nothing under `scripts/`, `ci/*.sh` or `tests/` is Windows-specific — they already run on `ubuntu-latest` in the app repos' `gate` job — but they are **bash 4+** (see Mac). `MSYS_NO_PATHCONV` is a no-op outside Git Bash.

## Mac (Apple Silicon — tested target: M4 Max)

Two things a Windows rebuild never exercises, both of which the airgap's Linux runners will:
the CPU architecture, and a host shell that is not Git Bash. Expect findings; that is the
point. Do Tier 1 here before anything else.

**Tools.** macOS ships bash **3.2** (GPL reasons) and no `envsubst`. The scripts need bash 4+:
`${var,,}` in `ci/deploy-system.sh` and `scripts/lib.sh`, `shopt -s inherit_errexit` (4.4+)
in `lib.sh`. So:

```bash
brew install bash gettext kubectl
bash --version | head -1          # must say 5.x — Homebrew's bin must precede /bin on PATH
command -v docker kubectl git envsubst openssl base64 curl
```

Every script starts `#!/usr/bin/env bash`, so the first `bash` on `PATH` wins; with
Homebrew's `shellenv` in your profile that is the new one. Two more to verify once, not
assume: `openssl passwd -apr1 x` works on macOS's LibreSSL (setup uses it for the staging
password) and `printf eA== | base64 -d` decodes (older macOS wanted `-D`; `lib.sh` uses `-d`).

**Docker Desktop for Mac**, with *Use Rosetta for x86_64/amd64 emulation* on in Settings →
General. Privileged containers, `tmpfs`, and the port publishing all work as on Windows.

**Architecture — the real finding.** The cluster is fine: `rancher/k3s`, Traefik, CoreDNS and
Headlamp all publish arm64 images, so `docker compose up -d` gives you two **native arm64**
clusters. The **app images are not**: every tag built so far — on GitHub's `ubuntu-latest`
and on the Windows runner — is amd64 only, including every `INITIAL_IMAGE`. On an arm64 node
that shows up as `ImagePullBackOff` with *no match for platform in manifest*, or a pod that
starts and dies with *exec format error*. Decide which of two routes you are testing before
you run setup:

| Route | What you do | What it proves | Cost |
|---|---|---|---|
| **A — emulate the whole cluster** | add `platform: linux/amd64` to both services in `cluster/docker-compose.yml` (a local override file `cluster/docker-compose.override.yml` keeps it out of git) | the platform unchanged, on a new host OS and shell | everything inside k3s runs under Rosetta; noticeably slower; not how any real target runs |
| **B — native arm64 + multi-arch images** | app CIs build `--platform linux/amd64,linux/arm64` (GitHub: `docker/setup-qemu-action` + `setup-buildx-action`; the Windows runner: `docker buildx create --use` once, Docker Desktop has the emulators), push one new commit per app so a multi-arch tag exists, point each `INITIAL_IMAGE` at it | the images are portable, which the airgap may also need | a CI change in three app repos plus one platform commit; the Java build under QEMU on the Windows runner is slow. Existing tags stay amd64 — **never rebuild a tag** |

Route A first: it answers "does the platform run on a Mac" in an hour. Route B is a small
project of its own and a decision about where images will ever need to run; it is worth
doing if the airgapped VMs are not guaranteed amd64, and pointless if they are.

Then Tier 1 exactly as written above. `--initial all` on the first setup, as everywhere.

**Tier 2 on the Mac** means the CI layer's four Windows-bound lines change: GitHub
`shell: bash`, GitLab `- unset BASH_ENV; bash ci/gitlab-job.sh` (and the same in each app
repo's `.gitlab-ci.yml`). Those are **the same edits the airgap needs**, so the Mac is a dry
run for them — but they break the Windows runner, so make them on a branch and expect to
hold two versions of the CI files until one machine is retired. The runners themselves:
`brew install gitlab-runner` (shell executor, bash), and GitHub's self-hosted runner has a
macOS arm64 build. Everything in the key registry applies unchanged; keys are bound to
clusters, not to operating systems.

## When you are done

Write down what the page did not tell you. Each gap is a line for this page, and a line the
airgapped site will otherwise rediscover.
