# Two Clusters (Staging and Prod) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The platform serves two k3s clusters: one runs staging, one runs prod. Prod still only accepts the image staging runs.

**Architecture:** Each `environments/<env>/env.conf` says how to reach its cluster (a local container or an admin kubeconfig) and its API address. All scripts pick the cluster from the environment. The prod gate reads staging through a read-only account on the staging cluster. Deploy keys become one per app per cluster, stored as GitHub environment secrets.

**Tech Stack:** k3s `rancher/k3s:v1.36.5-k3s1` in Docker Compose, bash (Git Bash on Windows), kubectl, envsubst, GitHub Actions on the self-hosted runner.

**Spec:** the design agreed in chat on 2026-10-28, summarised in Global Constraints below.

## Global Constraints

- Prod cluster: the existing container `k3s`, API `https://127.0.0.1:6443`, ingress `8081`, namespace `kanso-prod`. Its compose service, volume (`kubernetes_k3s-data`) and kubeconfig path stay byte-for-byte the same, so `docker compose up` does not recreate it.
- Staging cluster: new container `k3s-staging`, hostname `k3s-staging`, API port `6444` (k3s `--https-listen-port=6444`, mapped `6444:6444`), ingress `8082`, namespace `kanso-staging`, volume `k3s-staging-data`, admin kubeconfig `cluster/kubeconfig/staging.yaml`.
- URLs: prod `kanso.localhost:8081`, staging `staging.kanso.localhost:8082`, Headlamp `kubernetes.localhost:8081` (prod) and `kubernetes.localhost:8082` (staging).
- Read-only account `staging-reader` (namespace `ci`, staging cluster only): get/list/watch on deployments, replicasets and pods in `kanso-staging`. Nothing else.
- GitHub: environment secrets `DEPLOYER_KUBECONFIG_<APP>` in both `staging` and `prod`; `STAGING_READER_KUBECONFIG` in `prod` only. Repo-level `DEPLOYER_KUBECONFIG_*` secrets are deleted.
- Workflows run on `runs-on: [self-hosted, "k3s-${{ inputs.env }}"]`. The one runner carries labels `k3s-staging` and `k3s-prod`.
- Secret files: `.secrets/<env>/deploy-<app>.kubeconfig`, `.secrets/staging/staging-reader.kubeconfig`, under `umask 077`. Scripts print paths, never contents.
- Never print secrets. Commit only when the user says "commit", push only on "push".
- `MSYS_NO_PATHCONV=1` only on `docker exec` calls, never exported.

## Review Focus

- **CI prod deploy without `STAGING_READER_KUBECONFIG`:** the runner sits on the same PC, so a fallback to `docker exec k3s-staging` would silently use admin rights. Expected: in restricted mode (`DEPLOYER_KUBECONFIG` set) the prod deploy fails with "STAGING_READER_KUBECONFIG is not set". Test in Task 3.
- **A deploy key for the wrong cluster** (prod key pasted into the `staging` environment secret): expected: fails before any change with "kubeconfig points at <server>, but <env> is at <API_SERVER>". Test in Task 3.
- **One cluster is down while running `setup.sh`:** expected: it times out with the existing `wait_for` message naming the environment, and `./scripts/setup.sh prod` still sets up the other one. Test in Task 2.
- **An app re-created on the new staging cluster** starts on `INITIAL_IMAGE`, not its last staging image: expected: the migration (Task 5) rolls each app to its recorded image and checks `/version.txt`.
- **Old single-cluster key files** (`.secrets/deploy-<app>.kubeconfig`) left behind: expected: Task 5 deletes them, so nobody pastes a stale key.

---

### Task 1: Compose file and env.conf describe two clusters

**Files:**
- Modify: `cluster/docker-compose.yml`
- Modify: `environments/staging/env.conf`, `environments/prod/env.conf`

**Interfaces:**
- Produces: `env.conf` variables `CLUSTER_CONTAINER` (container name, may be empty), `CLUSTER_ADMIN_KUBECONFIG` (path relative to repo root, may be empty; used when `CLUSTER_CONTAINER` is empty), `API_SERVER` (URL written into deploy keys).

- [ ] **Step 1:** Add service `k3s-staging` to `cluster/docker-compose.yml`, copying the `k3s` service with: `container_name`/`hostname` `k3s-staging`, `command: server --tls-san=127.0.0.1 --https-listen-port=6444`, `K3S_KUBECONFIG_OUTPUT: /output/staging.yaml`, volume `k3s-staging-data:/var/lib/rancher/k3s`, ports `"6444:6444"` and `"${K3S_STAGING_HTTP_PORT:-8082}:80"`. Leave the `k3s` service untouched. Update the header comment to name both clusters.
- [ ] **Step 2:** Add to `environments/prod/env.conf`: `CLUSTER_CONTAINER=k3s`, `CLUSTER_ADMIN_KUBECONFIG=`, `API_SERVER=https://127.0.0.1:6443`. Add to staging: `CLUSTER_CONTAINER=k3s-staging`, `CLUSTER_ADMIN_KUBECONFIG=`, `API_SERVER=https://127.0.0.1:6444`. One comment above them: a container for local k3s in Docker, or an admin kubeconfig for a cluster elsewhere (e.g. a VM).
- [ ] **Step 3: Verify the prod cluster is not recreated**

Run: `cd cluster && docker compose up -d`
Expected: `Container k3s Running` (not `Recreated`), `Container k3s-staging Started`. Then `docker exec k3s-staging kubectl get nodes` shows `k3s-staging Ready` within ~1 min, and `cluster/kubeconfig/staging.yaml` contains `https://127.0.0.1:6444`.

### Task 2: Scripts pick the cluster per environment

**Files:**
- Modify: `scripts/lib.sh`, `scripts/setup.sh`, `scripts/rollback.sh`, `scripts/make-deployer-kubeconfig.sh`
- Create: `ci/staging-reader.yaml`, `scripts/make-reader-kubeconfig.sh`

**Interfaces:**
- Consumes: Task 1's `env.conf` variables.
- Produces (in `lib.sh`):
  - `use_cluster <env>`: loads the env and sets `KC_KUBECONFIG` / `KC_CONTAINER` for `kc`. Order: `DEPLOYER_KUBECONFIG` if non-empty, else `CLUSTER_ADMIN_KUBECONFIG` (made absolute), else `CLUSTER_CONTAINER`.
  - `kc`: host `kubectl --kubeconfig "${KC_KUBECONFIG}"` when set, else `MSYS_NO_PATHCONV=1 docker exec -i "${KC_CONTAINER}" kubectl`. Fails with "call use_cluster first" when neither is set.
  - `write_kubeconfig <env> <serviceaccount> <out-file>`: the body of today's `make-deployer-kubeconfig.sh` (token wait, CA, umask 077), with `server: ${API_SERVER}` and cluster name `k3s-<env>`.
- Produces scripts: `make-deployer-kubeconfig.sh <app> <env>` → prints `.secrets/<env>/deploy-<app>.kubeconfig`; `make-reader-kubeconfig.sh` → prints `.secrets/staging/staging-reader.kubeconfig`; `setup.sh [env]` (no argument = every environment).

- [ ] **Step 1:** Write `ci/staging-reader.yaml`: ServiceAccount `staging-reader` and its token Secret `staging-reader-token` in namespace `ci`, a Role `staging-reader` in `${NAMESPACE}` with get/list/watch on `deployments`, `replicasets` (group `apps`) and `pods` (core), and its RoleBinding. Same labels and comment style as `ci/deployer-account.yaml`.
- [ ] **Step 2:** Implement `use_cluster`, the new `kc` and `write_kubeconfig` in `scripts/lib.sh`. `env_ns` stays as is.
- [ ] **Step 3:** Restructure `setup.sh` so every step runs per environment, in a subshell after `use_cluster "${env}"`: wait for the API and Traefik, apply `cluster/manifests/*.yaml` (Headlamp on each cluster), apply deployer accounts **for the apps in that env's `apps.txt`**, then the existing namespace/basic-auth/apps/removal steps. For `staging`, also render and apply `ci/staging-reader.yaml`. An optional first argument limits the run to one environment (validated through `load_env`). Echo lines name the environment: `==> [staging] Waiting for the k3s API`.
- [ ] **Step 4:** `rollback.sh`: call `use_cluster "${ENV}"` before the first `kc`. `make-deployer-kubeconfig.sh`: take `<app> <env>`, call `use_cluster` (admin, `DEPLOYER_KUBECONFIG` unset as today) and `write_kubeconfig`. `make-reader-kubeconfig.sh`: same for `staging-reader` on `staging`.
- [ ] **Step 5: Verify setup on both clusters**

Run: `./scripts/setup.sh`
Expected: `[prod]` lines all `unchanged`/rolled out, no `kanso-staging` namespace touched on the prod cluster; `[staging]` creates `kanso-staging`, basic-auth, `staging-reader`, the three apps on `INITIAL_IMAGE`, all rolled out.

Run: `docker stop k3s-staging; ./scripts/setup.sh staging` → times out with `Timed out after 120s waiting for: kc get --raw /readyz`; then `./scripts/setup.sh prod` succeeds. `docker start k3s-staging` afterwards.

Run: `K="kubectl --kubeconfig .secrets/staging/staging-reader.kubeconfig"; $K auth can-i get deploy -n kanso-staging; $K auth can-i patch deploy/be-main -n kanso-staging; $K auth can-i get secrets -n kanso-staging`
Expected: `yes`, `no`, `no`.

- [ ] **Step 6: Commit** (only after the user says "commit")

### Task 3: Deploy reads staging from the staging cluster

**Files:**
- Modify: `ci/deploy.sh`

**Interfaces:**
- Consumes: `use_cluster`, `kc`, `current_image`, `roll`.
- Produces: env var `STAGING_READER_KUBECONFIG` (path) read by `ci/deploy.sh`.

- [ ] **Step 1: Write the failing checks** (run before the change; they should not behave as described yet)

```bash
# wrong-cluster key: prod key used for staging
DEPLOYER_KUBECONFIG=.secrets/prod/deploy-be-main.kubeconfig ci/deploy.sh be-main staging <any be-main image>
# expect: "kubeconfig points at https://127.0.0.1:6443, but staging is at https://127.0.0.1:6444", exit 1, nothing changed

# restricted prod deploy without the reader key
DEPLOYER_KUBECONFIG=.secrets/prod/deploy-be-main.kubeconfig ci/deploy.sh be-main prod <staging's be-main image>
# expect: "STAGING_READER_KUBECONFIG is not set", exit 1

# gate across clusters: image staging does not run
DEPLOYER_KUBECONFIG=.secrets/prod/deploy-fe-dashboard.kubeconfig STAGING_READER_KUBECONFIG=.secrets/staging/staging-reader.kubeconfig \
  ci/deploy.sh fe-dashboard prod ghcr.io/tjm-thomas/2026-kanso-fe-dashboard:0b116e35a986
# expect: "staging runs ...:d90567e11632, not ...:0b116e35a986", exit 1
```

- [ ] **Step 2:** In `ci/deploy.sh`: call `use_cluster "${ENV}"` first. When `DEPLOYER_KUBECONFIG` is set, compare its server (`kubectl config view --kubeconfig ... --minify -o jsonpath='{.clusters[0].cluster.server}'`) with the env's `API_SERVER` and fail with the message above. For prod, run the staging check in a subshell with `DEPLOYER_KUBECONFIG="${STAGING_READER_KUBECONFIG:-}" use_cluster staging`; if `DEPLOYER_KUBECONFIG` was set but `STAGING_READER_KUBECONFIG` is empty, fail before that. Admin runs (no keys) keep working through the containers.
- [ ] **Step 3: Run the three checks again** → each prints its expected message and exits 1; `rollout history` of the touched Deployments has no new revision.
- [ ] **Step 4: Commit** (only after the user says "commit")

### Task 4: Workflows pick runner and secrets per environment

**Files:**
- Modify: `.github/workflows/deploy.yml`, `.github/workflows/rollback.yml`

- [ ] **Step 1:** Both: `runs-on: [self-hosted, "k3s-${{ inputs.env }}"]`. The deployer secret name stays `DEPLOYER_KUBECONFIG_<APP>`; add a comment that it is an environment secret, one per cluster.
- [ ] **Step 2:** `deploy.yml` Deploy step: pass `READER_CONTENT: ${{ secrets.STAGING_READER_KUBECONFIG }}`; when non-empty, write it to `${RUNNER_TEMP}/staging-reader.kubeconfig` (umask 077) and export `STAGING_READER_KUBECONFIG`. Clean-up step removes it too. Do not check for emptiness in YAML; `ci/deploy.sh` owns that rule.
- [ ] **Step 3: Verify syntax:** `git diff` shows only these changes; the GitHub run in Task 5 is the real test.
- [ ] **Step 4: Commit** (only after the user says "commit")

### Task 5: Migrate, hand over keys, prove it end to end

**Files:**
- Modify: `README.md`, `docs/guide/add-an-app.md`, `docs/guide/how-deploys-work.md`, `docs/CLAUDE.kanso-platform.md`

- [ ] **Step 1: Record staging images (before Task 2's setup run, on the old cluster):** `docker exec k3s kubectl -n kanso-staging get deploy -o jsonpath='{range .items[*]}{.metadata.name}={.spec.template.spec.containers[0].image}{"\n"}{end}'` into the scratchpad. Expected today: `fe-main-user=...:7afa53713d88`, `be-main=...:b346e4c69d26`, `fe-dashboard=...:d90567e11632`.
- [ ] **Step 2: Restore them on the new staging cluster:** `ci/deploy.sh <app> staging <recorded image>` for each (admin mode). Check `/version.txt` and `/api/status` through `staging.kanso.localhost:8082` match.
- [ ] **Step 3: Remove staging from the prod cluster:** `docker exec k3s kubectl delete namespace kanso-staging`. Then `./scripts/setup.sh prod` → all `unchanged`, prod pods keep their age.
- [ ] **Step 4: Keys:** `make-deployer-kubeconfig.sh <app> <env>` for 3 apps × 2 envs, `make-reader-kubeconfig.sh`, delete the old `.secrets/deploy-*.kubeconfig`. Each key passes `auth can-i patch deploy/<app>` = yes and `patch deploy/<other app>` = no on its own cluster.
- [ ] **Step 5: Docs:** README (both clusters, URLs, ports, start/stop for each, kubeconfig paths), `add-an-app.md` (staging URL on 8082, Part 3 makes one key per environment and stores it as an environment secret), `how-deploys-work.md` (replace "serves one cluster" with the two-cluster picture and the reader account), CLAUDE doc ports line.
- [ ] **Step 6: User on GitHub:** add runner labels `k3s-staging`, `k3s-prod`; create the 6 environment secrets and `STAGING_READER_KUBECONFIG` in `prod`; delete the 3 repo-level `DEPLOYER_KUBECONFIG_*` secrets.
- [ ] **Step 7: End-to-end proof:**
  - Actions → Deploy, by hand: `fe-main-user`, `staging`, its current image → "already runs …; nothing to do" (staging key, staging runner label).
  - Promote the pending dashboard banner: merge `staging` → `main` in `2026-kanso-fe-dashboard`, approve the prod deploy → prod `/dashboard/version.txt` = `d90567e11632`, rollout history `promote ...`. This exercises the reader key across clusters.
  - Actions → Rollback `fe-dashboard` in `prod`, then promote again, to prove rollback on the prod cluster.
- [ ] **Step 8: Commit and push** (only after the user says so)
