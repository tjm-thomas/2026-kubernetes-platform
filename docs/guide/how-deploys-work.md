# How a deploy reaches the cluster

This page explains **how the cluster learns that an app changed**, and **how the platform serves
two clusters**. To plug in a new app, see [add-an-app.md](add-an-app.md).

---

## GitHub tells the cluster; the cluster doesn't watch for changes

The platform uses a **push model**. k3s does not poll GitHub or the image registry for new
versions. It only acts when something changes a Deployment through the Kubernetes API. Here, that
something is the platform repo's **Deploy** workflow.

```
app repo ──merge──▶ app workflow ──"please deploy"──▶ platform Deploy workflow
                                                        │ (approval for prod)
                                                        ▼
                                       self-hosted runner: ci/deploy.sh
                                                        │ kubectl set image
                                                        ▼
                                       cluster pulls the image, replaces pods
```

### Promoting from staging to prod, step by step

1. **Someone merges `staging` → `main` in the app repo.** The app's workflow does **not** rebuild.
   It works out the image tag (the git tree hash of the content), which is the same tag staging
   runs.
2. **The app repo asks the platform to deploy.** It calls the platform's Deploy workflow with the
   app, `prod` and the image, using the `PLATFORM_DEPLOY_TOKEN` secret.
3. **The platform workflow waits for approval.** `prod` is a protected GitHub environment, so a
   reviewer must click **Approve and deploy**. The job then runs on the **self-hosted runner**
   labelled `k3s-prod`, which sits on the same PC as the clusters and can reach their APIs.
4. **[`ci/deploy.sh`](../../ci/deploy.sh) checks the image on the staging cluster.** It logs in
   there with a **read-only** account, `staging-reader`. Prod only accepts the image staging runs
   right now, and only if staging is healthy. Otherwise it refuses.
5. **It changes the Deployment on the prod cluster:** `kubectl set image deploy/<app> app=<image>`.
   It logs in as that app's restricted deploy account on the prod cluster, which can change only
   that app's Deployment.
6. **Kubernetes takes over:**
   - It sees that the Deployment's desired image changed.
   - It **pulls** that image from GHCR and starts a new pod.
   - When the new pod passes its health check, it removes an old pod.
   - It repeats until every pod runs the new image. No pod is removed before its replacement is
     ready, so the app keeps serving.

A deploy to **staging** works the same way, except: the app workflow builds the image first
(push to the `staging` branch), there is no approval, and step 4 is skipped.

### So who does what?

| Who | Does what |
|---|---|
| GitHub (the Deploy workflow) | Decides **when** something changes, and **what** image to run |
| The cluster | Pulls that image and swaps the pods safely |

The trigger comes from GitHub. Only the image download is pulled by the cluster.

Tools like Argo CD or Flux work the other way round: the cluster watches git and pulls changes in.
This platform does **not** use them, by design.

---

## The platform serves two clusters

Each environment runs on its **own** k3s cluster. Locally, each one is a Docker container:

| Environment | Cluster | API | Namespace |
|---|---|---|---|
| staging | `k3s-staging` | `127.0.0.1:6444` | `kanso-staging` |
| prod | `k3s` | `127.0.0.1:6443` | `kanso-prod` |

The clusters share no namespace and no accounts: the deploy scripts can only change staging with
staging keys, and prod with prod keys. One gap remains: today one self-hosted runner, on the PC
that runs both clusters, serves both environments, and that PC can reach both clusters as admin
through Docker. Separate runners on separate machines close that gap.

**How each part knows which cluster to use:**

- **`environments/<env>/env.conf`** names the cluster: the container for admin access, and the
  API address that goes into deploy keys. Every script reads it.
- **Deploy keys are per app and per cluster.** Each GitHub environment (`staging`, `prod`) holds its
  own `DEPLOYER_KUBECONFIG_<APP>` secret, for its own cluster. A key for the wrong cluster is
  refused before anything changes.
- **The prod check reads staging with `STAGING_READER_KUBECONFIG`**, a read-only account on the
  staging cluster. It can look at Deployments in `kanso-staging`, and nothing else. Only the `prod`
  environment holds it.
- **The workflows pick the runner by environment** (labels `k3s-staging`, `k3s-prod`). Today one
  runner carries both labels.

To move a cluster to another machine later, point its `env.conf` at an admin kubeconfig
(`CLUSTER_ADMIN_KUBECONFIG`) and its new `API_SERVER`, then make its keys again.

**The same model runs on GitLab.** Push to `staging` deploys, merge to `main` plus a manual
play press promotes, and the same `ci/deploy.sh` enforces the same gates. What each GitHub
piece becomes on GitLab — tokens, secrets, runner, prod gate — is in
[github-to-gitlab.md](github-to-gitlab.md). Which system deploys an app is decided by the
`DEPLOY_SYSTEM` file in that app's repo.
