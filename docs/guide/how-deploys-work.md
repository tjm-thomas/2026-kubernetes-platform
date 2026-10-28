# How a deploy reaches the cluster

This page explains **how the cluster learns that an app changed**, and **how many clusters the
platform serves today**. To plug in a new app, see [add-an-app.md](add-an-app.md).

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
   reviewer must click **Approve and deploy**. The job then runs on the **self-hosted runner**,
   which sits on the same PC as the cluster and can reach its API at `127.0.0.1:6443`.
4. **[`ci/deploy.sh`](../../ci/deploy.sh) checks the image.** Prod only accepts the image staging
   runs right now, and only if staging is healthy. Otherwise it refuses.
5. **It changes the Deployment:** `kubectl set image deploy/<app> app=<image>`. It logs in as that
   app's restricted deploy account, which can change only that app's Deployment.
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

## The platform serves one cluster

Today everything targets **one k3s cluster with one node**: the `k3s` Docker container on the
local PC.

- **Staging and prod are not separate clusters.** They are two namespaces, `kanso-staging` and
  `kanso-prod`, inside that one cluster.
- **Every deploy goes to `127.0.0.1:6443`.** The deploy keys, the GitHub secrets and the runner all
  point there.

A multi-node setup would still be **one** cluster, spread over several
machines. To serve a **second** cluster, for example a separate prod cluster, the platform would
need:

- a kubeconfig and a secret for each app on **each** cluster;
- a way to tell the deploy scripts which cluster an environment lives on;
- a new way for the prod check in step 4 to read what staging runs, because staging would then be
  on another cluster.
