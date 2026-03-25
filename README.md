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
docker compose -p clutch-stage -f .\docker-compose.yml -f .\docker-compose.stage.yml up -d --force-recreate

```

Stop stage:

```powershell
docker compose -p stage -f .\docker-compose.yml -f .\docker-compose.stage.yml down
```

Stage Nginx config lives at:

- `config/nginx/nginx.stage.conf`
