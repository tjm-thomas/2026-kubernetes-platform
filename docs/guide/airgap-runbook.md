# Taking this platform into an airgapped GitLab

What to build, what to ask, and what is deliberately left blank. Read
[how-deploys-work.md](how-deploys-work.md) for the model and
[github-to-gitlab.md](github-to-gitlab.md) for the GitHub→GitLab mapping; this page is
only about moving the GitLab version into a closed network.

The short version: **staging can be built on decisions we are allowed to make. Prod
cannot.** Prod's remaining unknowns are governance, not engineering — someone has to own
prod and say what is permitted. So staging gets built, and prod gets handed over as a
contract with blanks.

## Confirmed on the target instance

Checked against a real project on the enterprise instance, with Owner rights:

| Feature | Status | Why it was make-or-break |
|---|---|---|
| **File-type CI/CD variables** | present | Kubeconfigs must arrive as a *path*. A plain variable hands the scripts the file's *content*, and the error echoes the key into the job log. This happened once on gitlab.com. |
| Pipeline variables on manual runs | work, no role setting | Instance predates the "Minimum role to use pipeline variables" lockdown, so the Run-pipeline screen has a Variables box with no extra setup. |
| Pipeline trigger tokens | present | How an app project starts the platform project's deploy. Replaces GitHub's PAT. |
| Protected branches, role-based push/merge | present | The prod fence: protected variables only reach protected refs. |
| Project-specific runner registration | offered | We may register our own runners rather than depending on shared ones. Decides runner placement below. |

One version signal: the instance still offers **registration tokens**, deprecated in
GitLab 16.0. Confirm the version from `/help` — it also decides whether `resource_group`
and `workflow:rules` behave as our files assume.

## Still to confirm

| # | Question | Where |
|---|---|---|
| 1 | **Where do images live?** GitLab's own container registry is **disabled instance-wide** — no Container registry toggle in Settings → General → Visibility, project features, permissions, and no sidebar entry beside the Package Registry. A *Package* registry is not a substitute: Kubernetes pulls OCI images. So images live in a central Harbor/Nexus/Artifactory and the admins own the hostname. | registry owner |
| 2 | **Do cluster pulls need credentials?** Central registries usually require auth even to pull, so the Deployment template probably needs `imagePullSecrets` — not built yet, see Gaps. | registry owner |
| 3 | **Where may a runner live?** | Platform team. See Runner placement. |
| 4 | **Can that spot reach both cluster APIs?** | A job that runs `curl -sS -k -m 10 https://<api-host>:6443/version`. Moot if runners live inside the clusters. |
| 5 | **Is the gitlab-runner image/binary mirrored internally?** | Whoever owns the mirror. Nothing installs without it. |
| 6 | **GitLab tier** | `/help`. Premium adds protected environments and deployment approvals — a stronger prod gate than branch protection. |

## Runner placement — decide before anything else

The runner holds the deploy credentials and does the deploying. Where it lives decides
what it can reach, who can read its secrets, and whether prod deploys survive one
person's laptop being off.

| | A — pod inside each cluster | B — VM beside the clusters | C — a workstation |
|---|---|---|---|
| Executor | `kubernetes` | `shell` or `docker` | `shell` |
| Reaching the cluster API | free, it is inside | confirm once | often blocked: workstations sit on a user network, clusters on a server network |
| Survives you being away | yes | yes | no |
| Who can read job secrets | cluster admins | the VM's admins | anyone local admin on that box, including endpoint management |
| Needs | runner image mirrored, Helm install per cluster | a machine assigned | nothing |

**A is the default recommendation**, with B acceptable where a managed VM already exists.
C is for a pilot you intend to throw away — say so out loud at handover, because pilots
become production by accident.

Under A you register **two** runners against the platform project — tag `k3s-staging`
installed in the staging cluster, tag `k3s-prod` in the prod cluster. `.gitlab-ci.yml`
already selects by tag, so no code changes. A job tagged `k3s-prod` then physically
cannot touch staging.

A moves job execution inside the prod security boundary, so it must be done deliberately:

- mark the runner **Protected**, so only protected-ref jobs reach it
- the runner's own service account may create job pods in its own namespace and nothing
  else — **not** deploy rights
- all authority stays in the per-app kubeconfig File variables, where it is today
- never mount a Docker socket into a runner pod: that is root on the node, and it can
  read every secret mounted there

## Build capability: staging may, prod must not

The prod fence rests on one rule — **prod only runs an image staging is already
running** — and that holds only because prod cannot produce an image. A usable Docker
daemon on a prod node removes the rule without any error appearing.

| | Staging nodes | Prod nodes |
|---|---|---|
| Docker present | acceptable | no reason to have it |
| Runner may build images | yes | never |
| Runner's whole job | build, then deploy | pull an approved image and roll it |

Two details worth knowing: k3s uses containerd, so an image built with Docker on a node
is **not** visible to the cluster unless imported into containerd — building on a node is
pointless anyway without pushing to the registry. And if development happens outside the
closed network, images are **imported** into the internal registry and *neither* cluster
needs a build capability. That is the cleanest version of this design and the one to aim
for.

## Images the platform needs before any of ours

These are third-party, pulled from the public internet today, and nothing in a closed
network can reach them. They must be mirrored into the internal registry — or pre-loaded
onto the nodes — before `setup.sh` will even complete.

| Image | Where | Fails as |
|---|---|---|
| `ghcr.io/headlamp-k8s/headlamp:v0.46.0` | `cluster/manifests/headlamp.yaml` | `setup.sh` hangs at the Headlamp rollout |
| k3s's own bundle: Traefik, CoreDNS, metrics-server, pause | pulled by k3s on first start | the cluster never becomes ready |

k3s publishes an airgap images tarball per release for exactly this. Load it on each node
before starting the cluster. Repoint `headlamp.yaml` at the internal copy, or drop Headlamp
if the site has its own cluster UI.

## Building staging

1. **Projects.** One GitLab project per repo (platform + each app). Push `main`, and
   `staging` for app repos.
2. **Registry.** Get the internal registry's hostname (answer 1 above) and put it in
   `IMAGE_REPO` in `apps/<app>/app.env`. It is a space-separated allow-list; drop the
   public entries for the airgapped copy. Because GitLab's own registry is off, the build
   job cannot use `CI_REGISTRY_IMAGE` or `CI_JOB_TOKEN` — see Gaps.
3. **Platform project variables** — Settings → CI/CD → Variables, all **Protected**:
   - `DEPLOYER_KUBECONFIG_<APP>` — **type File**, scoped to environment `staging`, one per app
   - the same scoped to `prod`
   - `STAGING_READER_KUBECONFIG` — **type File**, scoped to `prod` only
   Environments do not exist until first deploy: type the name and choose "Create wildcard".
4. **Trigger token.** Platform project → Settings → CI/CD → Pipeline trigger tokens. Put
   it in each app project as `PLATFORM_TRIGGER_TOKEN` (masked, protected), and set that
   app's `PLATFORM_PROJECT_ID` in its `.gitlab-ci.yml`.
5. **Protect branches.** Platform: `main`. App repos: `main` and `staging` — Developers
   may push to `staging`, nobody force-pushes.
6. **Runners.** Per the placement decision. Tags `k3s-staging`, `k3s-prod`.
7. **Cluster addresses.** `environments/<env>/env.conf` currently reaches the clusters at
   `127.0.0.1` because the runner shares the box. Set `API_SERVER` to the real hostname,
   and regenerate the deployer kubeconfigs so their server address matches.
8. **Prove it.** Push to `staging` and watch it deploy; merge to `main` and press play on
   `deploy-prod`; run a rollback; confirm a pipeline on an unprotected branch fails with
   `variable … is not set`.

## Prod: the blanks

Hand this table to whoever owns prod. Nothing here needs re-engineering — every row is
read from `environments/prod/env.conf` or a CI variable.

| Blank | Answer | Fills in |
|---|---|---|
| Runner placement | | executor, and one line in each job |
| Cluster API hostname | | `API_SERVER`, deployer kubeconfigs |
| One VM or several | | nothing in our code |
| Docker present on prod nodes | | whether the promotion gate is real |
| Registry hostname | | `IMAGE_REPO` |
| Pull credentials needed | | `imagePullSecrets` (see Gaps) |
| Who may press the prod button | | branch protection, or Premium protected environments |
| Replica count for prod | | `REPLICAS_PROD` in each `app.env` |

## Gaps in the platform code

Known, small, and not yet built — they become real when the answers above arrive:

- **`imagePullSecrets`** is absent from the Deployment template. Needed the moment the
  internal registry requires authentication to pull — likely, since GitLab's registry is
  off and images come from a central one.
- **The registry is not GitLab's.** `ci/gitlab-build-deploy.sh` derives its target from
  `CI_REGISTRY_IMAGE` and authenticates with `CI_JOB_TOKEN`; both are GitLab-registry
  only and will be empty/useless here. Replace with a configured `REGISTRY_BASE` variable
  and credentials the registry owner issues, stored as masked CI variables.
- **Image builds vs imports.** `ci/gitlab-build-deploy.sh` builds from source. Where
  images are imported from outside, its first half becomes "verify the image exists in
  the registry", keeping the same trigger. Scan gates (code scanning, Parasoft) slot in
  as stages before the trigger.
- **`DEPLOY_SYSTEM`** is compared byte-for-byte, so a stray CRLF makes both CI systems
  skip silently.
