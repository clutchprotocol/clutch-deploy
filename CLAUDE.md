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
| `node1`..`node3` | `clutch-node` / `../clutch-node` | Validators. Each mounts `./config:/app/config:ro` **and `nodeN-data:/app/data`** with `DB_PATH=/app/data`, started with `--env nodeN` → reads `config/node/nodeN.toml`. WS-RPC 808N, P2P 400N, metrics 300N. node2/3 `depends_on: node1` (bootstrap peer `/dns4/node1/tcp/4001`). |
| `clutch-hub-api` | `clutch-hub-api` / `../clutch-hub-api` | :3000. `CLUTCH_NODE_WS_URL=ws://node3:8083/ws` (node1 and node2 fell behind; being the p2p bootstrap says nothing about which node is best to read), config at `config/api/default.toml` (faucet key, JWT, referrers). Healthcheck: `curl /health`. |
| `clutch-hub-demo-app` | GHCR nginx image / **dev: raw `node:20-alpine`** | :5173→80. Dev runs Vite from bind-mounted source (see below). |
| `clutch-explorer-backend` | `clutch-explorer-backend` / `../clutch-explorer/backend` | :8088 REST API. `APP_*` env overrides `config/explorer/default.toml`. Healthcheck on `/health`. |
| `clutch-explorer-indexer` | **same image as backend** | Entrypoint override `/usr/local/bin/indexer --env default`. Polls node every 4s (`APP_INDEXER_POLL_INTERVAL_MS`), writes to Postgres. |
| `clutch-explorer-postgres` | `postgres:16-alpine` | Not published. `pg_isready` healthcheck. Data in `clutch-explorer-postgres-data` volume. |
| `clutch-explorer-frontend` | GHCR / dev: `node:20-alpine` + Vite | :5174→80. |
| `prometheus` / `grafana` / `seq` | stock images | No dev overrides (declared `{}` in dev overlay). Grafana on non-default port 3030 via `GF_SERVER_HTTP_PORT`. |

`depends_on` is ordering-only (no `condition: service_healthy`) — services must tolerate node1/postgres not being ready yet.

**Chain state was destroyed on every deploy, for TWO separate reasons.** Both are fixed; the first one was fixed months before the second was even found, which is why "the volume fix" appeared not to work.

1. **No volume.** The node's DB path is `{DB_PATH or cwd}/{blockchain_name}.db`; with no `DB_PATH` that is the container's writable layer, so `up -d --force-recreate` discarded the chain. Fixed with `DB_PATH=/app/data` and per-node volumes. `/app/data` must be created **in clutch-node's Dockerfile owned by `clutch`**, because Docker creates a mount path absent from the image as root-owned and the node runs as uid 999.

2. **`developer_mode = true`, which makes the node delete its own database on shutdown** (`blockchain.rs` `shutdown_blockchain` → `cleanup_db` → `delete_database`). All three stage configs had it. Every deploy erased the chain of whichever node completed its graceful stop inside the 30s grace period; the ones SIGKILLed first kept theirs, so the loss moved between nodes and looked like anything but a config flag. Observed: node3 went 44M/height 117573 → 15M → 212K/height 100 across restarts while node1 and node2 sat at 24554.

The second one cost a long investigation that blamed the volumes, then resyncing, then the deploy script — the volumes were intact from 2026-07-31 throughout and nothing in the deploy path ever removed them. **`developer_mode` must stay false anywhere the chain matters.** clutch-node now also refuses to delete when `DB_PATH` is set, so the flag cannot silently erase a mounted volume.

For a redeemable token this class of bug means minted CLT vanishing while the backing USDT stays at custody — and downstream it is why the treasury read a supply frozen near genesis, judged its reserve against it, and submitted mints into it. `reset_chain` now means something too: a plain deploy no longer resets the chain, so `down -v` is the only thing that does.

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

# Rebuild one service (e.g. after Rust changes) — add --no-deps so --build does not
# also rebuild that service's dependencies.
docker compose -p clutch-dev -f .\docker-compose.yml -f .\docker-compose.dev.yml up -d --build --no-deps clutch-hub-api

# Restart a frontend (demo app / explorer frontend). NEVER pass --build here: these
# services have no Dockerfile, and --build without --no-deps walks depends_on and
# rebuilds clutch-hub-api + clutch-node from source instead.
docker compose -p clutch-dev -f .\docker-compose.yml -f .\docker-compose.dev.yml up -d --no-deps --force-recreate clutch-hub-demo-app

# Logs
docker compose -p clutch-dev -f .\docker-compose.yml -f .\docker-compose.dev.yml logs -f node1 clutch-explorer-indexer

# Nuke data (chain state, explorer DB, node_modules volumes, Grafana/Seq state)
docker compose -p clutch-dev -f .\docker-compose.yml -f .\docker-compose.dev.yml down -v
```

Always pass the full `-f` list and `-p` on every command — omitting them targets a different (empty) project.

## Stage deploy

`.github/workflows/deploy-stage.yml` SSHes to the VPS (secrets `STAGE_HOST/USER/SSH_PASSWORD/DEPLOY_PATH`), does `git pull`, `compose pull`, `up -d --force-recreate --remove-orphans` — **no `--build`**; stage consumes GHCR images published by each repo's CI. Triggers: manual, push to `main` touching compose/config files, or `repository_dispatch` type `deploy-stage` (sent by sibling repos after image publish — e.g. `clutch-hub-demo-app`'s `docker-publish.yml` does this in its `trigger-stage-deploy` job). VPS bootstrap steps: `docs/SSH-SERVER-SETUP.md`.

**Not every sibling repo sends that dispatch — `clutch-treasury` does not.** Its
`docker-build-push.yml` only builds and pushes the three GHCR images; there is no
`repository_dispatch` step and no `gh api` call anywhere in it. Confirmed by merging to `main`
and waiting for a deploy that never came. A treasury image publish needs a deploy triggered
separately here: a push to this repo's `main` touching compose/config files, or a manual
`deploy-stage` dispatch. Don't assume image-publish-implies-deploy without checking the
publishing repo's own workflow first.

**nginx on the stage VPS is not ours.** The `nginx-stage` container there belongs to the **`v2ray`** compose project and mounts `/home/v2ray-docker/config/nginx/nginx.stage.cloudflare-flex.conf` — a hand-maintained superset serving the clutch vhosts alongside v2ray's (`de2`, `de.wenda.ir`, `3x`, `sub`, `de-grpc`). It owns :80, so `docker-compose.stage.nginx.yml` cannot run there, and **editing `config/nginx/*.conf` in this repo does nothing on that host**. A `/payment/` route was added here, deployed, verified present on the server, and still 405'd for a full cycle before anyone checked which file was mounted. `deploy-stage.yml` now patches the mounted config in place each deploy (idempotent, `nginx -t` with rollback) and gates on `/payment/` returning 401 rather than 405.

`.github/workflows/inspect-stage.yml` is a read-only probe for exactly this class of question — what is actually running and what is actually mounted. Reach for it before assuming the repo describes the host. Probes: `nginx`, `containers`, `git`, `treasury`, `sweeper`, `chain`, `bitcart`.

**Read node heights from `chain`, and trust nothing else.** Two earlier ways of getting that number were wrong in ways that misdirected an investigation: grepping node logs returns the block numbers a node is SERVING to a syncing peer (node3 appeared to fall from 117,573 to 17,463 while it was feeding node1), and the JSON-RPC ports speak WebSocket only, so curling them returns nothing at all. The probe scrapes `latest_block_index` from the Prometheus endpoint on 3001-3003.

Three write workflows exist alongside it, each requiring a typed confirmation:
`provision-treasury-secrets.yml` (fills missing `.env` values, never overwrites),
`resume-minting.yml` (clears the breaker, refuses while reconciliation is still a mismatch), and
`mint-intent-create.yml` / `mint-intent-approve.yml` (the four-eyes manual mint, deliberately two dispatches so one run cannot be both roles).

## Gotchas

- **Sibling layout is load-bearing**: dev build contexts are `../clutch-node`, `../clutch-hub-api`, `../clutch-explorer/backend`; bind mounts reach `../clutch-hub-demo-app` and `../clutch-hub-sdk-js`. Cloning clutch-deploy alone breaks dev mode.
- SDK changes appear in the dev demo app via the bind mount, but the SDK's `node_modules` volume persists — if SDK deps change, `down -v` (or remove `clutch-hub-sdk-js-node-modules`) to force `npm ci`.
- Port 80 is only taken by the optional nginx overlay; 3000/3030/5173/5174/8081-8083/8088/9090/5341 must be free for the base stack.
- Seq first-run admin credentials only apply to a fresh `seq-data` volume; changing them later in `.env` has no effect.
- The stage overlay uses YAML `!reset` (Compose v2.24+) to unpublish ports — older docker compose versions error on it.
- `package-lock.json` at the repo root is an artifact; there is no npm project here.
- **`tron-signer`'s SWEEP API takes an INDEX and nothing else** — the destination is its own
  config. Do not add a `to`, `contract`, or `amount` parameter there: each one individually
  deletes the reason that endpoint exists, and owning the orchestrator must never move a deposit.
  **The PAYOUT endpoint (`/internal/payout`) is the deliberate exception** and does take `to` and
  `amount`, because a redemption has no other way to express them. Its bound is different, not
  absent: it can only spend from the payout float at `2/0` — never a deposit address, never
  custody — so the float balance caps the loss, and a per-tx cap bounds one request. Unlike sweep,
  its safety DOES depend on the bearer token and the internal-only network. `contract` is still
  never a parameter. See
  `clutch-treasury/docs/superpowers/specs/2026-08-30-redemption-payout-rail-design.md`.

## Deposit detection (no Bitcart)

**Every user gets one permanent TRON address**, derived once from the account xpub at
`m/44'/195'/0'/0/i` and stored against their `user_pk` — not one per deposit intent.
`payment-orchestrator` holds only the account **xpub** — enough to derive addresses, not to spend
from them — and polls each address for USDT `Transfer` events by DESTINATION
(`crates/payment-orchestrator/src/custody.rs`, `poller.rs`). Polling is tiered: opening the deposit
panel marks that user's address hot for `deposit_hot_window_hours`; everyone else rotates through a
bounded per-pass budget, oldest-polled-first, so cost stays flat as the address set grows
(`due_addresses`). Any amount paid in is credited in full, and each on-chain transfer is stored as
its own row keyed by `tron_tx_id` — so repeated top-ups to the same address all count, not just the
first.

The mnemonic lives only in `tron-signer`, which is why the amount discriminator, slot allocation and
amount-based matching are all gone: identity is the address plus the transaction, not a promised
amount. `POST /api/v1/deposits` takes no body — the beneficiary is always the caller's authenticated
identity (the JWT `pk`, address form); a public-key-form token is refused with 400, and there is
deliberately no `clt_address` field to "add back".

Addresses derived before this change are not abandoned: a separate, shrinking loop keeps watching
each still-open legacy per-intent address until its window closes, but a second payment to one of
those *after* its intent has already settled goes uncredited — users must pay whatever address the
deposit panel currently shows them.

Bitcart was removed from this path. Its TRX daemon attributes a payment by the **sender's** address
(`tx.from_addr in request_addresses`, populated only by `set_request_address`), so a request is
detectable only once the payer's Tron address is registered against it in advance — unreconcilable
with payers who are anonymous until they pay. Per-invoice addresses are not available for Tron there
either (`TRX_ACCOUNT_PATH` is a fixed single-address derivation path). Verified by running the daemon
in isolation against Nile: synced, correct balance, `new_block` events past the relevant block, zero
payment events.

Gone with it: `docker-compose.bitcart.yml`, `provision-bitcart-stage.yml`,
`scripts/provision-bitcart.sh`, the `webhook_events` table, the unauthenticated `/webhooks/bitcart`
route, and `BITCART_TOKEN`/`BITCART_STORE_ID` (now inert if still present in `.env`).

### The TRX float needs a manual top-up

After a deposit is credited, `treasury-service`'s sweeper moves the USDT from the derived address to
the main treasury. A TRC-20 transfer costs energy, and **a freshly derived address holds no TRX** —
receiving tokens does not create a balance — so it cannot pay for its own sweep.

`tron-signer` funds it first, from the wallet's own fee account at `<account>/1/0`. A different
change level from deposit addresses (`0/i`) deliberately: nothing at `1/0` can ever collide with an
address a depositor was told to pay into. No extra key material and no second mnemonic — which is
why funding needs **no new env var**.

That account is the one thing in this stack an operator must top up by hand. Empty, every sweep
answers `fee_account_dry` and the pass stops; deposits are still credited and the reserve total is
still correct (`get_reserve_balance` sums custody, every DISTINCT unswept deposit address, and the
payout float), but nothing consolidates. Find the address and its balance with:

```
PROBE=treasury  →  "=== TRX float (fee account) ==="
```

via `.github/workflows/inspect-stage.yml`, or read `fee_address` off the signer's `/internal/xpub`.
Funding is two-pass by design: the TRX transfer has to confirm before the sweep can spend it, so an
address reports `funded` on one pass and is swept on a later one.

`docker-compose.stage.treasury.yml` survives even though it now resets a single port: a service key
carrying only `ports: !reset []` still declares that service, which breaks a core-only deploy — and
without it the deposit API is published on the VPS's public interface.
