# Kubernetes platform

A k3s platform that deploys application repos as swappable modules. Kanso is the placeholder app.

**Status:** two clusters (staging and prod), three apps (`fe-main-user`, `be-main`, `fe-dashboard`),
with deploy, promote and rollback through GitHub workflows — and, in parallel, through GitLab
pipelines (group [tjm-thomas on gitlab.com](https://gitlab.com/tjm-thomas)). Each app repo's
`DEPLOY_SYSTEM` file says which system deploys it (missing = GitHub); currently `fe-main-user`
deploys through GitLab, the rest through GitHub. Every repo is one local working copy with two
remotes (`origin` = GitHub, `gitlab` = GitLab) — push to both, or they drift. The differences are
listed in [docs/guide/github-to-gitlab.md](docs/guide/github-to-gitlab.md).

Each environment runs on its own k3s cluster. Locally, each cluster is one Docker container that is
both the control plane and the worker. Traefik (bundled with k3s) routes traffic.

| Cluster | Container | Kubernetes API | Browser port |
|---|---|---|---|
| prod | `k3s` | `127.0.0.1:6443` | `8081` |
| staging | `k3s-staging` | `127.0.0.1:6444` | `8082` |

| URL | What |
|---|---|
| http://kanso.localhost:8081 | Kanso prod |
| http://staging.kanso.localhost:8082 | Kanso staging (basic auth, user `staging`, password in `.secrets/staging-password.txt`) |
| http://kubernetes.localhost:8081 | Headlamp for the prod cluster |
| http://staging.kubernetes.localhost:8082 | Headlamp for the staging cluster |

## Layout

| Path | What |
|---|---|
| `cluster/` | `docker-compose.yml` for both clusters, and cluster-wide manifests (Headlamp) |
| `apps/<app>/` | One app module: `app.env` (image, path, port, replicas) and `base/` (Deployment, Service, Ingress templates) |
| `environments/<env>/` | `env.conf` (namespace, host, basic auth, which cluster), `apps.txt` (which apps run there), namespace and middleware |
| `ci/` | `deploy.sh` (used by the deploy workflow), the per-app deployer account templates, and the read-only `staging-reader` account |
| `scripts/` | `setup.sh`, `rollback.sh`, `make-deployer-kubeconfig.sh`, `make-reader-kubeconfig.sh`, shared helpers (`lib.sh`) |
| `.gitlab-ci.yml`, `ci/gitlab-job.sh` | The GitLab twin of the workflows: deploy (staging auto, prod manual) and rollback |
| `docs/` | [guide/add-an-app.md](docs/guide/add-an-app.md): step-by-step for plugging in a new app, [guide/how-deploys-work.md](docs/guide/how-deploys-work.md): how a deploy reaches the cluster, and [guide/github-to-gitlab.md](docs/guide/github-to-gitlab.md): the GitLab mapping |

App code lives in its own repo (for example `tjm-thomas/2026-kanso-fe-main-user`), which builds
the image. This repo only says how to run it.

## Start

Use Git Bash on Windows, or any bash.

```bash
cd cluster && docker compose up -d && cd ..   # start both clusters (first start takes ~1 min)
./scripts/setup.sh                            # every environment on its own cluster
./scripts/setup.sh staging                    # or one environment only
```

`setup.sh` is safe to re-run. It never changes the image an app already runs (a new app starts
on `INITIAL_IMAGE` from its `app.env`), and it removes apps that are no longer in `apps.txt`.

## Deploy, promote, roll back

```bash
DEPLOYER_KUBECONFIG="$(./scripts/make-deployer-kubeconfig.sh fe-main-user staging)" \
  ci/deploy.sh fe-main-user staging <image>     # roll staging to an image

DEPLOYER_KUBECONFIG="$(./scripts/make-deployer-kubeconfig.sh fe-main-user prod)" \
STAGING_READER_KUBECONFIG="$(./scripts/make-reader-kubeconfig.sh)" \
  ci/deploy.sh fe-main-user prod <image>        # only works if staging runs that image

./scripts/rollback.sh fe-main-user prod         # undo the last change in one environment
```

With `DEPLOYER_KUBECONFIG` set, the scripts use host `kubectl` with that app's restricted account
on that environment's cluster. It can only change that app's Deployment. A prod deploy also needs
`STAGING_READER_KUBECONFIG`: a read-only account on the staging cluster, used to check what
staging runs. Without any keys, the scripts use admin access inside the cluster containers.

Keys are secrets. They are written to git-ignored `.secrets/<env>/`.

To add an app, follow [docs/guide/add-an-app.md](docs/guide/add-an-app.md).

## Headlamp login token

```bash
docker exec k3s kubectl -n headlamp create token headlamp-admin           # prod cluster
docker exec k3s-staging kubectl -n headlamp create token headlamp-admin   # staging cluster
```

The token grants cluster-admin. It is for this local trial only.

## kubectl from Windows

`docker compose up` writes an admin kubeconfig per cluster to `cluster/kubeconfig/`:
`kubeconfig.yaml` (prod) and `staging.yaml` (staging). They are git-ignored and secrets.

```bash
export KUBECONFIG="$PWD/cluster/kubeconfig/staging.yaml"
kubectl get pods -A
```

## Stop and clean up

Run from `cluster/`:

```bash
docker compose down                      # stop both; state is kept in the volumes
docker compose down -v                   # stop and wipe both clusters
docker compose rm -sf k3s-staging && docker volume rm kubernetes_k3s-staging-data   # wipe staging only
```

After a wipe, the next `up` makes a new admin kubeconfig. Old Headlamp tokens and keys for that
cluster stop working: run `./scripts/setup.sh <env>`, then make its keys again
(`make-deployer-kubeconfig.sh <app> <env>`, and `make-reader-kubeconfig.sh` for staging) and update
the GitHub environment secrets. Apps on a wiped cluster start on their `INITIAL_IMAGE` again.
The staging password in `.secrets/` is also replaced on the next `setup.sh`.
