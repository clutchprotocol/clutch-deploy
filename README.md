# Clutch Deploy

Docker Compose deployment for the Clutch Protocol full stack: **clutch-node** + **clutch-hub-api** + monitoring.

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
docker-compose up -d
```

## Services

| Service        | Ports  | Description                    |
|----------------|--------|--------------------------------|
| node1          | 8081, 4001, 3001 | Blockchain node 1 (bootstrap) |
| node2          | 8082, 4002, 3002 | Blockchain node 2             |
| node3          | 8083, 4003, 3003 | Blockchain node 3             |
| clutch-hub-api | 3000   | API bridge (GraphQL, REST)     |
| Seq            | 5341   | Structured logging             |

## Optional: Nginx Proxy

To run with Nginx as reverse proxy (port 80):

```bash
docker-compose --profile proxy up -d
```

## Configuration

- **Node config:** `config/node/node1.toml`
- **API config:** `config/api/default.toml`
- **Environment:** `.env` (from `.env.example`)

For multi-node or monitoring (Prometheus, Grafana), see [clutch-node](https://github.com/clutchprotocol/clutch-node) repository.

## Images

Uses pre-built images from:

- `ghcr.io/clutchprotocol/clutch-node:latest`
- `9194010019/clutch-hub-api:latest` (Docker Hub)

Each project builds and pushes its own image via CI. If clutch-hub-api is published to GHCR, update the image in `docker-compose.yml`.
