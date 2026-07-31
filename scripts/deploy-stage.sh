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
               TREASURY_APPROVER_TOKEN TREASURY_READONLY_TOKEN"
TREASURY_VAR_COUNT=6
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

  # Only now that the orchestrator is confirmed healthy: make sure nginx routes
  # /payment/ to it. Deliberately after the health gate — `nginx -t` resolves a
  # static proxy_pass host at config-load time, so running this against a
  # not-yet-started orchestrator fails the deploy for the wrong reason.
  #
  # In a script, NOT inline here. As an inline block with a multi-line single-quoted
  # awk program it failed twice with exit 1, no message, and no ERR trap firing — the
  # shell took neither branch of a plain `if`, which a working bash cannot do.
  # Something between YAML, the ssh-action and the remote shell was mangling it. One
  # `bash script.sh` has no such layers, and the script is testable locally.
  #
  # Invoked via `bash`, not by relying on the exec bit: `chmod +x` on a tracked file
  # shows up as a local modification and silently blocks `git pull --ff-only` on this
  # host, which once kept four fixes off the server for an hour.
  echo "[stub] ensure-nginx-route $NGINX_C"

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
    pcode=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
      -H "Host: app-stage.clutchprotocol.io" -H "Content-Type: application/json" \
      -d '{}' http://localhost/payment/api/v1/deposits || true)
    case "$pcode" in
      401|400|422) pok=1; echo "payment route reaches the orchestrator (HTTP $pcode)"; break ;;
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
fi
