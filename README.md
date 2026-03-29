# Clutch Deploy

This folder contains Docker Compose configs to run the Clutch Protocol stack in two modes:

- **Dev**: build/run from local source with hot reload (Vite dev server)
- **Stage**: run as a staged deployment behind Nginx using a stage domain

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
docker compose -p dev -f .\docker-compose.yml -f .\docker-compose.dev.yml down
```

## Run (stage)

Stage runs the stack with a reverse proxy that routes:

- `stageweb.clutchprotocol.io/` → demo web app
- `stageweb.clutchprotocol.io/api/*` and `/graphql` → hub API

Start stage (PowerShell):

```powershell
docker compose -p clutch-stage -f docker-compose.yml -f docker-compose.stage.yml pull
docker compose -p clutch-stage -f docker-compose.yml -f docker-compose.stage.yml up -d --force-recreate

```

Stop stage:

```powershell
docker compose -p stage -f .\docker-compose.yml -f .\docker-compose.stage.yml down
```

Stage Nginx config lives at:

- `config/nginx/nginx.stage.conf`

## Stage behind Cloudflare (HTTPS at edge, HTTP on VPS)

If you want the **browser** to use HTTPS while your **origin** only serves plain HTTP (no TLS certificates on the server), use Cloudflare SSL mode **Flexible** and the compose overlay below.

**What this means:** Traffic is encrypted between visitors and Cloudflare. Between Cloudflare and your VPS it is **unencrypted HTTP** on port 80. That is fine for some staging setups; for production, consider **Full (strict)** with an origin certificate or tunnel so the last hop is also TLS.

**Cloudflare dashboard**

1. Point your DNS **A** records (e.g. `stageweb`, `stageapi`) at your server IP.
2. Under **SSL/TLS → Overview**, set encryption mode to **Flexible**.
3. Allow inbound **TCP 80** on the VPS firewall (Cloudflare reaches the origin on HTTP).

**Docker Compose**

Use **only** this file **instead of** `docker-compose.stage.yml`. Do not pass both: Compose would merge port lists and you would still expose TLS or extra ports on the nodes.

```powershell
docker compose -p clutch-stage -f docker-compose.yml -f docker-compose.stage.cloudflare-flex.yml pull
docker compose -p clutch-stage -f docker-compose.yml -f docker-compose.stage.cloudflare-flex.yml up -d --force-recreate
```

Nginx listens on **80** only and sets `X-Forwarded-Proto https` so the app sees the public scheme correctly.

- Overlay: `docker-compose.stage.cloudflare-flex.yml`
- Nginx: `config/nginx/nginx.stage.cloudflare-flex.conf` (edit `server_name` to match your hostnames)

**Frontend / SDK:** Build the demo with API and GraphQL WebSocket URLs using your **public** `https://` (and `wss://`) hostnames behind Cloudflare, not raw VPS HTTP URLs.

## VPS setup over SSH

Step-by-step: [docs/SSH-SERVER-SETUP.md](docs/SSH-SERVER-SETUP.md)
