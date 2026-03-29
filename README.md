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
docker compose -p clutch-stage -f docker-compose.yml -f docker-compose.stage.cloudflare-flex.yml up -d --force-recreate
```

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
