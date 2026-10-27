# k3s: local single-node cluster in Docker

k3s runs as one Docker container that is both the control plane and the worker.
Traefik (bundled with k3s) routes traffic on host port 8081.
There are two environments: staging (1 replica) and production (2 replicas).

| URL | What |
|---|---|
| http://kanso.localhost:8081 | Kanso production |
| http://staging.kanso.localhost:8081 | Kanso staging (basic auth, user `staging`) |
| http://headlamp.localhost:8081 | Headlamp cluster UI |

The staging password is in `k3s/.secrets/staging-password.txt` (git-ignored).

## First time

Run all commands from `k3s/` (Git Bash on Windows, or any bash).

```bash
docker compose up -d        # start the cluster (first start takes ~1 min)
./setup.sh                  # headlamp, staging, prod, deployer account
```

`setup.sh` always uses admin access (it ignores `KANSO_KUBECONFIG`).
It is safe to re-run. It never changes the image an environment already runs.
To choose the staging password, run `STAGING_PASSWORD=... ./setup.sh` the first time.

## Deploy, promote, roll back

```bash
./deploy.sh 1.0.1           # build ../frontend, import into k3s, roll STAGING
./promote.sh                # put the exact image staging runs on PROD (no rebuild)
./rollback.sh staging       # undo the last change in one environment
./rollback.sh prod
```

Each code change needs a new tag. If `kanso-web:<tag>` already exists in k3s, deploy
reuses it and does not rebuild, so an old tag never picks up new code.
Deploying the tag staging already runs does nothing.

## Deployer account (limited access)

`setup.sh` creates a `deployer` account that can only patch Deployments and watch
rollouts in the two kanso namespaces. It cannot touch anything else.

```bash
./make-deployer-kubeconfig.sh          # writes .secrets/deployer.kubeconfig
export KANSO_KUBECONFIG="$PWD/.secrets/deployer.kubeconfig"
./deploy.sh 1.0.2                      # now uses host kubectl with that account
```

With `KANSO_KUBECONFIG` set, the scripts run host `kubectl` with that file instead of
`docker exec k3s kubectl`. So `kubectl` must be installed on the host (Docker is still needed to build). `make-deployer-kubeconfig.sh` needs admin, so run it
without `KANSO_KUBECONFIG`. The deployer kubeconfig is a secret. Do not commit or share it.

The token never expires. To rotate it: delete Secret `ci/deployer-token`, run `./setup.sh`, then `./make-deployer-kubeconfig.sh`.

## GitHub pipeline (two branches)

Workflows in `.github/workflows/` run on the self-hosted runner on this PC (label `k3s-local`).

| Event | Workflow | What happens |
|---|---|---|
| Push to `staging` | Staging | Build `ghcr.io/thomasjmtan/kanso-web:<hash>` (skipped if it exists), deploy it to staging |
| Push or merge to `main` | Production | Promote that same image to prod, only if staging runs it. No rebuild |
| Manual (Actions tab) | Rollback | Roll staging or prod back one version |

The image tag is git's hash of the `frontend/` folder, not the commit. Any merge style
(merge commit, squash, rebase) keeps the same `frontend/` content, so prod finds the exact
image staging tested. The pipeline files only call `ci-build.sh`, `ci-deploy.sh` and
`rollback.sh`, so a GitLab pipeline can reuse them unchanged.

Needs: repo secret `DEPLOYER_KUBECONFIG` (contents of `.secrets/deployer.kubeconfig`) and a
public `kanso-web` package in GHCR, so the cluster can pull without a token.

## Headlamp login token

```bash
docker exec k3s kubectl -n headlamp create token headlamp-admin
```

The token grants cluster-admin. It is for this local trial only.

## kubectl from Windows

`docker compose up` writes `kubeconfig/kubeconfig.yaml` (git-ignored; it is a secret, admin access).

```bash
export KUBECONFIG="$PWD/kubeconfig/kubeconfig.yaml"
kubectl get pods -A
```

## Stop and clean up

```bash
docker compose down         # stop; cluster state is kept in the k3s-data volume
docker compose down -v      # stop and wipe the cluster
```

`.secrets/` stays on disk after `down -v`. `.secrets/deployer.kubeconfig` then
belongs to the old cluster. After the next `./setup.sh`, run
`./make-deployer-kubeconfig.sh` again. (`setup.sh` writes a new staging password file.)
