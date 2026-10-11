# podroid-homelab-gitops

GitOps homelab for a Samsung Galaxy Z Fold 4 running **Podroid** — an Alpine
ARM64 VM on the phone. Everything is driven by this repo:

- **Podman + podman-compose** (no Docker anywhere)
- a **one-line installer** that sets up the VM in seconds
- a **self-updater** that syncs every 12 hours, redeploys only what changed,
  healthchecks it, and **rolls back automatically** on failure
- an **AI app generator**: open a GitHub issue, a workflow asks a free
  OpenRouter model for the app files and opens a pull request
- a demo app (`whoami`) that doubles as the reference template

## Install (one line)

Run this **inside the Podroid VM** (Alpine, aarch64, as root):

```sh
curl -fsSL https://raw.githubusercontent.com/muxd22-alt/podroid-homelab-gitops/main/bootstrap/install.sh | sh
```

The installer is idempotent — re-run it any time. It:

1. installs `git curl bash podman podman-compose openrc dcron`
2. clones/updates the repo to `/root/homelab`
3. creates `.env` files from `.env.example` (secrets never live in git)
4. installs the `podroid-gitops` OpenRC service (reconcile at boot)
5. adds a cron entry: `0 */12 * * *` → `bootstrap/updater.sh`
6. deploys every app and runs its healthcheck (5 retries)

## How it works

```
you: edit apps/, push to main
        │
        ▼
12h cron ──► bootstrap/updater.sh
              ├─ lock file (runs never overlap)
              ├─ git fetch; if no change → exit quietly
              ├─ deploy only apps whose files changed
              ├─ healthcheck each app (5 tries × 10s)
              ├─ health failed? git reset --hard <previous commit>
              │                redeploy, log "ROLLED BACK TO <sha>"
              └─ success → podman image prune -f
```

All logs go to the RAM disk — `/tmp/homelab-logs/updater.log` — to spare the
phone's UFS flash from write wear.

### Day-2 commands

```sh
homelab sync        # manual git sync + deploy + healthcheck
homelab status      # git state, services, containers, last log lines
homelab apps        # list apps with images and ports
homelab logs        # tail the updater log (homelab logs <app> = container log)
homelab version     # installed commit info
```

## Adding an app — the AI way

1. Open a **New app request** issue (the template labels it `app-request`).
2. `.github/workflows/ai-app-generator.yml` runs and asks an OpenRouter
   **free model** (`nvidia/nemotron-3-super-120b-a12b:free` by default;
   override with the `OPENROUTER_MODEL` repo variable — allowlisted models
   only) to generate:
   - `apps/<slug>/compose.yml` (arm64 pin, limits, log caps)
   - `apps/<slug>/app.yml` (metadata)
   - `apps/<slug>/.env.example`
   - `apps/<slug>/healthcheck.sh`
3. The workflow validates: unique slug, host port ≥ 1024 and not taken,
   **arm64 manifest** must exist for the image. Failures are commented on
   the issue.
4. A PR (`feat(app): add <slug>`) is opened and the issue gets a comment
   with the link. Merge it; the next updater cycle deploys it.

### Adding an app — the manual way

Copy `apps/whoami/` to `apps/<slug>/`, adjust the four files, push, done.
Rules enforced by CI and the updater:

| Rule | Value |
| --- | --- |
| Architecture | `platform: linux/arm64` — x86 images rejected |
| Host ports | ≥ 1024, unique across apps |
| CPU | `cpus: 0.5` (hard max 2.0) |
| Memory | `mem_limit: 256m` (hard max 1g) |
| Logs | driver `k8s-file`, `max-size: "5m"`, `max-file: "2"` |
| Restart | `unless-stopped` |
| Secrets | gitignored `.env` only; commit `.env.example` |

## Repository layout

```
.github/ISSUE_TEMPLATE/new-app.yml     issue form for the AI generator
.github/workflows/ai-app-generator.yml issue → PR pipeline (free OpenRouter models)
.github/workflows/validate.yml         shellcheck + acceptance tests + smoke test
apps/whoami/                           demo app / reference template
bootstrap/install.sh                   one-line installer
bootstrap/updater.sh                   12h sync + healthcheck + rollback
bootstrap/podroid-gitops               OpenRC service (reconcile at boot)
bootstrap/homelab                      operator CLI
tests/acceptance_test.sh               the acceptance suite (also runs in CI)
```

## The demo app: whoami

`traefik/whoami:v1.10` (arm64) on host port **8080** — it echoes request
headers and the container's identity:

```sh
curl http://localhost:8080/
```

Change the reported name in `apps/whoami/.env` (`WHOAMI_NAME=...`).

## CI

- **validate** — on every push/PR: shellcheck on all scripts, acceptance
  tests (compose parses, arm64 pins, port/limit/log rules, no secrets
  committed), then a real `podman-compose up` smoke test of whoami.
- **AI app generator** — on `app-request` issues.

Repo secrets:

| Secret | Purpose |
| --- | --- |
| `OPENROUTER_API_KEY` | free-model app generation |

## Notes & constraints

- Targets only the Podroid VM: Alpine, aarch64, non-emulated ARM.
- No host ports below 1024.
- `podroid-forward` / `podroid-notify` are used when present, skipped cleanly
  when not.
- Rollbacks reset the repo to the last healthy commit; `.env` files are
  untracked so secrets survive every rollback.
