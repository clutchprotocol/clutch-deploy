# clutch-deploy

Docker Compose orchestration for the full Clutch Protocol stack. Workspace overview, architecture, and the ports table live in the parent `../CLAUDE.md` — this file covers deploy internals only.

## Compose files — which combination to use

| File | Role |
|------|------|
| `docker-compose.yml` | Base stack, pre-built GHCR images, each pinned to an exact tag (see "Image tags" below). Always the first `-f`. |
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
| `clutch-hub-api` | `clutch-hub-api` / `../clutch-hub/services/hub-api` | :3000. `CLUTCH_NODE_WS_URL=ws://node3:8083/ws` (node1 and node2 fell behind; being the p2p bootstrap says nothing about which node is best to read), config at `config/api/default.toml` (JWT, referrers). Healthcheck: `curl /health`. |
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
- **Demo app**: no Dockerfile — plain `node:20-alpine` with `../clutch-hub` mounted **whole** at `/workspace`, working dir `/workspace/apps/demo`. A long inline `sh -c` script retries `npm ci` (up to 5x) once at the workspace root, builds the SDK, then launches Vite via `node /workspace/node_modules/vite/bin/vite.js` — deliberately not the `.bin/vite` shim, because Docker Desktop Windows bind mounts drop the execute bit. `node_modules` live in named volumes (not the bind mount), one per workspace plus the hoisted root. `CHOKIDAR_USEPOLLING=true` makes hot reload work on Windows mounts.
  - **`../clutch-hub-demo-app` no longer exists.** The demo app and the SDK were merged into one npm workspace in `clutch-hub-sdk-js` on 2026-09-18 (`apps/demo` and `packages/sdk`); that repo is `clutch-hub` since 2026-09-24, and the Hub API joined it as `services/hub-api`. That is why there is one mount, one lockfile and one `npm ci` where there used to be two of each.
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

`.github/workflows/deploy-stage.yml` SSHes to the VPS (secrets `STAGE_HOST/USER/SSH_PASSWORD/DEPLOY_PATH`), does `git pull --ff-only origin main`, `compose pull`, `up -d --force-recreate --remove-orphans` — **no `--build`**; stage consumes GHCR images published by each repo's CI, at the tags pinned in the compose files. Triggers: manual, push to `main` touching compose/config files, or `repository_dispatch` type `deploy-stage` (sent by sibling repos after image publish — `clutch-hub`'s `docker-publish.yml` for the `apps/demo` image and `hub-api-image.yml` for the Hub API, `clutch-node`'s and `clutch-explorer`'s image workflows). VPS bootstrap steps: `docs/SSH-SERVER-SETUP.md`.

### Image tags: pinned, never `latest`

**A deploy ships exactly the tags in the compose files, and nothing newer** (#103, 2026-09-25). Before that every deploy pulled the newest `latest` of every image, so a deploy for one repo's change also shipped whatever any other repo had built since: that day a demo-app deploy would have rolled out the GasFree treasury images (treasury #53), which nobody had decided to ship, and Prometheus had moved to v3.15.0 that morning without anyone choosing it.

- **Where the pins live.** Clutch images use the `sha-<7>` tag their own CI already pushes. Stage: `docker-compose.yml` + `docker-compose.treasury.yml`. Mainnet: `docker-compose.mainnet.yml` + `docker-compose.mainnet.treasury.yml` (the mainnet treasury file pins its 3 images itself, so a stage treasury pin never moves mainnet). The stage overlays set no Clutch image: an overlay's `image:` silently wins the merge. Monitoring images carry exact versions and move by a reviewed edit.
- **`scripts/set-image.sh`** is the one way a Clutch tag moves. `set-image.sh stage clutch-node` prints a pin; `set-image.sh stage clutch-node=sha-xxxxxxx ...` moves pins after checking every pair (a known image, already pinned there, a `sha-<7>` tag, and ghcr.io has it); `PUSH=1` also commits and pushes to main (CI only). `scripts/test-set-image.sh` (workflow `test-set-image.yml`) tests it and fails any PR that brings `latest` or an untagged image back.
- **Stage moves by itself for the node, the Hub API, the demo app and the explorer.** Each image workflow's dispatch carries `client_payload.set_images`; the `pin` job commits it to main, then the `deploy` job runs. Only `deploy` is in the `deploy-stage` concurrency group: GitHub keeps one pending run per group and cancels the older pending one, which would drop a pin if the whole workflow were in it. A replaced pending deploy loses nothing, because its pin is already on main.
- **The treasury moves only by hand.** Its CI sends no dispatch, on purpose. Run "Deploy stage (VPS)" with `set_images` = `clutch-treasury=sha-… clutch-orchestrator=sha-… clutch-tron-signer=sha-…`.
- **Mainnet moves only through `mainnet-app-up.yml`.** With `promote` (the default) it copies stage's Hub API and demo pins into the mainnet file and commits them, so only what stage already runs can reach mainnet. It runs `up -d --no-deps`, and fails if a validator's image or start time changed. The validators stay on `sha-c3e301f`, the build they have run since 2026-09-19, until a planned upgrade.
- **Rollback** is a revert of the pin commit: a push to main touching compose files deploys it.
- A rebuild of the same commit can point a sha tag at a new digest (the Hub API's `sha-21a26a3` did on 2026-09-25). The code is the same.

**`origin main` on that pull is load-bearing, and a failed pull now fails the deploy.** A bare
`git pull --ff-only` resolves `FETCH_HEAD` against every branch it just fetched, so pushing two
feature branches was enough to stop the host updating with `fatal: Cannot fast-forward to multiple
branches`. That failure used to be swallowed by `|| echo "... continuing"`, and the deploy went on
to recreate containers from whatever the host already had and report success — for a stack whose
deploy also rewrites the edge nginx config and restarts the services that mint. Readiness item G4.
Every workflow here names the refspec now; `PROBE=git` reports branch, upstream and commits behind
`origin/main`, none of which it used to.

**Not every sibling repo sends that dispatch — `clutch-treasury` does not.** Its
`docker-build-push.yml` only builds and pushes the three GHCR images; there is no
`repository_dispatch` step and no `gh api` call anywhere in it. Confirmed by merging to `main`
and waiting for a deploy that never came. A treasury image publish needs a deploy triggered
separately here: a push to this repo's `main` touching compose/config files, or a manual
`deploy-stage` dispatch. Don't assume image-publish-implies-deploy without checking the
publishing repo's own workflow first.

**nginx on the stage VPS is not ours — but every clutch route in it is.** The `nginx-stage` container there belongs to the **`v2ray`** compose project and mounts `/home/v2ray-docker/config/nginx/nginx.stage.cloudflare-flex.conf` — a hand-maintained superset serving the clutch vhosts alongside v2ray's (`de2`, `de.wenda.ir`, `3x`, `sub`, `de-grpc`). It owns :80, so `docker-compose.stage.nginx.yml` cannot run there, and **editing `config/nginx/*.conf` in this repo still does nothing on that host** — that path is mounted nowhere and always was.

What does reach the host, injected between markers by `scripts/ensure-nginx-clutch-block.sh` on every deploy (readiness item G1, closed 2026-09-13):

| Directory | Holds | Lands |
|---|---|---|
| `config/nginx/clutch.d/<vhost>/*.conf` | `location` blocks, one subdirectory per vhost | inside that vhost's `server` block |
| `config/nginx/clutch.http/*.conf` | `upstream`, `limit_req_zone`, `geo`, `map`, `log_format` | just after `http {` |
| `config/nginx/clutch.shared/*.conf` | snippets every clutch vhost needs | copied into **each** clutch vhost, ahead of its own files |

All six clutch vhosts and all four upstreams are repo-owned. Everything outside the markers is v2ray's and is never touched.

**Things that will bite you here, each learned the expensive way:**

- **Not an include.** Tried and shipped first; it cannot work. The container bind-mounts exactly ONE path, the single `nginx.conf`, so no host directory is visible inside it. A glob matching nothing is valid nginx, so it passed `nginx -t`, reloaded cleanly, and loaded nothing.
- **A route file cannot declare an `upstream`** — `location` belongs to `server`, `upstream` to `http`. That is why `clutch.http/` exists as a separate injection point.
- **Adopting a route deletes the hand-written copy in the same pass**, scoped to that one server block. nginx refuses a duplicate `location`, so a half-done takeover serves nothing rather than the old route. A comment directly above an adopted location goes with it.
- **`$server_name` in a `log_format` is a variable, not a declaration.** The vhost guard masks it; unmasked it reads as a vhost and refuses a correct config.
- **A `grep` matching nothing exits 1**, and under `set -euo pipefail` in a command substitution that kills the script between two log lines with no message. Three separate places in that script needed `|| true`. Suspect it first when a deploy dies silently.
- The local `v2ray-docker` checkout has none of this and always drifts. Read the host, never either copy.

Guards, in order: the `server_name` set must be unchanged, no upstream may disappear, `nginx -t`, then reload — with a restore from backup on failure. Then 18 post-reload gates across all six vhosts (`/health`, real WebSocket handshakes expecting 101, the nodes' `location /` expecting 404), any of which restores the previous config and fails the deploy. `scripts/test-nginx-clutch-block.sh` covers the block script against a fixture shaped like the host's config; CI runs it on any PR touching those paths.

`.github/workflows/inspect-stage.yml` is a read-only probe for exactly this class of question — what is actually running and what is actually mounted. Reach for it before assuming the repo describes the host. Probes: `nginx`, `containers`, `git`, `treasury`, `sweeper`, `mainnet-treasury`, `chain`, `metrics`, `balance`, `energy`, `bitcart`, `bitcart-daemon`.

The `nginx` probe also takes `vhost=` — a comma-separated list, restricted to `*.clutchprotocol.io` because that run log is public and the same file serves v2ray's vhosts — and dumps each whole `server` block. It reports the nginx version, every upstream name with clutch bodies, both kinds of managed block, and what the edge rate limiter would have refused.

**Read node heights from `chain`, and trust nothing else.** Two earlier ways of getting that number were wrong in ways that misdirected an investigation: grepping node logs returns the block numbers a node is SERVING to a syncing peer (node3 appeared to fall from 117,573 to 17,463 while it was feeding node1), and the JSON-RPC ports speak WebSocket only, so curling them returns nothing at all. The probe scrapes `latest_block_index` from the Prometheus endpoint on 3001-3003.

Three write workflows exist alongside it, each requiring a typed confirmation:
`provision-treasury-secrets.yml` (fills missing `.env` values, never overwrites),
`resume-minting.yml` (clears the breaker, refuses while reconciliation is still a mismatch), and
`mint-intent-create.yml` / `mint-intent-approve.yml` (the four-eyes manual mint, deliberately two dispatches so one run cannot be both roles).

## The mainnet treasury

`docker-compose.mainnet.treasury.yml` is a complete file, not an overlay on `docker-compose.treasury.yml`. It is for compose project `clutch-main-treasury`, and its env file is `.env.mainnet` (gitignored, on the host only; `.env.mainnet.example` is the template).

Its app services have `mainnet-` names (`mainnet-treasury-service`, `mainnet-tron-signer`, `mainnet-payment-orchestrator`) **on purpose**. Compose adds a service's name as an alias on every network the service joins. A second `treasury-service` or `payment-orchestrator` on a network that Prometheus or nginx share would answer next to the stage one. Then requests, scrapes and the orchestrator's calls to its treasury would reach either stack.

`scripts/check-mainnet-compose.sh` checks that the copy has not drifted from the stage file. CI runs it (`check-monitoring-config.yml`), and it fails on: a service name shared with stage, a published port, a stage network, a stage setting missing from the mainnet services, a stage host in a mainnet URL, an image that is not pinned to a `sha-<7>` tag, and a value that is not the mainnet one (the chain id, the KMS signer, the mainnet nodes, TronGrid and USDT contract).

- **Only the pilot's accounts can use it.** No port is published. `/payment/` on `app.clutchprotocol.io` proxies to `mainnet-payment-orchestrator:8091` (`config/nginx/clutch.d/app.clutchprotocol.io/payment.conf`; the stage copy names `payment-orchestrator`, and the two must never be swapped), and the orchestrator serves only the accounts in `PILOT_ALLOWED_ADDRESSES`. Redemptions are on (`APP_REDEMPTIONS_ENABLED=true`, since 2026-10-05), but the treasury refuses to create one (503, before anything is burned) until the GasFree float has made its first transfer, so withdrawals begin when `activate-float.yml` has run for mainnet. Only `mainnet-payment-orchestrator` joins the stage network (nginx lives there; `mainnet-hub-api` does the same), under a name no stage service has, and `check-mainnet-compose.sh` refuses any other service there and refuses the orchestrator without its pilot allowlist. The deploy gate for the route is `edge_check app.clutchprotocol.io /payment/api/v1/deposits 401`.
- **The pilot allowlist.** `PILOT_ALLOWED_ADDRESSES` in `.env.mainnet` is REQUIRED (the start refuses without it): 0x addresses, comma-separated, or `*` for everyone. The orchestrator answers 403 to any other account (after the signature, before anything is created) and treats a blank list as nobody. It is written by `set-pilot-allowlist.yml` from the repository secret of the same name, because run inputs and logs are public. An orchestrator image from before the allowlist ignores the setting silently, so it logs one line at start, `pilot allowlist: on, N address(es)` or `off`, and the start ends by checking it; `PROBE=mainnet-treasury` prints it too.
- **One switch for the operator tools: `CHAIN=stage|mainnet`** (`scripts/lib/chain.sh`). `halt-minting.yml`, `resume-minting.yml`, `set-mint-caps.yml`, `activate-float.yml`, `mint-intent-create.yml`, `mint-intent-approve.yml`, `redrive-mint.yml`, `reverse-mint.yml` and `close-repaid-deposit.yml` have a `chain` choice (default stage) and ask for `<word> mainnet` on mainnet. The mint tools cut a user's address in their output on mainnet (`chain_mask`, `chain_mask_sql` in `chain.sh`), because their run logs are public; `mint-intent-create`'s beneficiary is an input, which is public on the run page whatever the script does. `mint-intent-approve` takes an intent in `needs_manual` too: that is where a deposit over the per-transaction mint cap is parked, and the way out is "Set mint caps" (raise), "Approve mint intent", then "Set mint caps" (put back). `set-gasfree-settings.yml` has a `network` choice. `backup-treasury-db.yml` backs up both chains. `ENV_FILE` does the same for `check-cap-invariants.sh`. Still stage-only: `fund-float` (the TRX rail's fee account; GasFree needs none) and the restore rehearsal. `sweep-address` is stage-only on purpose: its run log prints the address you type.
- **Start it with the workflow "Mainnet — start the treasury"** (confirm `START MAINNET TREASURY`). It runs `scripts/mainnet-treasury-up.sh`, which starts nothing until every check has passed. The steps, in order:
  - The preflight (`scripts/lib/mainnet-preflight.sh`) prints OK or FAIL for each check. It names settings and line numbers, never values. It refuses:
    - a `.env.mainnet` that its group or other users can read (`chmod 600`);
    - a line that is none of these: blank, a `#` comment (with the `#` in column 1), or a plain `NAME=value` with an upper-case name; and a name that is set twice. A plain value has no quote at the start, no `$`, no backtick, no space followed by `#`, no blank at either end and no carriage return;
    - a missing `BACKUP_PASSPHRASE`, or any other required setting that is empty;
    - a `GASFREE_NETWORK` that is set to anything but `mainnet` (an unset one passes);
    - a `TRONGRID_URL` that is not the mainnet TronGrid, or a `USDT_CONTRACT` that is not the mainnet one;
    - a secret, token, password, custody address, float address, backup passphrase or backup remote that equals the stage one (the mnemonic is compared by its words);
    - a `JWT_SECRET` that is not `.env`'s `MAINNET_JWT_SECRET`;
    - a plaintext mint key.
  - `check-cap-invariants.sh` on `.env.mainnet` (`ENV_FILE=.env.mainnet`). `ENV_FILE` must name a file that exists.
  - The network `clutch-mainnet` exists and `mainnet-node3` runs.
  - The compose file renders. Compose's own message is not printed, because it can quote a line of the env file.
  - Then it pulls only the three app images, never Postgres: `postgres:16-alpine` is a floating tag, and a pull that moved it would make the next `up -d` recreate both databases. A stage deploy can move it, so a later start can still recreate them.
  - Then it starts the five services and waits for each to be healthy. It prints no service log, because the run log is public. An unhealthy service gets the command `docker logs --tail 50 <container>`, to run on the host.
  - It never runs `down` and never takes `-v`. Never run `down -v` against `clutch-main-treasury`: its two databases are in its volumes.
- **`PROBE=mainnet-treasury`** shows what runs, its ports and networks, whether every service name resolves to one address, its settings (secrets as presence only), the breaker, reconciliation, alerts, mint intents, redemptions and the GasFree float. The run log is public, so it prints no address and no identifier of a user: alert texts are masked.
- `set-gasfree-settings.yml` (network mainnet, confirm `gasfree mainnet`) writes the GasFree block and the limits (17 values) into `.env.mainnet`. The payout side and the mint caps are the pilot's until the KMS payout key (readiness A2) ships: a $100 float target, $50 for both the redemption maximum and the signer's per-transaction cap, a $200 rolling 24-hour payout ceiling (readiness B4's decided set has $1,000, $200 and $1,000), and mint caps of $100 per deposit and $200 per day (decided: $1,000 and $2,000). Mainnet has been open to every account since 2026-10-05 (`PILOT_ALLOWED_ADDRESSES=*`), so what is credited in a day cannot outgrow what can be paid out. The relay's key pair is put there by hand, as plain lines: the script refuses if either is missing, blank or quoted.
- **`test-treasury-scripts.yml` parses every workflow file with Ruby** (the step "Workflow files parse", `ruby -ryaml`). A YAML mistake in a workflow is otherwise found only after the merge, when someone dispatches it.

## Gotchas

- **Sibling layout is load-bearing**: dev build contexts are `../clutch-node`, `../clutch-hub/services/hub-api`, `../clutch-explorer/backend`; the demo app's bind mount reaches `../clutch-hub` (the whole workspace — the app is `apps/demo` inside it). Cloning clutch-deploy alone breaks dev mode.
- SDK changes appear in the dev demo app via the bind mount, and the container rebuilds the SDK on every start. But the `node_modules` volumes persist and `npm ci` is skipped when they look populated — if **dependencies** change, `down -v` (or remove `clutch-hub-node-modules`) to force a reinstall.
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

### The TRX float needs a manual top-up (the TRX rail only)

**With `TRANSFER_RAIL=gasfree` none of this applies.** That is the rail mainnet runs, and stage since
2026-09-26. A GasFree account is swept by a relay permit whose fee is held back from the USDT, and
redemptions are paid from the GasFree float, so the fee account is not used and needs no TRX. The
stage test of 2026-10-02 spent zero TRX. The fee account is touched only to sweep a plain address
that holds USDT. Do not ask the maintainer to fund `fee_address` on that rail: there is no TRX budget,
and the GasFree rail exists so that none is needed. What the float needs there is USDT, once, in
custody: its one-time activation costs about 3.00 USDT (`activate-float.yml` wants a surplus of at
least 4.00).

After a deposit is credited on the TRX rail, `treasury-service`'s sweeper moves the USDT from the derived address to
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
