# Clutch Deploy

This folder contains Docker Compose configs for the Clutch Protocol stack:

- **Dev**: build/run from local source with hot reload (Vite dev server).
- **Stage**: deployed VPS behind **Cloudflare** — HTTPS at the edge, plain HTTP on the origin (`docker-compose.stage.cloudflare-flex.yml`).

## Prerequisites

- Docker Desktop (includes Docker Compose)
- A `.env` file in this folder (copy from `.env.example`)

## Run (dev)

Dev assumes you have these sibling repos next to `clutch-deploy/`:

- `../clutch-node`
- `../clutch-hub-api`
- `../clutch-hub-demo-app`
- `../clutch-hub-sdk-js`

Start dev (PowerShell):

```powershell
docker compose -p clutch-dev -f .\docker-compose.yml -f .\docker-compose.dev.yml up -d --build
```

Useful dev URLs:

- Demo app (Vite): `http://localhost:5173/`
- Hub API health: `http://localhost:3000/health`

Stop dev:

```powershell
docker compose -p clutch-dev -f .\docker-compose.yml -f .\docker-compose.dev.yml down
```

## Run (stage on VPS / Cloudflare)

Stage uses Nginx on the server on **port 80 only** (no TLS on the origin). Visitors use **HTTPS** via Cloudflare; Cloudflare reaches your VPS over **HTTP**.

**What this means:** Traffic is encrypted between visitors and Cloudflare. Between Cloudflare and your VPS it is **unencrypted HTTP** on port 80. That is acceptable for some staging setups; for production, consider **Full (strict)** with an origin certificate or tunnel so the last hop is also TLS.

**Cloudflare dashboard**

1. Point your DNS **A** records (e.g. `stageweb`, `stageapi`) at your server IP.
2. Under **SSL/TLS → Overview**, set encryption mode to **Flexible** when the origin only serves HTTP.
3. Allow inbound **TCP 80** on the VPS firewall (Cloudflare reaches the origin on HTTP).

**Docker Compose**

Use **only** `docker-compose.yml` together with `docker-compose.stage.cloudflare-flex.yml`. Do not add another compose overlay that also publishes node, API, or duplicate proxy ports — merges would combine port mappings and break isolation.

Start stage (PowerShell):

```powershell
docker compose -p clutch-stage -f docker-compose.yml -f docker-compose.stage.cloudflare-flex.yml pull
docker compose -p clutch-stage -f docker-compose.yml -f docker-compose.stage.cloudflare-flex.yml up -d --build --force-recreate
```

(`--build` rebuilds the demo app image; CI uses the same flags.)

Stop stage:

```powershell
docker compose -p clutch-stage -f docker-compose.yml -f docker-compose.stage.cloudflare-flex.yml down
```

Files:

- Overlay: `docker-compose.stage.cloudflare-flex.yml`
- Nginx: `config/nginx/nginx.stage.cloudflare-flex.conf` (edit `server_name` to match your hostnames)

Nginx sets `X-Forwarded-Proto https` so the app sees the public scheme correctly.

**Frontend / SDK:** The demo resolves the Hub API from the page hostname: **`stageweb.<domain>` → `https://stageapi.<domain>`** (GraphQL HTTP and `wss://…/graphql/ws` follow). The stage compose file also passes **`VITE_API_URL`** at image build time. Set **`ALLOWED_ORIGINS`** in `.env` to include your demo origin (e.g. `https://stageweb.clutchprotocol.io`) so the Hub API accepts browser requests.

## VPS setup over SSH

Step-by-step (Ubuntu Server): [docs/SSH-SERVER-SETUP.md](docs/SSH-SERVER-SETUP.md)

## Automated stage deploy (GitHub Actions)

Workflow: [`.github/workflows/deploy-stage.yml`](.github/workflows/deploy-stage.yml) runs **`git pull`** (if the deploy dir is a clone), **`docker compose pull`**, then **`up -d --build --force-recreate`** with the Cloudflare flex files.

### Repository secrets

Configure these in **GitHub → Settings → Secrets and variables → Actions**:

| Secret | Description |
|--------|-------------|
| `STAGE_HOST` | VPS hostname or IP |
| `STAGE_USER` | SSH user (e.g. `root` or `deploy`) |
| `STAGE_SSH_PASSWORD` | SSH password for that user (GitHub encrypt-at-rest). Using an **SSH key** is more secure if you can enable key-only login on the server. |
| `STAGE_DEPLOY_PATH` | Absolute path to this repo on the server (e.g. `/root/clutch-deploy`) |

If SSH is not on port 22, add `port: YOUR_PORT` under `with:` in the workflow (or use `~/.ssh/config` on a self-hosted runner).

### Server one-time setup

- Clone this repo on the VPS at `STAGE_DEPLOY_PATH` so `git pull` updates compose and config.
- Copy `.env` and ensure **`ALLOWED_ORIGINS`**, **`JWT_SECRET`**, etc. exist (not stored in Git).
- For **private** images on GHCR, run **`docker login ghcr.io`** once on the server (or use a read-only PAT).

### When it runs

- **Manual:** Actions → **Deploy stage (VPS)** → Run workflow.
- **On push to `main`:** when `docker-compose*.yml`, `config/**`, or this workflow file changes.
- **From another repo** (e.g. after an image publish): send a **`repository_dispatch`** with event type **`deploy-stage`**:

```bash
curl -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer YOUR_PAT_WITH_REPO_SCOPE" \
  https://api.github.com/repos/OWNER/clutch-deploy/dispatches \
  -d '{"event_type":"deploy-stage"}'
```

Or add a job in `clutch-hub-api` / `clutch-node` CI that calls [`repository_dispatch`](https://docs.github.com/en/rest/repos/repos#create-a-repository-dispatch-event) after `docker push` so stage updates whenever a new image is published.
