# Handover: generalised Kubernetes platform (kanso-platform)

**Date:** 2026-10-27 · **Fallback repo:** `thomasjmtan/2026-kubernetes-fe-test` (public, branches `main` + `staging`)
**Next home:** the free GitHub organization `tjm-thomas` with `kanso-platform`,
`kanso-frontend`, `kanso-backend`. Kanso is a placeholder app.
The platform repo is `tjm-thomas/2026-kubernetes-platform` (public).

You are picking up a working single-repo trial and turning it into a **multi-repo platform**.
The user wants small steps, simple English, and short concrete answers.

---

## 1. Goal, in the user's words

- Test a **new version in staging with selected users while production keeps running**, then
  **promote it cleanly** (the same tested image, never a rebuild).
- A **Kubernetes platform that can scale to many application repos**, where the apps it serves
  are **modules that can be swapped in and out**.
- The GitHub demo must stay **transferable to the real target**: self-managed **GitLab behind a
  closed network** (private projects, no internet, internal registry and runner).

## 2. Decisions already made: do not reopen

| Topic | Decision |
|---|---|
| Distribution | **k3s only.** Locally: k3s in one Docker container. Later: an Ubuntu VM |
| Delivery | **Push model only.** The pipeline changes the cluster. **No GitOps** (no Argo CD/Flux); don't offer it as an option |
| Branches per app repo | **Two branches.** Push to `staging` deploys to staging. Merge to `main` promotes to prod |
| Promotion | Prod accepts **only the image staging currently runs**. Never rebuild for prod |
| Image tags | **Git tree hash of the app's content** (not the commit). GitHub's merge button never fast-forwards, so commit SHAs differ; the tree hash survives merge, squash and rebase |
| Repo layout | `2026-kubernetes-platform` (cluster, app modules, deploys) and one repo per app: `2026-kanso-fe-main-user` (module `fe-main-user`), `2026-kanso-fe-dashboard` (module `fe-dashboard`, planned), a backend repo (planned). App code never lives in the platform repo, and there are no submodules: they are linked only by the image |
| Who deploys | **Only `kanso-platform`.** App repos build on GitHub-hosted runners, push to GHCR, then **trigger the platform's deploy workflow** (inputs: app, env, image). The self-hosted runner serves the platform repo only |
| App to platform trigger | A fine-grained token per app repo with only **Actions: Read and write** on the platform repo; it calls the Deploy workflow through the API (`workflow_dispatch`). Not `repository_dispatch`: that needs Contents: write, which could also push code. GitLab equivalent: multi-project pipeline `trigger:` (built in, no extra token) |
| Namespaces | **One per environment, holding all apps** (`kanso-staging`, `kanso-prod`), so staging frontend talks to staging backend by name |
| Routing | One host per environment. Ingress by path, longest prefix wins: `/` → `fe-main-user`, `/dashboard` → `fe-dashboard`, `/api` → backend. An app on a sub-path serves all its files under that prefix (for example `/dashboard/cube.js`), so it needs no other host and no CORS. Confirmed 2026-10-28 |
| Cluster access | **One restricted deployer account per app** (RBAC `resourceNames` = that app's Deployment) |
| Modularity | `apps/<name>/` module + `environments/<env>/apps.txt`. `setup.sh` applies listed apps and removes unlisted ones |
| Visibility | Demo repos **public** (free runners, branch protection, environment reviewers). The real GitLab stays private (see section 6) |
| GitHub org | **One free organization** for the three repos (matches a GitLab group) |

## 3. Proposed platform layout

```
kanso-platform/
├─ cluster/                 k3s-in-Docker compose, Traefik (bundled), Headlamp
├─ apps/
│  ├─ frontend/  app.env (image, path /, port, replicas)  base/ (Deployment, Service, Ingress)
│  └─ backend/   app.env (image, path /api, port, ...)    base/
├─ environments/
│  ├─ staging/apps.txt      e.g. "frontend backend"
│  └─ prod/apps.txt
├─ ci/                      deploy logic called by the deploy workflow
├─ scripts/                 setup, add-app (from a template), remove-app, rollback
└─ .github/workflows/       deploy.yml (workflow_dispatch: app, env, image, source), rollback.yml
```

## 4. Phases (confirm each with the user)

0. **Setup (user):** create the org and the 3 public repos. Register a self-hosted runner on
   `kanso-platform` with label `k3s-local`. Spin down the old cluster:
   `cd k3s && docker compose down` in the fallback repo (no `-v`, so it stays restorable).
1. **Platform skeleton:** `cluster/`, `apps/frontend` module, `environments/`, `setup.sh` reading
   `apps.txt`, per-app deployer accounts, staging basic auth, Headlamp.
2. **Platform deploy workflow:** inputs app/env/image. Staging rolls. Prod is checked against
   staging's image. Rollback workflow.
3. **kanso-frontend:** move `frontend/`. CI builds on GitHub-hosted runners, pushes
   `ghcr.io/tjm-thomas/kanso-frontend:<tree hash>`, triggers platform.
4. **kanso-backend:** a tiny API (`GET /api/status` returns its version). Ingress `/api`. The
   dashboard shows the backend version, which proves the apps talk to each other.
5. **Module swap test:** add or remove an app from staging only; prod untouched.
6. **GitLab mapping:** `.gitlab-ci.yml` equivalents. Optionally rehearse on GitLab CE in Docker.
   Offline k3s install notes.
7. **Multi-node (later):** start only after phases 1–5 are done and tested with more than one app
   repo. Details in section 9.

## 5. Reuse from the fallback repo

All of these work and were reviewed. Port them, don't rewrite them:

- `k3s/docker-compose.yml`: k3s `rancher/k3s:v1.36.5-k3s1`, privileged, ports `6443` (API) and
  `${K3S_HTTP_PORT:-8081}:80` (Traefik), kubeconfig written to `k3s/kubeconfig/`.
- `k3s/lib.sh`:
  - `kc()` uses host kubectl when `KANSO_KUBECONFIG` is set, otherwise `docker exec -i k3s kubectl`.
  - `roll`, `current_image`, `env_ns`, `registry_image`.
- `k3s/setup.sh`:
  - Idempotent; re-applying never changes a running image (it renders the kustomize overlay and substitutes the current image).
  - Creates the staging basic-auth secret.
  - Applies `deployer.yaml`.
- `k3s/ci-build.sh` (skip if the image exists in the registry; refuse uncommitted changes) and
  `k3s/ci-deploy.sh` (the prod gate: staging healthy and running the same image).
- `k3s/rollback.sh`: it also fixes the rollback change-cause label.
- `k3s/manifests/`:
  - Kustomize base + overlays.
  - Deployment with RollingUpdate `maxSurge 1 / maxUnavailable 0`, readiness and liveness on `/healthz`, `preStop sleep 5`, `minReadySeconds 3`.
  - Staging Traefik `Middleware` basic auth.
  - Pod Security `baseline` labels on the namespaces.
  - Headlamp.
  - Deployer RBAC.
- `k3s/make-deployer-kubeconfig.sh`: writes `.secrets/deployer.kubeconfig` under `umask 077` and never prints the token.
- `frontend/`:
  - Static nginx site, with `/version.txt` and `/healthz`.
  - `/dashboard` cube page (cube.js).
  - nginx `Cache-Control: no-cache`; the Dockerfile adds `?v=<version>` to CSS/JS links.
- `.github/workflows/`: staging, production and rollback workflows (single-repo version).

## 6. Real target: GitLab behind a closed network

| GitHub demo | Internal GitLab |
|---|---|
| Organization | Group (subgroups possible) |
| Self-hosted runner, label `k3s-local` | Group or project runner, `tags: [k3s-local]`. Registering needs group Owner; ask admins about existing instance runners |
| Reusable workflow / workflow_dispatch API | `include:` a CI template from the platform project; multi-project `trigger:` |
| Secrets / variables | CI/CD variables, Masked + Protected |
| GHCR (public) | Project container registry (private). k3s needs a read-only **deploy token** |
| Environments + required reviewers | Environments + manual prod job on a protected branch |
| Docker Hub base images | Dependency proxy or internal mirror. Make the base image a build arg (`ARG BASE_IMAGE`) |
| `get.k3s.io` install | Offline install: k3s binary + `k3s-airgap-images-amd64.tar.zst` |

Private everything means: registry pull credentials in the cluster, per-app deploy credentials as
protected CI variables, and the platform CI template included by each app project.

## 7. Gotchas already solved (this PC: Windows 11, Git Bash, Docker Desktop)

- **Runner shell:** plain `bash` resolves to **WSL**, and the runner cannot parse a quoted
  path with spaces in `shell:`. Use
  `shell: C:\PROGRA~1\Git\bin\bash.exe --noprofile --norc -eo pipefail {0}`.
- **Runner:** run it interactively (`run.cmd`), **not as a Windows service**; a service account
  can't use Docker Desktop. The current runner lives in `C:\Users\user\actions-runner` (fallback repo).
- **Git Bash path rewriting:** use `MSYS_NO_PATHCONV=1` only on `docker exec` calls that pass
  container paths (like `/manifests`). Never export it globally; it breaks host paths.
- **GHCR first push** (layers pushed, then `denied`): in the package settings, **Manage Actions
  access → add the repo with Write**, and **make the package public** so k3s can pull without a token.
- **502s during rollouts:** fixed with `preStop sleep 5` + `minReadySeconds 3`. Verified 0 non-200
  out of 145 requests across deploy, promote and rollback.
- **Stale browser files:** nginx `no-cache` + versioned asset URLs (`styles.css?v=<version>`).
- **Never rebuild an existing tag:** an overwritten tag can put untested code in prod.
- **Ports:** 8080 is taken on this PC. Ingress uses **8081**, the API uses **6443**. Only one
  cluster at a time can use them.
- **Hostnames:** `*.localhost` resolves to 127.0.0.1 in browsers with no DNS setup:
  `kanso.localhost:8081`, `staging.kanso.localhost:8081`, `headlamp.localhost:8081`.
- **actions/checkout@v4** prints a Node 20 deprecation warning. Use `@v5` (needs runner ≥ v2.327.1).
- **Org runners + public repos:** if you use an org-level runner, check the runner group's
  repository access, and that public repositories are allowed.
- **Pricing (checked 2026-10-27):** public repos have free runner minutes, branch protection and
  environment reviewers. Private repos on Free have none of the protection features, and
  self-hosted runner minutes are billed at $0.002/min from March 2026.
- **Scripted file edits:** escaping Windows backslashes through bash, sed or inline node broke
  twice. Write a small node script file, or use the Edit tool.
- **Git Bash also rewrites environment values** for Windows programs like `envsubst`:
  `PATH_PREFIX=/` became `C:/Program Files/Git/`. `render` in `scripts/lib.sh` runs it with
  `MSYS_NO_PATHCONV=1`.
- **Recreating the k3s container** (for example after a compose change) gave it a new random
  hostname, so it registered as a new node and the old one stayed `NotReady`. The compose file
  now sets `hostname: k3s`.
- **Right after a rollout,** a request can still reach an old pod during its 5 s `preStop` delay.
  Wait a few seconds before checking `/version.txt`.
- **Visual checks:** headless Chrome over the DevTools protocol (node script) works. Use device
  emulation for phone widths, because a headless window has a minimum width.

## 8. Working rules

- **Commit only when the user says "commit"; push only when they say "push".** Pushing is public.
- **Never print secrets:** passwords, tokens, kubeconfigs. Report file paths and names only.
  `.secrets/` and `kubeconfig/` are git-ignored.
- Give the user commands for anything that needs their GitHub login (runner tokens, secrets,
  package settings). They paste secrets themselves.
- Verify before claiming: curl through the ingress, check `/version.txt` on each host, use
  `rollout history`, and take headless screenshots for UI.
- The user verifies UI in their own browser; ask them for the footer version when something
  "doesn't show".

## 9. Later phase: spread the cluster over several VMs

**Start only when** the single-node platform is finished and proven with several app repos
(phases 1–5). Until then, everything runs as one k3s container.

**Target picture:** one cluster, several nodes. Not one cluster per VM.

```
VM 1: kanso-platform          VM 2                    VM 3
k3s SERVER (control plane)    k3s AGENT               k3s AGENT
API, scheduler, datastore,    runs frontend pods      runs backend pods
Traefik, Headlamp
        ▲ pipeline and kubectl talk only to VM 1's API (6443)
```

- **Join:**
  - VM 1 runs `k3s server` (taint it with `--node-taint CriticalAddonsOnly=true:NoExecute` so app pods stay off it).
  - VMs 2 and 3 run `k3s agent` with `K3S_URL=https://<vm1>:6443` and `K3S_TOKEN=<server token>`.
- **Placement:** label the nodes (for example `kanso/role=frontend`) and give each app module an
  optional `nodeSelector` in `app.env` / `base/`. Unpinned apps are spread by the scheduler.
- **Unchanged:**
  - Apps still reach each other by Service name across VMs, over the flannel overlay network.
  - The deploy workflow, the deployer accounts and promotion all stay the same.
  - Ingress traffic can enter on any node.
- **New work:**
  - Firewall between the VMs: `6443/tcp` (agents to server), `8472/udp` (flannel VXLAN, all nodes), `10250/tcp` (server to agents).
  - Registry access and pull credentials on **every** node (`/etc/rancher/k3s/registries.yaml`); this matters for the offline GitLab registry.
- **Trade-offs to explain to the user:**
  - One server node is a single point of failure for changes: running apps keep serving, but nothing can deploy or heal until it's back. True high availability needs 3 server nodes.
  - Pinning an app to one VM means it can't move if that VM dies. Pin only for a real reason (hardware, security zone).
- **Rehearse locally first:** add k3s agent containers next to the server in the compose file, so
  there are 3 "nodes" on one PC. Then run the same placement and failover tests.

## 10. Open questions for the user

1. Backend language: Node.js, Python, Go, or whatever the real backend uses?
2. Local clone paths for the three repos?
3. Required reviewer on the prod environment (free on public repos)? Optional.
