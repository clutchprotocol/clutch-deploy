#!/usr/bin/env bash
#
# Deploy the stage stack. Run ON the VPS, from the clutch-deploy checkout.
#
# This used to be an 11 KB inline `script:` block in deploy-stage.yml. It failed three times in a
# row in ways that made no sense against the source: exit 1 with no message and no ERR trap
# firing, twice, and then
#
#   bash: -c: line 370: syntax error near unexpected token `;'
#
# on a script whose own `case` statement sits at line 202 and which passes `bash -n` cleanly. The
# string bash received was not the string in the workflow — the block had outgrown what survives
# the trip through YAML, the ssh-action and `bash -c`, and the failure point moved every time the
# text got longer. Chasing it as a logic bug produced two wrong fixes.
#
# As a file it is read from disk by a real bash: no length ceiling, no transport, accurate line
# numbers, `bash -n`-able, and runnable locally. Keep the inline part in the workflow tiny — cd,
# git pull, call this. Anything that grows belongs here.
#
# Env (all optional):
#   RESET_CHAIN=true   DESTRUCTIVE. `down -v`: wipes the chain, explorer DB, monitoring and the
#                      treasury and orchestrator databases. Only for a genesis change.
#
# Whether the treasury is deployed is derived from .env, never passed in; see the comment below.

set -euo pipefail
# -E so the ERR trap survives into functions, subshells and command substitutions;
# without it the trap is silently not inherited and you get the bare exit again.
set -E
# This script has now died twice with exit 1 and NO message — once mid-nginx-patch,
# once earlier — leaving nothing to debug but the last successful echo. `set -e` exits
# wherever it likes and says nothing about where. Report the line and the command,
# to stdout (a previous version of this trap wrote to stderr and the message never
# surfaced in the Actions log).
# shellcheck disable=SC2154  # rc is assigned by the trap body itself, at fire time.
trap 'rc=$?; echo "SCRIPT FAILED rc=$rc at line $LINENO: $BASH_COMMAND"; exit $rc' ERR

# Is the treasury part of this deployment? DERIVED from the host's own .env, not from
# a workflow input.
#
# Two reasons it can't be an input. `inputs` is only populated for workflow_dispatch —
# on `push` and on the repository_dispatch a sibling repo fires after publishing an
# image, every input is the empty string. That built a CORE-ONLY file list on those
# runs, and `up -d --remove-orphans` then removed treasury-service and
# payment-orchestrator as orphans, reporting success while doing it. And a manual toggle is state that drifts from reality.
#
# The secrets ARE the switch: the treasury cannot run without them, so their presence
# is the honest signal. Add them to .env to enable it, remove them to disable. Every
# trigger then behaves identically, with nothing to keep in sync.
TREASURY_VARS="TREASURY_POSTGRES_PASSWORD ORCHESTRATOR_POSTGRES_PASSWORD \
               MINT_AUTHORITY_SECRET TREASURY_INITIATOR_TOKEN \
               TREASURY_APPROVER_TOKEN TREASURY_READONLY_TOKEN \
               DEPOSIT_MNEMONIC DEPOSIT_ACCOUNT_XPUB SIGNER_TOKEN"
TREASURY_VAR_COUNT=9
present=0; missing=""
for v in $TREASURY_VARS; do
  if grep -qE "^${v}=.+" .env 2>/dev/null; then present=$((present+1)); else missing="$missing $v"; fi
done

TREASURY="false"
if [ "$present" -eq "$TREASURY_VAR_COUNT" ]; then
  TREASURY="true"
  echo "treasury: ENABLED (all $TREASURY_VAR_COUNT secrets present in .env)"
elif [ "$present" -gt 0 ]; then
  # Half-configured is a mistake, not an intention — refuse rather than quietly
  # deploying core-only and orphaning whatever treasury containers are running.
  echo "DEPLOY ABORTED — .env has $present of $TREASURY_VAR_COUNT treasury secrets. Missing:"
  for v in $missing; do echo "  - $v"; done
  echo ""
  echo "Nothing was changed. Add the rest to enable the treasury, or remove them all"
  echo "to deploy core-only."
  echo ""
  echo "MINT_AUTHORITY_SECRET must be a key generated FOR STAGE, never the"
  echo "publicly-committed node1 dev key used locally."
  echo ""
  echo "DEPOSIT_MNEMONIC and DEPOSIT_ACCOUNT_XPUB are two halves of ONE wallet and must match."
  echo "Read the xpub off the signer (GET /internal/xpub) rather than transcribing it: a mistyped"
  echo "xpub means every deposit address belongs to a wallet nothing can sweep, and the first"
  echo "symptom is a user paying into an address no key exists for."
  exit 1
else
  echo "treasury: disabled (no treasury secrets in .env) — deploying core stack only"
fi

# .env overrides the compose default, so fixing the default is not enough on a host that pins it.
#
# TXLAQ63Xg1NAzckPwKHvzw7CSEmLMEqcdj exists on Nile and reports symbol "USDT", which is why it was
# picked — but the nileex.io faucet dispenses a DIFFERENT token, so nobody can obtain it and no
# deposit can ever be funded. Worse, it fails silently: tron_verifier queries TronGrid filtered by
# contract_address, so a transfer of any other token is absent from the response rather than
# mismatched. The intent finds no evidence, stays Transient, and ages into manual review with
# nothing naming the cause.
#
# Abort rather than warn. A stage that looks deployed and cannot process a deposit is the exact
# failure shape that has cost the most time here.
if [ "$TREASURY" = "true" ] && grep -q '^USDT_CONTRACT=TXLAQ63Xg1NAzckPwKHvzw7CSEmLMEqcdj' .env 2>/dev/null; then
  echo "DEPLOY ABORTED — .env pins a retired USDT contract:"
  echo "    USDT_CONTRACT=TXLAQ63Xg1NAzckPwKHvzw7CSEmLMEqcdj"
  echo ""
  echo "Nothing was changed. Replace that line with the faucet-dispensed Nile token:"
  echo "    USDT_CONTRACT=TXYZopYRdj2D9XRtbG411XZZ3kM5VkAeBf"
  echo "(or delete the line and let docker-compose.treasury.yml's default apply)."
  echo ""
  exit 1
fi

# The stage overlay MUST stay last of the port-bearing files: compose MERGES port
# lists, and its `ports: !reset []` entries are what keep the orchestrator (8091) off
# this box's public interface.
FILES=(-f docker-compose.yml)
if [ "$TREASURY" = "true" ]; then
  FILES+=(-f docker-compose.treasury.yml)
fi
FILES+=(-f docker-compose.stage.cloudflare-flex.yml)
# The orchestrator's `ports: !reset []` lives in its own file because a service key carrying only
# a reset still DECLARES that service, which breaks a core-only deploy. Applied last so the reset
# wins the port-list merge. Without it, 8091 — the deposit API — is published on this VPS's public
# interface, when stage reaches it same-origin through nginx's /payment/ route.
if [ "$TREASURY" = "true" ]; then
  FILES+=(-f docker-compose.stage.treasury.yml)
fi
echo "Compose files: ${FILES[*]}"

# PULL BEFORE TEARDOWN. This ordering is the whole point.
#
# It used to be down -v first, and a missing image then destroyed stage and left it
# offline: the teardown succeeded, `pull` failed with "repository does not exist", and
# `script_stop` aborted before anything came back up. Pulling first means an image
# problem fails while the old stack is still serving.
docker compose -p clutch-stage "${FILES[@]}" pull

# Opt-in, never a default. A plain deploy must never destroy stage data; this exists
# for the one case that genuinely needs it — a genesis change, where the new ChainInit
# genesis cannot import onto the old chain and every node would refuse to start.
if [ "${RESET_CHAIN:-false}" = "true" ]; then
  echo "reset_chain=true — tearing down WITH VOLUMES (chain, explorer DB, monitoring, treasury DBs)"
  docker compose -p clutch-stage "${FILES[@]}" down -v --remove-orphans
fi

docker compose -p clutch-stage "${FILES[@]}" up -d --force-recreate --remove-orphans

# ---------------------------------------------------------------------------
# nginx on this host is NOT ours.
#
# The container named `nginx-stage` belongs to compose project `v2ray` and mounts
# /home/v2ray-docker/config/nginx/nginx.stage.cloudflare-flex.conf — a hand-maintained
# SUPERSET carrying the clutch vhosts alongside the v2ray ones (de2, de.wenda.ir, 3x,
# sub, de-grpc). It owns :80.
#
# So `docker compose -p clutch-nginx -f docker-compose.stage.nginx.yml up` can never
# work here: it fails to bind :80, and the repo's config/nginx/*.conf is never on the
# live path. A `/payment/` location sat in this repo for a full deploy cycle while the
# live nginx 405'd it as a static path, and the recreate attempt left a dead
# `<hash>_nginx-stage` husk behind. Don't reintroduce that compose call.
#
# Instead: patch the config that is actually mounted, idempotently, every deploy — so
# it self-heals if the v2ray side ever replaces the file.
NGINX_C=$(docker ps --format '{{.Names}}' | grep -x 'nginx-stage' || true)
if [ -z "$NGINX_C" ]; then
  echo "DEPLOY FAILED: no running container named nginx-stage — nothing is serving :80"
  exit 1
fi

# The /payment/ route is patched in LATER, after the orchestrator health gate — a
# static proxy_pass host is resolved when the config loads, so `nginx -t` fails if
# the orchestrator is not up yet.

# Reload regardless: --force-recreate gave every app container a new IP, and these
# upstreams are resolved once at load time, so without this nginx 502s the whole stack.
docker exec "$NGINX_C" nginx -s reload

# Clear the corpse left by the old compose-nginx approach, if it is still around.
# `|| true` on the grep is load-bearing under `set -o pipefail`: no husk means grep
# exits 1, the pipeline inherits it, and `set -e` kills an otherwise-successful deploy
# at the very last step.
HUSKS=$(docker ps -a --format '{{.Names}}' | grep -E '^[0-9a-f]+_nginx-stage$' || true)
for husk in $HUSKS; do
  echo "removing dead husk container $husk"
  docker rm -f "$husk" || true
done

# Health gate: fail the deploy loudly if the API is not reachable THROUGH nginx.
ok=""
for _ in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: api-stage.clutchprotocol.io" http://localhost/health || true)
  if [ "$code" = "200" ]; then ok=1; echo "api healthy via nginx"; break; fi
  echo "waiting for api (got $code)..."; sleep 2
done
[ -n "$ok" ] || { echo "DEPLOY FAILED: api not reachable through nginx"; exit 1; }

# When the treasury is part of this deployment, gate on it too. The check above only
# proves the hub API is up — an orchestrator that crash-loops on a bad config would
# otherwise leave the deploy reporting success.
#
# Checked from INSIDE the network on purpose: the orchestrator is deliberately not
# published on this host, so there is no host port to curl. treasury-service is
# checked the same way and is even stricter — it has no published port anywhere.
if [ "$TREASURY" = "true" ]; then
  for svc in payment-orchestrator:8091 treasury-service:8090; do
    name="${svc%%:*}"; port="${svc##*:}"
    tok=""
    for _ in $(seq 1 30); do
      if docker run --rm --network clutch-stage_clutch-network curlimages/curl:8.10.1 \
           -sf -m 5 "http://${name}:${port}/health" >/dev/null 2>&1; then
        tok=1; echo "${name} healthy"; break
      fi
      sleep 2
    done
    [ -n "$tok" ] || { echo "DEPLOY FAILED: ${name} not healthy"; docker logs "clutch-stage-${name}-1" 2>&1 | tail -30; exit 1; }
  done
  # Readiness item G1: the clutch vhost's config has an owner. The contents of
  # config/nginx/clutch.d/ are injected into the mounted file between markers, replacing whatever
  # sat there before.
  #
  # NOT an include. That was tried first and cannot work: the container bind-mounts exactly one
  # path, the single nginx.conf, so no host directory is visible inside it and the include loaded
  # nothing while still passing nginx -t. Adding a mount means editing another project's compose
  # file.
  #
  # /payment/ used to be patched in here by a separate ensure-nginx-payment-route.sh, which is now
  # retired: the route lives in config/nginx/clutch.d/payment.conf and the block script strips the
  # old inline copy on the first run that sees a replacement in the repo. Two mechanisms able to
  # write the same location is how you get a duplicate `location` and a config nginx refuses, so
  # there is deliberately only one.
  #
  # Runs after the orchestrator health gate for the same reason its predecessor did: a static
  # proxy_pass host resolves at config-load time, so nginx -t fails if the upstream is not up yet.
  bash scripts/ensure-nginx-clutch-block.sh "$NGINX_C"

  # Prove the browser-facing /payment/ route reaches the ORCHESTRATOR, not the static
  # site. Both previous checks passed while this was broken: the containers were
  # healthy and nginx answered — with 405 from the SPA's static location, because the
  # proxy rule was in a config file nothing mounted. "nginx is up" was never the
  # question; "does this path leave nginx" was.
  #
  # 401 is the PASS here. Unauthenticated POST reaching the orchestrator is exactly
  # what should happen; 405/404 means nginx handled it locally.
  #
  # Retried, not single-shot. `nginx -s reload` returns as soon as the master has signalled;
  # the OLD workers keep serving in-flight connections with the OLD config for a moment after.
  # A gate that fires immediately reads the pre-reload world and reports 405 for a route that
  # is in fact live — which is exactly what happened on run 30583006089, where the config was
  # confirmed patched and reloaded and the gate still failed.
  pok=""; pcode=""
  for _ in $(seq 1 15); do
    pbody=$(curl -s -w "HTTPCODE__%{http_code}" -X POST \
      -H "Host: app-stage.clutchprotocol.io" -H "Content-Type: application/json" \
      -d '{}' http://localhost/payment/api/v1/deposits || true)
    pcode="${pbody##*HTTPCODE__}"
    case "$pcode" in
      401|400|422) pok=1; echo "payment route reaches the orchestrator (HTTP $pcode)"; break ;;
      # The rollout gate: while APP_PERMANENT_DEPOSIT_ADDRESSES_ENABLED is false the orchestrator
      # itself answers 503 with a JSON body. nginx's own 503 for a missing upstream is HTML, so the
      # body is what tells "deliberately off" from "unreachable".
      503) case "$pbody" in
             *"temporarily unavailable"*) pok=1; echo "payment route reaches the orchestrator (HTTP 503: deposits gated off)"; break ;;
           esac ;;
    esac
    echo "waiting for the /payment/ route (got $pcode)..."
    sleep 2
  done
  if [ -z "$pok" ]; then
    echo "DEPLOY FAILED: /payment/ still returns $pcode after 30s"
    echo "405/404 means the request never left nginx — it matched the SPA's static location"
    echo "instead of the proxy rule. 502 means nginx proxied but the upstream is unreachable."
    echo "Live config around the route:"
    docker exec "$NGINX_C" grep -n -B2 -A8 'location /payment/' /etc/nginx/nginx.conf || \
      echo "  (no /payment/ block in the running container's config)"
    exit 1
  fi

  # api-stage's routes are repo-owned too, so they have to be proved AFTER the block is written.
  # The health gate near the top of this script ran before it -- a green gate there says nothing
  # about the config the reload has since installed.
  #
  # Two checks, and deliberately not three. A POST to /graphql proves less than it looks: this
  # vhost's `location /` proxies everything to the same upstream with the path preserved, so losing
  # the /graphql block entirely would still answer correctly. What it would catch, a typo'd
  # upstream name, `nginx -t` already rejects at config load.
  #
  #   /health      proves the vhost still proxies to the Hub API at all
  #   /graphql/ws  proves the upgrade headers survived. Drop `proxy_set_header Upgrade` and the
  #                request falls through to `location /`, which has none: the handshake degrades to
  #                a plain 200 instead of 101, every page still loads, and every subscription
  #                silently never fires. That is the one failure here worth a gate.
  #
  # Retried for the same reason the payment gate is: `nginx -s reload` returns as soon as the
  # master has signalled, and the old workers keep serving the old config for a moment after.
  api_check() {
    local what="$1" want="$2" tries=15 code=""
    while [ "$tries" -gt 0 ]; do
      case "$what" in
        health)  code=$(curl -s -o /dev/null -w "%{http_code}" \
                   -H "Host: api-stage.clutchprotocol.io" http://localhost/health || true) ;;
        ws)      code=$(curl -s -o /dev/null -w "%{http_code}" \
                   -H "Host: api-stage.clutchprotocol.io" \
                   -H "Connection: Upgrade" -H "Upgrade: websocket" \
                   -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
                   -H "Sec-WebSocket-Protocol: graphql-transport-ws" \
                   http://localhost/graphql/ws || true) ;;
      esac
      [ "$code" = "$want" ] && { echo "api-stage $what OK (HTTP $code)"; return 0; }
      echo "waiting for api-stage $what (got $code, want $want)..."
      sleep 2; tries=$((tries - 1))
    done
    echo "DEPLOY FAILED: api-stage $what returned $code, expected $want, after the managed block"
    return 1
  }
  api_check health 200 || exit 1
  api_check ws 101     || exit 1
fi
