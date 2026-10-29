# kanso-platform

A generalised k3s platform that deploys application repos as swappable modules. Kanso
(`kanso-frontend`, `kanso-backend`) is the placeholder app. It's a GitHub demo of a setup that
will later run on self-managed GitLab behind a closed network, so keep everything transferable.

How to add an app: `docs/guide/add-an-app.md`. How deploys reach the cluster: `docs/guide/how-deploys-work.md`.

## Fixed decisions (don't reopen)

- k3s only. One cluster per environment: locally `k3s-staging` and `k3s` (prod), one Docker
  container each. Push-based deploys; **no GitOps tools**.
- **Only this repo deploys.** App repos build their image and trigger this repo's deploy with
  `app`, `env`, `image` — on GitHub: GitHub-hosted runners, GHCR, the GitHub self-hosted runner
  serves this repo only. On GitLab: the group runner on the cluster PC also builds app images
  (tag `builder`), and every job it runs executes as SYSTEM with Docker on the cluster PC — keep
  it marked Protected so only protected-ref jobs reach it.
- Per app repo: push to `staging` deploys to staging; merge to `main` promotes. **Prod only takes
  the image staging currently runs.** Image tag = git tree hash of the app's content. Never
  rebuild or overwrite an existing tag.
- One namespace per environment (`kanso-staging`, `kanso-prod`) holding all apps, each on its own
  cluster. Ingress by path (`/` frontend, `/api` backend). One restricted deployer account per app
  per cluster (GitHub environment secrets). The prod check reads staging through the read-only
  `staging-reader` account.
- App modules live in `apps/<name>/`. `environments/<env>/apps.txt` decides what runs where.
- **GitLab runs in parallel** (group `tjm-thomas` on gitlab.com, public): same scripts, thin
  `.gitlab-ci.yml` wrappers, images in `registry.gitlab.com/tjm-thomas/<repo>`, one group runner
  (tags `k3s-staging`, `k3s-prod`, `builder`). `DEPLOY_SYSTEM` in each app repo picks the deploying
  system (missing = GitHub); `fe-main-user` is on GitLab. Key variables are Protected **File**
  variables scoped per environment. Mapping and enterprise notes: `docs/guide/github-to-gitlab.md`.

## This machine (Windows 11, Git Bash, Docker Desktop)

- Workflows: `shell: C:\PROGRA~1\Git\bin\bash.exe --noprofile --norc -eo pipefail {0}`. Plain
  `bash` is WSL, and quoted paths with spaces aren't accepted.
- `MSYS_NO_PATHCONV=1` only on `docker exec` calls with container paths. Never export it.
- Ports: prod ingress `8081` (8080 is taken) and API `6443`; staging ingress `8082` and API `6444`.
  URLs use `*.localhost`.
- `docker exec -i` (used by `kc`) reads stdin: inside `while read` loops, give commands `</dev/null`.
- For scripted edits that contain backslashes, write a node script file or use the Edit tool.

## Working rules

- Simple English, short concrete answers, small steps.
- **Commit only when the user says "commit"; push only when they say "push".** The repos are public.
- Never print secrets (passwords, tokens, kubeconfigs). `.secrets/` and `kubeconfig/` are git-ignored.
- Anything that needs the user's GitHub login (runner tokens, secrets, package settings): give
  exact steps; the user does it.
- Verify before claiming: curl through the ingress, `/version.txt` per host, `rollout history`,
  headless Chrome screenshots for UI.
