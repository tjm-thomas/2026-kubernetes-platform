# kanso-platform

A generalised k3s platform that deploys application repos as swappable modules. Kanso
(`kanso-frontend`, `kanso-backend`) is the placeholder app. It's a GitHub demo of a setup that
will later run on self-managed GitLab behind a closed network, so keep everything transferable.

Full context, decisions and solved gotchas: `docs/handover-kanso-platform.md`. Read it first.

## Fixed decisions (don't reopen)

- k3s only, running in one Docker container locally. Push-based deploys; **no GitOps tools**.
- **Only this repo deploys.** App repos build on GitHub-hosted runners, push to GHCR, and trigger
  this repo's deploy workflow with `app`, `env`, `image`. The self-hosted runner serves this repo only.
- Per app repo: push to `staging` deploys to staging; merge to `main` promotes. **Prod only takes
  the image staging currently runs.** Image tag = git tree hash of the app's content. Never
  rebuild or overwrite an existing tag.
- One namespace per environment (`kanso-staging`, `kanso-prod`) holding all apps. Ingress by
  path (`/` frontend, `/api` backend). One restricted deployer account per app.
- App modules live in `apps/<name>/`. `environments/<env>/apps.txt` decides what runs where.

## This machine (Windows 11, Git Bash, Docker Desktop)

- Workflows: `shell: C:\PROGRA~1\Git\bin\bash.exe --noprofile --norc -eo pipefail {0}`. Plain
  `bash` is WSL, and quoted paths with spaces aren't accepted.
- `MSYS_NO_PATHCONV=1` only on `docker exec` calls with container paths. Never export it.
- Ports: ingress `8081` (8080 is taken), API `6443`. URLs use `*.localhost`.
- For scripted edits that contain backslashes, write a node script file or use the Edit tool.

## Working rules

- Simple English, short concrete answers, small steps.
- **Commit only when the user says "commit"; push only when they say "push".** The repos are public.
- Never print secrets (passwords, tokens, kubeconfigs). `.secrets/` and `kubeconfig/` are git-ignored.
- Anything that needs the user's GitHub login (runner tokens, secrets, package settings): give
  exact steps; the user does it.
- Verify before claiming: curl through the ingress, `/version.txt` per host, `rollout history`,
  headless Chrome screenshots for UI.
