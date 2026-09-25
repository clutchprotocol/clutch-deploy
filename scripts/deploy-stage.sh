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

# The treasury's limits and its GasFree settings must agree with each other before anything is pulled
# or recreated. A broken relationship fails quietly in production — a limit that refuses everything,
# one that protects nothing, or three services reading GasFree differently — so a deploy that would
# run one stops here, with the stack as it was.
if [ "$TREASURY" = "true" ] && ! bash scripts/check-cap-invariants.sh; then
  echo ""
  echo "DEPLOY ABORTED — check-cap-invariants.sh found a broken relationship (above). Nothing was changed."
  exit 1
fi

# Alertmanager's destination. Telegram needs a bot token AND a chat id, and only the token can be
# read from a file (`bot_token_file`) -- `chat_id` has to sit in the config itself. So the config is
# a TEMPLATE here and the rendered alertmanager.yml is gitignored, which keeps both values out of a
# public repository while the routing stays reviewable in git.
#
# Both are always written, even unset. A missing bind source makes Docker create a DIRECTORY at that
# path, after which Alertmanager fails to start for a reason that reads nothing like "nobody has
# chosen a destination yet". Placeholders fail visibly in Alertmanager's own log instead.
env_value() {
  grep -E "^$1=" .env 2>/dev/null | head -1 | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//' || true
}
ALERT_TELEGRAM_BOT_TOKEN="$(env_value ALERT_TELEGRAM_BOT_TOKEN)"
ALERT_TELEGRAM_CHAT_ID="$(env_value ALERT_TELEGRAM_CHAT_ID)"
mkdir -p config/monitoring/alertmanager

if [ -n "$ALERT_TELEGRAM_BOT_TOKEN" ] && [ -n "$ALERT_TELEGRAM_CHAT_ID" ]; then
  printf '%s' "$ALERT_TELEGRAM_BOT_TOKEN" > config/monitoring/alertmanager/telegram-token
  # A chat id is digits and an optional leading minus (groups are negative). Validated because it is
  # substituted into a config file, and because a malformed one makes Alertmanager refuse to start
  # -- which would take the alerting stack down over a typo.
  if ! printf '%s' "$ALERT_TELEGRAM_CHAT_ID" | grep -qE '^-?[0-9]+$'; then
    echo "DEPLOY ABORTED — ALERT_TELEGRAM_CHAT_ID is not a number: $ALERT_TELEGRAM_CHAT_ID"
    echo "  Telegram chat ids are digits, negative for groups. Nothing was changed."
    exit 1
  fi
  sed "s/__TELEGRAM_CHAT_ID__/$ALERT_TELEGRAM_CHAT_ID/"     config/monitoring/alertmanager/alertmanager.yml.tpl     > config/monitoring/alertmanager/alertmanager.yml
  echo "Alertmanager: Telegram destination configured from .env"
else
  printf '%s' 'placeholder-no-telegram-bot-token-configured' > config/monitoring/alertmanager/telegram-token
  # Delete the whole telegram block rather than rendering a placeholder chat_id into it. A
  # receiver with no integrations is valid and drops silently; a chat_id of 0 is refused by
  # Alertmanager's own config validation, which crash-loops the container and makes "nobody has
  # chosen a destination yet" look like an outage. Shipped that way once.
  sed '/__TELEGRAM_BEGIN__/,/__TELEGRAM_END__/d'     config/monitoring/alertmanager/alertmanager.yml.tpl     > config/monitoring/alertmanager/alertmanager.yml
  echo "Alertmanager: ALERT_TELEGRAM_BOT_TOKEN/CHAT_ID not set in .env — rules will fire and reach nobody."
  echo "  Readiness item D3 is not closed by having the rules. Set them, then force a failure to test."
fi
# The token file has to be readable BY ALERTMANAGER, which runs as nobody (65534) in the official
# image — not by whoever ran the deploy. Mode 600 owned by root is the obvious hardening and it
# makes the container fail with "permission denied" on every notification, which reads as a broken
# route rather than as a permissions mistake. Found exactly that way.
#
# chown keeps the file unreadable to other users on the host. It needs root, so a deploy running as
# anything else falls back to 644 and says what that costs: the token becomes readable by any local
# user, which at worst lets them post fake alerts to the one chat it can reach.
chmod 600 config/monitoring/alertmanager/telegram-token
if chown 65534:65534 config/monitoring/alertmanager/telegram-token 2>/dev/null; then
  :
else
  chmod 644 config/monitoring/alertmanager/telegram-token
  echo "Alertmanager: could not chown the token to uid 65534, fell back to mode 644."
  echo "  Any local user on this host can now read the bot token. Re-run the deploy as root to fix."
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
# tron-signer too: it refuses to start on an incomplete GasFree block, and sweeps and payouts stop while it is down.
if [ "$TREASURY" = "true" ]; then
  for svc in payment-orchestrator:8091 treasury-service:8090 tron-signer:8093; do
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

  # Every repo-owned vhost has to be proved AFTER the block is written. The health gate near the
  # top of this script ran before it, and a green gate there says nothing about the config the
  # reload has since installed.
  #
  # Retried for the same reason the payment gate is: `nginx -s reload` returns as soon as the
  # master has signalled, and the old workers keep serving the old config for a moment after.
  #
  # `ws` sends a real WebSocket handshake and wants 101. That check earns its place everywhere it
  # appears: drop `proxy_set_header Upgrade` and the request falls through to a `location /` that
  # has none, the handshake degrades to a plain 200, every page still loads, and every subscription
  # silently never fires.
  #
  # The fifth argument is a WebSocket subprotocol, and it is not decoration. The Hub API's
  # /graphql/ws answers 400 to a handshake that does not name `graphql-transport-ws`; the nodes'
  # /ws answers 101 without one. Measured both ways on 2026-09-13 after the first version of this
  # helper dropped the header and failed the deploy on a config that was in fact correct.
  edge_check() {
    local host="$1" path="$2" want="$3" mode="${4:-get}" proto="${5:-}" tries=15 code=""
    while [ "$tries" -gt 0 ]; do
      if [ "$mode" = "ws" ]; then
        # --max-time is load-bearing here. A successful upgrade leaves the socket open with nothing
        # to read, so an unbounded curl waits forever: the first run of this gate hung on node1 /ws
        # and took the whole deploy down with the ssh action's 10-minute command timeout -- after
        # the config had been written and reloaded, so the restore never ran either. curl still
        # reports 101 when --max-time cuts it off.
        code=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" -H "Host: $host" -H "Connection: Upgrade" -H "Upgrade: websocket" -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" ${proto:+-H "Sec-WebSocket-Protocol: $proto"} "http://localhost$path" || true)
      else
        # Bounded for the same reason, if not the same cause: a hung GET stops the deploy just as
        # dead as a hung handshake.
        code=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" -H "Host: $host" "http://localhost$path" || true)
      fi
      [ "$code" = "$want" ] && { echo "$host$path OK (HTTP $code)"; return 0; }
      echo "waiting for $host$path (got $code, want $want)..."
      sleep 2; tries=$((tries - 1))
    done
    echo "DEPLOY FAILED: $host$path returned $code, expected $want, after the managed block"
    return 1
  }

  # Restore and reload if any gate fails. `nginx -t` passing only means the config parses -- these
  # checks are the ones that can still find the edge broken, and by then it is already serving.
  # Reverting the repo change would NOT undo it: the hand-written locations were stripped in the
  # same pass that added the managed ones, so a later deploy without the route file leaves the
  # vhost with no routes at all. The backup the block script writes before every edit is the only
  # thing that puts the previous edge back.
  restore_nginx() {
    local conf
    conf=$(docker inspect "$NGINX_C"       --format '{{range .Mounts}}{{if eq .Destination "/etc/nginx/nginx.conf"}}{{.Source}}{{end}}{{end}}')
    if [ -n "$conf" ] && [ -f "$conf.clutch-block.bak" ]; then
      # cat, not mv: the container bind-mounts this path by inode.
      cat "$conf.clutch-block.bak" > "$conf"
      docker exec "$NGINX_C" nginx -s reload && echo "restored the previous nginx config and reloaded"
    else
      echo "NO BACKUP TO RESTORE at ${conf:-<unknown>}.clutch-block.bak — the edge is live as written"
    fi
  }

  # Let the deployment settle ONCE before any gate runs.
  #
  # edge_check retries for 30s, which is right for nginx finishing a reload and far too short for
  # a container that has just been recreated: clutch-stage-node3 holds ~20,000 blocks and takes
  # about two minutes to open its database. On 2026-09-19 a deploy failed on
  # node3-stage/metrics 502 while node3 was still starting, rolled the edge config back, and then
  # passed on a re-run minutes later with nothing changed.
  #
  # One wait here rather than a larger `tries` on all 27 checks: raising every one would multiply
  # the worst case past the ssh action's 10-minute command timeout -- which is the failure that
  # once left a config written and reloaded with the restore never running.
  #
  # Filtered on docker's own health state rather than a hardcoded container list, so it covers
  # whatever this deployment actually contains and cannot go stale when a service is added.
  wait_settled() {
    local deadline=$(( $(date +%s) + 240 )) starting unhealthy
    while [ "$(date +%s)" -lt "$deadline" ]; do
      starting=$(docker ps --filter "label=com.docker.compose.project=clutch-stage" --filter "health=starting"  --format '{{.Names}}' | tr '\n' ' ')
      unhealthy=$(docker ps --filter "label=com.docker.compose.project=clutch-stage" --filter "health=unhealthy" --format '{{.Names}}' | tr '\n' ' ')
      if [ -z "$starting$unhealthy" ]; then
        echo "deployment settled: nothing starting, nothing unhealthy"
        return 0
      fi
      echo "settling, still waiting for: ${starting}${unhealthy}"
      sleep 5
    done
    # Not fatal. The gates below have their own retry and their own restore, and they are a better
    # judge of whether the EDGE works than a container healthcheck is.
    echo "WARNING: after 240s still starting/unhealthy: ${starting}${unhealthy} — running the gates anyway"
    return 0
  }
  wait_settled

  # api-stage. A POST to /graphql is deliberately NOT checked: this vhost's `location /` proxies
  # everything to the same upstream with the path preserved, so losing the /graphql block entirely
  # would still answer correctly, and the typo it would catch `nginx -t` rejects at config load.
  edge_check api-stage.clutchprotocol.io /health     200 || { restore_nginx; exit 1; }
  edge_check api-stage.clutchprotocol.io /graphql/ws 101 ws graphql-transport-ws || { restore_nginx; exit 1; }

  # app-stage, the demo app's own vhost and the last one migrated. `location /` is the site itself,
  # so a failure here is not one broken path but the whole app -- which is why it has the most
  # gates and why it went last.
  edge_check app-stage.clutchprotocol.io /            200 || { restore_nginx; exit 1; }
  edge_check app-stage.clutchprotocol.io /health      200 || { restore_nginx; exit 1; }
  # /api/ strips its own prefix before proxying, so /api/health reaches the Hub API's /health.
  # That is the check worth having: it proves the rewrite survived, not merely the proxy_pass.
  edge_check app-stage.clutchprotocol.io /api/health  200 || { restore_nginx; exit 1; }
  edge_check app-stage.clutchprotocol.io /explorer/   200 || { restore_nginx; exit 1; }
  edge_check app-stage.clutchprotocol.io /graphql/ws  101 ws graphql-transport-ws || { restore_nginx; exit 1; }


  # --- MAINNET (chain_id 1000) -----------------------------------------------------------------
  #
  # These two vhosts shipped without gates, so a deploy could break them and still report success:
  # the checks above prove only the six -stage vhosts. A gate is not optional here for the same
  # reason it was not there -- the edge is already serving by the time these run.
  edge_check api.clutchprotocol.io /health     200 || { restore_nginx; exit 1; }
  edge_check api.clutchprotocol.io /graphql/ws 101 ws graphql-transport-ws || { restore_nginx; exit 1; }

  edge_check app.clutchprotocol.io /           200 || { restore_nginx; exit 1; }
  edge_check app.clutchprotocol.io /health     200 || { restore_nginx; exit 1; }
  # /api/ strips its own prefix, so /api/health must reach the mainnet Hub API's /health. Proves
  # the rewrite survived, not merely the proxy_pass.
  edge_check app.clutchprotocol.io /api/health 200 || { restore_nginx; exit 1; }
  edge_check app.clutchprotocol.io /graphql/ws 101 ws graphql-transport-ws || { restore_nginx; exit 1; }

  # The three routes that must FAIL, and must fail as 503 rather than 200.
  #
  # Not belt-and-braces. `location /` on this vhost is a catch-all serving the SPA's index.html
  # with a 200, so if any of these blocks is dropped the route does not disappear -- it starts
  # answering 200 with HTML. For /payment/ that is the dangerous one: the deposit panel would show
  # a real depositor an address watched by nothing, or by the TESTNET orchestrator if the stage
  # copy of the file were ever restored here. A gate that accepts "not 200" would pass on that.
  edge_check app.clutchprotocol.io /payment/health  503 || { restore_nginx; exit 1; }
  edge_check app.clutchprotocol.io /explorer/       503 || { restore_nginx; exit 1; }
  edge_check app.clutchprotocol.io /explorer/api/   503 || { restore_nginx; exit 1; }
  # explorer-stage. /health reaches the explorer's Rust API; / is the React frontend, and a 200
  # from it is what says the frontend upstream still resolves.
  edge_check explorer-stage.clutchprotocol.io /health 200 || { restore_nginx; exit 1; }
  edge_check explorer-stage.clutchprotocol.io /        200 || { restore_nginx; exit 1; }

  # The three nodes. /metrics is what Prometheus scrapes, /ws is what the Hub API reads the chain
  # over, and `location /` returning 404 is a route rather than an accident -- these hosts expose
  # two endpoints and nothing else, so a 404 there is the correct answer and worth asserting.
  for n in 1 2 3; do
    edge_check "node${n}-stage.clutchprotocol.io" /metrics 200 || { restore_nginx; exit 1; }
    edge_check "node${n}-stage.clutchprotocol.io" /ws      101 ws || { restore_nginx; exit 1; }
    edge_check "node${n}-stage.clutchprotocol.io" /        404 || { restore_nginx; exit 1; }
  done
fi
