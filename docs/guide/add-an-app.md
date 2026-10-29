# Add an app to the platform

This guide plugs **any** containerised app into the Kubernetes platform: a frontend, a backend
or anything else. It runs next to the existing apps without touching them.

Follow the parts in order. Each part ends with a check. Don't move on until the check passes.

This guide wires the app to **GitHub**. To deploy it through GitLab instead, do the same parts
and then map the GitHub pieces using [github-to-gitlab.md](github-to-gitlab.md).

---

## The idea in one minute

- **The app's code** lives in its own repo. That repo builds a Docker image.
- **This platform repo** says how to run that image. Each app gets one folder, `apps/<name>/`.
  We call that folder the app's **slot**.
- **`environments/<env>/apps.txt`** switches the slot on in `staging` or `prod`.
- **Only this repo deploys.** The app repo builds the image, then asks this repo's **Deploy**
  workflow to roll it out.
- **New versions go to staging first.** Prod only accepts the exact image staging is running,
  and a human must approve it.

```
app repo ──build──▶ image in GHCR ──"please deploy"──▶ platform Deploy workflow ──▶ cluster
```

Both environments share one host each. A path picks the app:

| Path | App |
|---|---|
| `kanso.localhost:8081/` | `fe-main-user` |
| `kanso.localhost:8081/dashboard` | `fe-dashboard` |
| `kanso.localhost:8081/api` | backend |

The longest matching path wins. Staging runs on its own cluster and uses
`staging.kanso.localhost:8082`.

---

## Before you start

**Your PC needs:**

- Git Bash, Docker Desktop, and a clone of this repo.
- Both clusters running (staging and prod):
  ```bash
  cd cluster && docker compose up -d && cd ..
  ```
- The GitHub runner running. Open `C:\Users\user\actions-runner-platform` and run `run.cmd`.
  It should say `Listening for Jobs`.

**Get admin access.** Run all commands from the platform repo root, in Git Bash. `ks` talks to the
staging cluster, `kp` to the prod cluster:

```bash
ks() { kubectl --kubeconfig "$PWD/cluster/kubeconfig/staging.yaml" "$@"; }
kp() { kubectl --kubeconfig "$PWD/cluster/kubeconfig/kubeconfig.yaml" "$@"; }
ks get nodes; kp get nodes      # each shows one node, Ready
```

**Who does what.** Some steps need GitHub owner rights (secrets, tokens, package settings). If you
don't have them, ask whoever owns the `tjm-thomas` org. Those steps are marked **(owner)**.

---

## Part 0. Check that the app fits

Answer these questions before you write anything. If any answer is "no", fix the app first.

| # | Question | Why it matters |
|---|---|---|
| 1 | Does it have a `Dockerfile` that builds and runs with no extra arguments? | The pipeline only runs `docker build .` |
| 2 | Does it listen on **one** HTTP port? Note it down (for example `80`, `8080`, `3000`). | This becomes `PORT` |
| 3 | Is there a URL that returns **200** when the app is healthy? Note it down (for example `/healthz`). | This becomes `HEALTH_PATH`. Kubernetes restarts the app if this URL fails |
| 4 | Which **path** will it live under (for example `/api` or `/reports`)? | This becomes `PATH_PREFIX` |
| 5 | Does the app answer requests **with that prefix still in the URL**? | The platform does **not** strip the prefix. A request for `/reports/x` reaches the app as `/reports/x` |
| 6 | If it's a website on a sub-path: are its own CSS and JS links **relative** (`app.js`, not `/app.js`)? | `/app.js` would load from the app on `/`, not from yours |
| 7 | How much memory does it use? Note it down (for example `docker stats` while it runs). | This becomes `MEMORY_LIMIT` (default `128Mi`). Above it, the app is killed |
| 8 | Does it run without root-level privileges? | The namespaces enforce Pod Security `baseline` |

Pick a **name** for the app: lowercase letters, digits and `-` only. For example `reports-api`.
This guide writes it as `<name>`.

> **Tip:** if the app can't handle a path prefix (question 5), stop and ask before going on.
> The other choice is a separate host, which needs a small platform change.

---

## Part 1. App repo: build the first image

1. **(owner)** Create an empty **public** repo `tjm-thomas/2026-kanso-<name>`.
2. Clone it next to this repo, in `Documents/GitHub/`. Add the app code and its `Dockerfile` on
   `main`, then commit and push.
3. Copy the build workflow from the existing app:
   `2026-kanso-fe-main-user/.github/workflows/build-deploy.yml`
   → `.github/workflows/build-deploy.yml` in your repo.
4. In that file, change the three lines under `env:`:
   ```yaml
   APP: <name>
   PLATFORM_REPO: tjm-thomas/2026-kubernetes-platform     # leave as is
   IMAGE_REPO: ghcr.io/tjm-thomas/2026-kanso-<name>
   ```
   If the `Dockerfile` doesn't accept `--build-arg VERSION=...`, that's fine. The argument is
   ignored.
5. **(owner)** Create the token that lets this repo ask the platform to deploy. Go to profile picture →
   **Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token**:
   - Name: `kanso-<name> deploy`. Resource owner: **`tjm-thomas`**.
   - Repository access: **Only select repositories → `2026-kubernetes-platform`**.
   - Permissions → Repositories → **Actions: Read and write**. Nothing else.
6. **(owner)** In the app repo, go to **Settings → Secrets and variables → Actions → New repository
   secret**. Name: **`PLATFORM_DEPLOY_TOKEN`**. Value: the token.
7. Create the `staging` branch and push it:
   ```bash
   git switch -c staging && git push -u origin staging
   ```
   This starts **Actions → Build and deploy**. The first run **stops on purpose** at
   *"Check the cluster can pull the image"*, because new packages start private.
8. **(owner)** Make the image public. Go to **github.com/tjm-thomas → Packages → 2026-kanso-<name> →
   Package settings → Change visibility → Public**.
9. Write down the image name with its tag. It's the repo's tree hash:
   ```bash
   git rev-parse --short=12 'HEAD^{tree}'      # run in the app repo, on staging
   ```
   The image is `ghcr.io/tjm-thomas/2026-kanso-<name>:<that hash>`.

**Check:** this pulls the image without logging in and prints JSON:
```bash
docker logout ghcr.io; docker manifest inspect ghcr.io/tjm-thomas/2026-kanso-<name>:<hash> | head -3
```

---

## Part 2. Platform repo: create the slot

1. Copy an existing slot:
   ```bash
   cp -r apps/fe-main-user apps/<name>
   ```
2. Edit **`apps/<name>/app.env`**. Every line is needed, except `MEMORY_LIMIT`:
   ```bash
   IMAGE_REPO=ghcr.io/tjm-thomas/2026-kanso-<name>
   INITIAL_IMAGE=ghcr.io/tjm-thomas/2026-kanso-<name>:<hash from Part 1>
   PATH_PREFIX=/<path>            # e.g. /api
   PORT=<port>                    # e.g. 8080
   HEALTH_PATH=<health url>       # e.g. /api/status
   REPLICAS_STAGING=1
   REPLICAS_PROD=2
   MEMORY_LIMIT=<limit>           # e.g. 384Mi for Spring Boot; optional, default 128Mi
   ```
   Also change the comment at the top so it names your app and repo.
3. Don't touch `apps/<name>/base/*.yaml` unless you need to. They are templates, and `${...}` is
   filled in from `app.env`.
4. Switch it on in **staging only**. Add a line with `<name>` to
   **`environments/staging/apps.txt`**.
5. Apply it:
   ```bash
   ./scripts/setup.sh
   ```
   Look for `app <name>: ...` under `[staging] Environment`. It ends with
   `deployment "<name>" successfully rolled out`.

**Check:**
```bash
ks -n kanso-staging get pods -l app=<name>        # READY 1/1, STATUS Running
kp -n kanso-prod get deploy                       # your app is NOT here: prod untouched
pw="$(cat .secrets/staging-password.txt)"
curl -u "staging:$pw" -H 'Host: staging.kanso.localhost' http://127.0.0.1:8082/<path>
```
The last command should return your app's response. Also open
`http://staging.kanso.localhost:8082/<path>` in a browser. The user is `staging`; the password is in
`.secrets/staging-password.txt`.

---

## Part 3. Give the pipeline its key

`setup.sh` created a restricted account, `deploy-<name>`, on the staging cluster. It can change
**only** this app's Deployment. The pipeline needs a login file for it. Each cluster has its own
account, so each environment gets its own file (prod's comes in Part 5).

1. Create the file:
   ```bash
   ./scripts/make-deployer-kubeconfig.sh <name> staging    # prints .secrets/staging/deploy-<name>.kubeconfig
   ```
   It's a secret. `.secrets/` is git-ignored. Never commit it, paste it in chat, or email it.
2. **(owner)** In the **platform** repo, go to **Settings → Environments → staging → Environment
   secrets → Add environment secret**:
   - Name: **`DEPLOYER_KUBECONFIG_<NAME>`**. Use capitals, and change `-` to `_`. For example
     `reports-api` → `DEPLOYER_KUBECONFIG_REPORTS_API`.
   - Value: the whole content of `.secrets/staging/deploy-<name>.kubeconfig`.

   Use an **environment** secret, not a repository secret: the `prod` environment holds a secret
   with the same name, for the prod cluster.

**Check:** the account can change your app and nothing else:
```bash
K="kubectl --kubeconfig .secrets/staging/deploy-<name>.kubeconfig"
$K auth can-i patch deploy/<name> -n kanso-staging        # yes
$K auth can-i patch deploy/fe-main-user -n kanso-staging  # no
```

---

## Part 4. Publish the platform change

The Deploy workflow reads `apps.txt` from the platform repo's `main` on GitHub. So the change must
be pushed before the pipeline can deploy the app.

```bash
git add apps/<name> environments/staging/apps.txt
git commit -m "Add <name> app to staging"
git push
```

Then, in the **app** repo, go to **Actions → the stopped run → Re-run jobs → Re-run failed jobs**.

**Check:**
- The app run goes green.
- The platform repo's **Actions** shows **Deploy <name> to staging (...)** in green. The first time,
  it says "already runs …; nothing to do", because `setup.sh` already started that image.

From now on, every push to the app's `staging` branch builds the image and deploys it to staging
on its own.

---

## Part 5. Go to prod

1. Add `<name>` to **`environments/prod/apps.txt`**, then run:
   ```bash
   ./scripts/setup.sh
   git add environments/prod/apps.txt && git commit -m "Add <name> app to prod" && git push
   ```
   Prod now runs `INITIAL_IMAGE`.
2. Create the prod key: `./scripts/make-deployer-kubeconfig.sh <name> prod`.
   **(owner)** Add its content as **`DEPLOYER_KUBECONFIG_<NAME>`** under
   **Settings → Environments → prod → Environment secrets**, as in Part 3. The `prod` environment
   already holds `STAGING_READER_KUBECONFIG`, which all apps share.
3. For each later release, in the **app** repo, open a pull request **`staging` → `main`** and merge it.
4. **(owner)** In the platform repo, go to **Actions → Deploy <name> to prod → Review deployments →
   Approve and deploy**.

**Check:**
```bash
kp -n kanso-prod get pods -l app=<name>                      # Running, 2 pods
kp -n kanso-prod rollout history deploy/<name> | tail -1     # "promote ..."
```

Prod only accepts the image staging runs. If it refuses with *"staging runs …, not …"*, push the
change to `staging` first and wait for it to finish.

---

## Everyday commands

| Task | How |
|---|---|
| Roll back one app | Platform repo → **Actions → Rollback** → app `<name>`, env `staging` or `prod` |
| See what runs where | `ks get deploy -A`, `kp get deploy -A`, or Headlamp at `http://staging.kubernetes.localhost:8082` (staging) and `:8081` (prod) |
| Headlamp login token | `docker exec k3s-staging kubectl -n headlamp create token headlamp-admin` (staging), `docker exec k3s ...` (prod) |
| See an app's logs | `ks -n kanso-staging logs deploy/<name>` |
| Deploy history | `ks -n kanso-staging rollout history deploy/<name>` |

## Remove an app

1. Delete its line from `environments/<env>/apps.txt` (one environment or both).
2. Run `./scripts/setup.sh`. It removes the app from those environments only. Then commit and push.
3. To remove it completely, also:
   - delete `apps/<name>/`
   - delete the environment secret `DEPLOYER_KUBECONFIG_<NAME>` in `staging` and in `prod`
   - delete the app repo's token
   - on each cluster, run `ks -n ci delete sa/deploy-<name> secret/deploy-<name>-token` (and the same with `kp`)

## When something goes wrong

| You see | Likely cause | Fix |
|---|---|---|
| Pod `ImagePullBackOff` | Package is private, or the image name or tag is wrong | Part 1, step 8. Compare `INITIAL_IMAGE` with the package page |
| Pod `CrashLoopBackOff`, or `READY 0/1` | Wrong `PORT` or `HEALTH_PATH`, or the app crashes | `ks -n kanso-staging describe pod -l app=<name>` and `logs deploy/<name>` |
| Pod status `OOMKilled` | The app uses more than `MEMORY_LIMIT` | Raise `MEMORY_LIMIT` in `app.env`, run `setup.sh` |
| `404` on your path | App not listed in `apps.txt`, wrong `PATH_PREFIX`, or the app doesn't handle the prefix | Part 0, question 5. Re-run `setup.sh` |
| Your page loads, but CSS/JS come from another app | Absolute links like `/app.js` | Part 0, question 6 |
| `401` on staging | Staging needs the password | User `staging`, password in `.secrets/staging-password.txt` |
| Deploy: *"not listed in environments/…/apps.txt"* | The platform change isn't pushed yet | Part 4 |
| Deploy: *"only runs images from …"* | `IMAGE_REPO` in `app.env` doesn't match the workflow | Make both say `ghcr.io/tjm-thomas/2026-kanso-<name>` |
| Deploy: *"Secret DEPLOYER_KUBECONFIG_… is not set"* | Secret missing in that environment, or its name is wrong | Part 3, step 2 (staging) or Part 5, step 2 (prod) |
| Deploy: *"The deployer kubeconfig points at …, but <env> is at …"* | The key for the other cluster was saved in this environment | Replace it with `.secrets/<env>/deploy-<name>.kubeconfig` |
| Deploy to prod: *"STAGING_READER_KUBECONFIG is not set"* | The `prod` environment lacks the read-only staging key | `./scripts/make-reader-kubeconfig.sh`, add its content to the `prod` environment |
| App run: *"Secret PLATFORM_DEPLOY_TOKEN is not set"*, or `403` | Token missing, expired or wrong permission | Part 1, steps 5–6 |
| Run stuck on *"Waiting for a runner"* | `run.cmd` isn't running | Start it in `C:\Users\user\actions-runner-platform` |
| Deploys stopped working after a cluster was wiped (`docker compose down -v`) | That cluster's keys are new | Run `setup.sh`, then make that environment's keys again for every app (and the reader key, for staging) and update the environment secrets |
