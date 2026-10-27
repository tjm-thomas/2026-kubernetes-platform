# Kubernetes platform

A k3s platform that deploys application repos as swappable modules. Kanso is the placeholder app.
Plan and decisions: [docs/handover-kanso-platform.md](docs/handover-kanso-platform.md).

**Status:** the cluster layer works (k3s, Traefik, Headlamp). Apps and environments come next.

k3s runs as one Docker container that is both the control plane and the worker.
Traefik (bundled with k3s) routes traffic on host port 8081.

| URL | What |
|---|---|
| http://kubernetes.localhost:8081 | Headlamp cluster UI |

## Layout

| Path | What |
|---|---|
| `cluster/` | `docker-compose.yml` for k3s, and cluster-wide manifests (Headlamp) |
| `scripts/` | `setup.sh` and shared helpers (`lib.sh`) |
| `docs/` | Handover plan |

## Start

Use Git Bash on Windows, or any bash.

```bash
cd cluster && docker compose up -d && cd ..   # start k3s (first start takes ~1 min)
./scripts/setup.sh                            # wait for k3s and Traefik, apply Headlamp
```

`setup.sh` is safe to re-run.

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

After `down -v`, the next `up` makes a new admin kubeconfig, and old Headlamp tokens stop working.
