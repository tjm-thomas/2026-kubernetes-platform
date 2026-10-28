# Kubernetes platform

A k3s platform that deploys application repos as swappable modules. Kanso is the placeholder app.

**Status:** the cluster, both environments and the `fe-main-user` app work locally, with deploy,
promote and rollback scripts. GitHub workflows come next.

k3s runs as one Docker container that is both the control plane and the worker.
Traefik (bundled with k3s) routes traffic on host port 8081.

| URL | What |
|---|---|
| http://kanso.localhost:8081 | Kanso prod |
| http://staging.kanso.localhost:8081 | Kanso staging (basic auth, user `staging`, password in `.secrets/staging-password.txt`) |
| http://kubernetes.localhost:8081 | Headlamp cluster UI |

## Layout

| Path | What |
|---|---|
| `cluster/` | `docker-compose.yml` for k3s, and cluster-wide manifests (Headlamp) |
| `apps/<app>/` | One app module: `app.env` (image, path, port, replicas) and `base/` (Deployment, Service, Ingress templates) |
| `environments/<env>/` | `env.conf` (namespace, host, basic auth), `apps.txt` (which apps run there), namespace and middleware |
| `ci/` | `deploy.sh` (used by the deploy workflow) and the per-app deployer account templates |
| `scripts/` | `setup.sh`, `rollback.sh`, `make-deployer-kubeconfig.sh`, shared helpers (`lib.sh`) |
| `docs/` | [guide/add-an-app.md](docs/guide/add-an-app.md): step-by-step for plugging in a new app, and [guide/how-deploys-work.md](docs/guide/how-deploys-work.md): how a deploy reaches the cluster |

App code lives in its own repo (for example `tjm-thomas/2026-kanso-fe-main-user`), which builds
the image. This repo only says how to run it.

## Start

Use Git Bash on Windows, or any bash.

```bash
cd cluster && docker compose up -d && cd ..   # start k3s (first start takes ~1 min)
./scripts/setup.sh                            # cluster, environments, apps, deployer accounts
```

`setup.sh` is safe to re-run. It never changes the image an app already runs (a new app starts
on `INITIAL_IMAGE` from its `app.env`), and it removes apps that are no longer in `apps.txt`.

## Deploy, promote, roll back

```bash
export DEPLOYER_KUBECONFIG="$(./scripts/make-deployer-kubeconfig.sh fe-main-user)"
ci/deploy.sh fe-main-user staging <image>     # roll staging to an image
ci/deploy.sh fe-main-user prod <image>        # only works if staging runs that image
./scripts/rollback.sh fe-main-user prod       # undo the last change in one environment
```

With `DEPLOYER_KUBECONFIG` set, the scripts use host `kubectl` with that app's restricted account.
It can only change that app's Deployment. Without it, they use admin access inside the container.
The deployer kubeconfig is a secret; it is written to git-ignored `.secrets/`.

To add an app, follow [docs/guide/add-an-app.md](docs/guide/add-an-app.md).

## Headlamp login token

```bash
docker exec k3s kubectl -n headlamp create token headlamp-admin
```

The token grants cluster-admin. It is for this local trial only.

## kubectl from Windows

`docker compose up` writes `cluster/kubeconfig/kubeconfig.yaml`. It is git-ignored and a secret (admin access).

```bash
export KUBECONFIG="$PWD/cluster/kubeconfig/kubeconfig.yaml"
kubectl get pods -A
```

## Stop and clean up

Run from `cluster/`:

```bash
docker compose down         # stop; cluster state is kept in the kubernetes_k3s-data volume
docker compose down -v      # stop and wipe the cluster
```

After `down -v`, the next `up` makes a new admin kubeconfig. Old Headlamp tokens and deployer
kubeconfigs stop working: run `./scripts/setup.sh`, then `./scripts/make-deployer-kubeconfig.sh <app>` again.
The staging password in `.secrets/` is also replaced on the next `setup.sh`.
