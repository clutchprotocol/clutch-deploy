# clutch-deploy

Docker Compose orchestration for the full Clutch Protocol stack. Workspace overview, architecture, and the ports table live in the parent `../CLAUDE.md` — this file covers deploy internals only.

## Compose files — which combination to use

| File | Role |
|------|------|
| `docker-compose.yml` | Base stack, pre-built GHCR images (`ghcr.io/clutchprotocol/*:latest`). Always the first `-f`. |
| `docker-compose.dev.yml` | Dev overlay: builds Rust services from sibling repos, runs frontends as Vite dev servers with hot reload. |
| `docker-compose.stage.cloudflare-flex.yml` | Stage/VPS overlay: `ports: !reset []` on every service (nothing published except via nginx); TLS at Cloudflare, HTTP origin. |
| `docker-compose.nginx.yml` | Optional local reverse proxy on :80. Separate project (`-p clutch-nginx`), joins external network `clutch-dev_clutch-network`. |
| `docker-compose.stage.nginx.yml` | Same idea for stage; joins `clutch-stage_clutch-network`, mounts `config/nginx/nginx.stage.cloudflare-flex.conf`. |

- **Dev**: `-p clutch-dev -f docker-compose.yml -f docker-compose.dev.yml` (project name matters — the nginx overlay references the network by that name).
- **Stage**: `-p clutch-stage -f docker-compose.yml -f docker-compose.stage.cloudflare-flex.yml` — never add a third overlay that publishes ports; compose merges port lists and breaks the isolation.
- Nginx overlays run as a **separate compose project** and require the app stack's network to exist first.

## Services (base compose)

| Service | Image / dev build context | Notes |
|---------|---------------------------|-------|
| `node1`..`node3` | `clutch-node` / `../clutch-node` | Validators. Each mounts `./config:/app/config:ro`, started with `--env nodeN` → reads `config/node/nodeN.toml`. WS-RPC 808N, P2P 400N, metrics 300N. node2/3 `depends_on: node1` (bootstrap peer `/dns4/node1/tcp/4001`). |
| `clutch-hub-api` | `clutch-hub-api` / `../clutch-hub-api` | :3000. `CLUTCH_NODE_WS_URL=ws://node1:8081/ws`, config at `config/api/default.toml` (faucet key, JWT, referrers). Healthcheck: `curl /health`. |
| `clutch-hub-demo-app` | GHCR nginx image / **dev: raw `node:20-alpine`** | :5173→80. Dev runs Vite from bind-mounted source (see below). |
| `clutch-explorer-backend` | `clutch-explorer-backend` / `../clutch-explorer/backend` | :8088 REST API. `APP_*` env overrides `config/explorer/default.toml`. Healthcheck on `/health`. |
| `clutch-explorer-indexer` | **same image as backend** | Entrypoint override `/usr/local/bin/indexer --env default`. Polls node every 4s (`APP_INDEXER_POLL_INTERVAL_MS`), writes to Postgres. |
| `clutch-explorer-postgres` | `postgres:16-alpine` | Not published. `pg_isready` healthcheck. Data in `clutch-explorer-postgres-data` volume. |
| `clutch-explorer-frontend` | GHCR / dev: `node:20-alpine` + Vite | :5174→80. |
| `prometheus` / `grafana` / `seq` | stock images | No dev overrides (declared `{}` in dev overlay). Grafana on non-default port 3030 via `GF_SERVER_HTTP_PORT`. |

`depends_on` is ordering-only (no `condition: service_healthy`) — services must tolerate node1/postgres not being ready yet.

## Dev overlay specifics (`docker-compose.dev.yml`)

- **node1 builds, node2/3 reuse**: only node1 has a `build:` (tag `clutch-node:dev`, `pull_policy: build`); node2/3 use `image: clutch-node:dev, pull_policy: never`. Three parallel builds of one tag fail — don't "fix" this by adding builds to node2/3.
- **Demo app**: no Dockerfile — plain `node:20-alpine` with `../clutch-hub-demo-app` mounted at `/app` and `../clutch-hub-sdk-js` at `/clutch-hub-sdk-js`. A long inline `sh -c` script retries `npm ci` (up to 5x) for both, then launches Vite via `node ./node_modules/vite/bin/vite.js` — deliberately not the `.bin/vite` shim, because Docker Desktop Windows bind mounts drop the execute bit. `node_modules` live in named volumes (not the bind mount). `CHOKIDAR_USEPOLLING=true` makes hot reload work on Windows mounts.
- **Explorer frontend**: same Vite-in-container pattern against `../clutch-explorer/frontend`.
- Explorer backend/indexer default to `APP_DEVELOPER_MODE=true`, `APP_CLEANUP_ON_START=true` (DB wiped on each start) in dev.
- Rust source changes need `--build` (or `docker compose build <svc>`) — only the frontends hot-reload.

## Env (`.env`, gitignored — copy from `.env.example`)

Compose fails if `.env` is missing (several services use `env_file: .env`). Keys: `SEQ_API_KEY`, `SEQ_ADMIN_USERNAME`/`SEQ_ADMIN_PASSWORD` (applied only on first run with an empty seq volume), `JWT_SECRET`, `ALLOWED_ORIGINS` (Hub API CORS — must include the demo origin), `EXPLORER_ALLOWED_ORIGINS`, `EXPLORER_POSTGRES_{DB,USER,PASSWORD}`, `EXPLORER_DEVELOPER_MODE`, `EXPLORER_CLEANUP_ON_START`. Optional for dev npm installs: `NPM_CONFIG_REGISTRY`, `HTTP(S)_PROXY`.

App-level config is TOML under `config/` (mounted read-only): `config/node/node{1,2,3}.toml` (validator keys, authority set — all three lists must match), `config/api/default.toml`, `config/explorer/default.toml`. `APP_*` env vars override the explorer/API TOML. The keys checked in here are throwaway test-net keys.

## Monitoring

- **Prometheus**: `config/monitoring/prometheus/prometheus.yml` scrapes `nodeN:300N/metrics` every 10s. Add scrape jobs there; `--web.enable-lifecycle` is on, so `curl -X POST localhost:9090/-/reload` applies without restart. 200h retention.
- **Grafana**: provisioning via `config/monitoring/grafana/{datasources.yml,dashboards.yml}`; dashboard JSON goes in `config/monitoring/grafana/dashboards/` (e.g. `clutch-node.json`) — picked up within 10s into the "Clutch Protocol" folder, no restart needed. Anonymous **viewer** access is enabled (read-only public dashboards); admin password comes from `GRAFANA_ADMIN_PASSWORD` (committed fallback in `docker-compose.yml`, override in `.env`).
- **Seq** (:5341→80): Rust services push structured logs; per-service ingestion API keys are set in the TOML configs / `SEQ_API_KEY`.

## Common operations (PowerShell, from this folder)

```powershell
# Full dev stack up / down
docker compose -p clutch-dev -f .\docker-compose.yml -f .\docker-compose.dev.yml up -d --build
docker compose -p clutch-dev -f .\docker-compose.yml -f .\docker-compose.dev.yml down

# Rebuild one service (e.g. after Rust changes)
docker compose -p clutch-dev -f .\docker-compose.yml -f .\docker-compose.dev.yml up -d --build clutch-hub-api

# Logs
docker compose -p clutch-dev -f .\docker-compose.yml -f .\docker-compose.dev.yml logs -f node1 clutch-explorer-indexer

# Nuke data (chain state, explorer DB, node_modules volumes, Grafana/Seq state)
docker compose -p clutch-dev -f .\docker-compose.yml -f .\docker-compose.dev.yml down -v
```

Always pass the full `-f` list and `-p` on every command — omitting them targets a different (empty) project.

## Stage deploy

`.github/workflows/deploy-stage.yml` SSHes to the VPS (secrets `STAGE_HOST/USER/SSH_PASSWORD/DEPLOY_PATH`), does `git pull`, `compose pull`, `up -d --force-recreate --remove-orphans` — **no `--build`**; stage consumes GHCR images published by each repo's CI. Triggers: manual, push to `main` touching compose/config files, or `repository_dispatch` type `deploy-stage` (sent by sibling repos after image publish). VPS bootstrap steps: `docs/SSH-SERVER-SETUP.md`.

## Gotchas

- **Sibling layout is load-bearing**: dev build contexts are `../clutch-node`, `../clutch-hub-api`, `../clutch-explorer/backend`; bind mounts reach `../clutch-hub-demo-app` and `../clutch-hub-sdk-js`. Cloning clutch-deploy alone breaks dev mode.
- SDK changes appear in the dev demo app via the bind mount, but the SDK's `node_modules` volume persists — if SDK deps change, `down -v` (or remove `clutch-hub-sdk-js-node-modules`) to force `npm ci`.
- Port 80 is only taken by the optional nginx overlay; 3000/3030/5173/5174/8081-8083/8088/9090/5341 must be free for the base stack.
- Seq first-run admin credentials only apply to a fresh `seq-data` volume; changing them later in `.env` has no effect.
- The stage overlay uses YAML `!reset` (Compose v2.24+) to unpublish ports — older docker compose versions error on it.
- `package-lock.json` at the repo root is an artifact; there is no npm project here.
