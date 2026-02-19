# Clutch Deploy

Docker Compose deployment for the Clutch Protocol full stack: **clutch-node** (blockchain) + **clutch-hub-api** (GraphQL bridge) + **monitoring** (Prometheus, Grafana, Seq).

## Prerequisites

- Docker & Docker Compose
- (Optional) GHCR login if using private images: `docker login ghcr.io`

## Quick Start

```bash
# Clone this repo
git clone https://github.com/clutchprotocol/clutch-deploy.git
cd clutch-deploy

# Copy env and customize
cp .env.example .env

# Start the stack
docker compose up -d
```

**Verify:**
- API health: http://localhost:3000/health
- Grafana: http://localhost:3030 (admin/admin)
- Seq logs: http://localhost:5341

## Services

| Service        | Ports           | URL / Description                    |
|----------------|-----------------|--------------------------------------|
| clutch-hub-api | 3000            | http://localhost:3000 (GraphQL, /health) |
| node1          | 8081, 4001, 3001| Bootstrap node (WebSocket, libp2p, metrics) |
| node2          | 8082, 4002, 3002| Blockchain node 2                    |
| node3          | 8083, 4003, 3003| Blockchain node 3                    |
| Prometheus     | 9090            | http://localhost:9090 (metrics)      |
| Grafana        | 3030            | http://localhost:3030 (admin/admin)  |
| Seq            | 5341            | http://localhost:5341 (logs)         |

## Optional: Nginx Proxy

Run with Nginx as reverse proxy on port 80:

```bash
docker compose --profile proxy up -d
```

## Configuration

| Path | Purpose |
|------|---------|
| `config/node/node1.toml`, `node2.toml`, `node3.toml` | Node settings, bootstrap peers |
| `config/api/default.toml` | API bind address, node WebSocket URL, Seq |
| `config/monitoring/prometheus/prometheus.yml` | Scrape targets |
| `config/monitoring/grafana/` | Datasources, dashboards |
| `config/nginx/nginx.conf` | Proxy config (when using `--profile proxy`) |
| `.env` | `SEQ_API_KEY`, `JWT_SECRET`, `ALLOWED_ORIGINS` (from `.env.example`) |

## Common Commands

```bash
# View logs
docker compose logs -f clutch-hub-api

# Restart API
docker compose restart clutch-hub-api

# Full reset (stops containers, removes volumes)
docker compose down -v
docker compose up -d
```

## Project Structure

```
clutch-deploy/
├── docker-compose.yml
├── .env.example
├── config/
│   ├── api/default.toml
│   ├── node/node1.toml, node2.toml, node3.toml
│   ├── nginx/nginx.conf
│   └── monitoring/
│       ├── prometheus/prometheus.yml
│       └── grafana/
│           ├── datasources.yml
│           ├── dashboards.yml
│           └── dashboards/clutch-node.json
└── README.md
```

## Images

| Image | Source |
|-------|--------|
| clutch-node | `ghcr.io/clutchprotocol/clutch-node:latest` |
| clutch-hub-api | `9194010019/clutch-hub-api:latest` (Docker Hub) |

Each project builds and pushes its own image via CI. To use a different registry, update `docker-compose.yml`.
