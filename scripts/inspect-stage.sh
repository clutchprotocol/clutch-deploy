#!/usr/bin/env bash
#
# Read-only inspection of the stage VPS. Run ON the host, from the clutch-deploy checkout.
#
#   PROBE=nginx|containers|git|treasury|sweeper|bitcart bash scripts/inspect-stage.sh
#
# A file, not an inline `script:` block, for the same reason deploy-stage.sh is: as inline YAML
# this probe broke three times — once making the whole workflow unparseable (column-0 Python
# inside a literal block terminates the block scalar), and twice exiting 1 mid-output with no
# message. Every failure was invisible in the source and none was a logic error.
#
# Every command here is read-only: ps / inspect / logs / grep / ss / SELECT. Nothing starts,
# stops, or writes. Secrets are reported as <set> or used as credentials, never echoed.

set -uo pipefail

set -uo pipefail
PROBE="${PROBE:-nginx}"
# Default rather than fail: `inputs` is empty on any trigger that is not
# workflow_dispatch, and an empty probe silently matching nothing is worse than a
# useless-but-obvious default.
[ -n "$PROBE" ] || PROBE=nginx
echo "probe: $PROBE"

if [ "$PROBE" = "nginx" ]; then
  echo "=== containers with 'nginx' in the name ==="
  # .Labels is printed raw so an unexpected compose project shows up rather than
  # being normalised away by a --filter.
  docker ps -a --format '{{.ID}}  {{.Names}}  {{.Image}}  {{.Status}}  {{.Ports}}' \
    | grep -i nginx || echo "(none)"

  echo ""
  echo "=== compose ownership + config mounts of the live nginx ==="
  for c in $(docker ps -a --format '{{.Names}}' | grep -i nginx || true); do
    echo "--- $c"
    echo "    project: $(docker inspect "$c" --format '{{index .Config.Labels "com.docker.compose.project"}}' 2>/dev/null || echo '?')"
    echo "    service: $(docker inspect "$c" --format '{{index .Config.Labels "com.docker.compose.service"}}' 2>/dev/null || echo '?')"
    echo "    mounts:"
    docker inspect "$c" --format '{{range .Mounts}}      {{.Source}} -> {{.Destination}} ({{.Type}}){{"\n"}}{{end}}' 2>/dev/null || true
    echo "    networks: $(docker inspect "$c" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>/dev/null || true)"
  done

  echo ""
  echo "=== live nginx.conf: size, server_names, locations ==="
  # From INSIDE the container: whatever is actually being served, regardless of
  # which host path it came from or whether the inode still matches.
  LIVE=$(docker ps --format '{{.Names}}' | grep -i nginx | head -1 || true)
  if [ -n "$LIVE" ]; then
    echo "live container: $LIVE"
    echo "lines: $(docker exec "$LIVE" wc -l < /etc/nginx/nginx.conf 2>/dev/null || echo '?')"
    echo "--- server_name / listen ---"
    docker exec "$LIVE" grep -nE '^[[:space:]]*(server_name|listen)' /etc/nginx/nginx.conf 2>/dev/null || true
    echo "--- location blocks ---"
    docker exec "$LIVE" grep -nE '^[[:space:]]*location' /etc/nginx/nginx.conf 2>/dev/null || true
    echo "--- does it already route /payment/ ? ---"
    docker exec "$LIVE" grep -n 'payment' /etc/nginx/nginx.conf 2>/dev/null || echo "(no /payment/ route in the LIVE config)"
  else
    echo "no running nginx container"
  fi

  echo ""
  echo "=== who holds :80 / :443 on the host ==="
  ss -lntp 2>/dev/null | grep -E ':80 |:443 ' || echo "(ss unavailable or nothing bound)"
fi

if [ "$PROBE" = "containers" ]; then
  echo "=== all containers by compose project ==="
  docker ps -a --format '{{.Names}}\t{{.Status}}\t{{.Image}}' || true
  echo ""
  echo "=== compose projects present ==="
  docker ps -a --format '{{.Label "com.docker.compose.project"}}' | sort -u || true
  echo ""
  echo "=== disk ==="
  df -h / | tail -2 || true
  docker system df || true
fi

if [ "$PROBE" = "treasury" ]; then
  # An explicit allow-list of NON-SECRET keys. Never `docker inspect ... .Config.Env`
  # or `env` wholesale here: that environment also carries MINT_AUTHORITY_SECRET, the
  # four-eyes tokens, BITCART_TOKEN and both Postgres passwords, and this log is
  # readable by anyone with repo access.
  echo "=== treasury / orchestrator settings (non-secret keys only) ==="
  for c in treasury-service payment-orchestrator; do
    echo "--- clutch-stage-${c}-1"
    for k in APP_TRONGRID_URL APP_CUSTODY_TRON_ADDRESS APP_USDT_CONTRACT \
             APP_REDEMPTIONS_ENABLED APP_MIN_DEPOSIT_USDT APP_MAX_DEPOSIT_USDT \
             APP_DEPOSIT_TTL_MINUTES APP_DEPOSIT_MATCH_WINDOW_HOURS \
             APP_BITCART_URL APP_INVOICE_CURRENCY; do
      v=$(docker exec "clutch-stage-${c}-1" printenv "$k" 2>/dev/null || true)
      if [ -n "$v" ]; then echo "    $k=$v"; fi
    done
    # Presence, never the value.
    #
    # Tested for CONTENT, not exit status. Compose writes `APP_X=${X:-}` for optional settings, so
    # an unset X still defines APP_X as empty and `printenv` exits 0 -- which reported an unkeyed
    # TronGrid as `<set>` on this very probe. The distinction matters most for exactly that key:
    # unkeyed TronGrid throttles hard, and a throttled watcher is indistinguishable from "nobody
    # paid".
    for k in APP_TRONGRID_API_KEY APP_BITCART_TOKEN APP_MINT_AUTHORITY_SECRET; do
      v=$(docker exec "clutch-stage-${c}-1" printenv "$k" 2>/dev/null || true)
      if [ -n "$v" ]; then
        echo "    $k=<set, ${#v} chars>"
      elif docker exec "clutch-stage-${c}-1" printenv "$k" >/dev/null 2>&1; then
        echo "    $k=<EMPTY -- defined but not configured>"
      fi
    done
  done

  echo ""
  echo "=== deposit intents so far ==="
  docker exec clutch-stage-orchestrator-postgres-1 psql -U orchestrator -d orchestrator \
    -c "select status, count(*) from deposit_intents group by status order by 2 desc;" 2>/dev/null \
    || echo "(could not query orchestrator db -- container down, or the user/db names changed)"

  # The TRX float. A derived deposit address holds no TRX -- receiving tokens does not create a
  # balance -- so it cannot pay for its own sweep. tron-signer funds it from the wallet's fee
  # account at <account>/1/0, and that account is the one thing here an operator must top up by
  # hand. An empty one stalls every sweep, which shows up as a growing set of unswept addresses
  # rather than as an error.
  echo ""
  echo "=== TRX float (fee account) ==="
  # The token is expanded INSIDE the container and never printed. The response is public material:
  # an account xpub and an address. Both are safe in a log that repo access can read.
  FEE_JSON=$(docker exec clutch-stage-tron-signer-1 sh -c \
    'curl -fsS -H "Authorization: Bearer $APP_SIGNER_TOKEN" http://localhost:8093/internal/xpub' \
    2>/dev/null || true)
  FEE_ADDR=$(printf '%s' "$FEE_JSON" | sed -n 's/.*"fee_address"[ ]*:[ ]*"\([^"]*\)".*/\1/p')
  if [ -z "$FEE_ADDR" ]; then
    echo "    (could not read fee_address from tron-signer -- is the service up?)"
  else
    echo "    fee_address=$FEE_ADDR"
    # Queried from inside the signer, using the network the signer itself talks to, so this reads
    # the same chain the sweeps run against rather than whichever one the host would reach.
    BAL_JSON=$(docker exec clutch-stage-tron-signer-1 sh -c \
      "curl -fsS \"\$APP_TRONGRID_URL/v1/accounts/$FEE_ADDR\"" 2>/dev/null || true)
    BAL=$(printf '%s' "$BAL_JSON" | sed -n 's/.*"balance"[ ]*:[ ]*\([0-9]*\).*/\1/p' | head -1)
    if [ -z "$BAL" ]; then
      echo "    balance=0 sun (no account on chain yet -- never funded)"
      echo "    ACTION: send TRX to the address above, or no deposit can ever be swept."
    else
      echo "    balance=$BAL sun ($((BAL / 1000000)) TRX)"
      # 31 TRX is one funding transfer plus its own bandwidth reserve; under that, the next sweep
      # reports fee_account_dry and stops the pass.
      if [ "$BAL" -lt 31000000 ]; then
        echo "    ACTION: below one sweep's worth (31 TRX). Top up, or sweeps stall."
      fi
    fi
  fi
fi

if [ "$PROBE" = "sweeper" ]; then
  # Tailing this service is useless: clutch_chain::node_client logs a get_chain_info request AND
  # its response at INFO every 2 seconds (the outbox poll), so `docker logs --tail 30` is thirty
  # lines of the same poll and nothing else. Grep for what actually matters instead.
  echo "=== sweeper / signer activity (filtered out of the 2s chain poll) ==="
  docker logs --tail 4000 clutch-stage-treasury-service-1 2>&1 \
    | grep -aiE "sweep|swept|funded|fee_account|signer|alert" \
    | tail -25 \
    || echo "(no sweeper lines in the last 4000 log lines)"

  echo ""
  echo "=== is the worker alive at all? (its first pass logs on startup) ==="
  # A count, not a sample: zero here means the worker never ran, which is invisible in a tail.
  N=$(docker logs clutch-stage-treasury-service-1 2>&1 | grep -aciE "sweeper" || true)
  echo "    lines mentioning the sweeper since container start: ${N:-0}"

  echo ""
  echo "=== addresses waiting to be swept ==="
  # deposit_address IS NOT NULL skips discriminator-era rows, which have no address to sweep.
  docker exec clutch-stage-treasury-postgres-1 psql -U treasury -d treasury \
    -c "select status, count(*), min(created_at)::date as oldest
        from mint_intents
        where deposit_address is not null and swept_at is null
        group by status order by 2 desc;" 2>/dev/null \
    || echo "(could not query treasury db)"

  echo ""
  echo "=== already swept ==="
  docker exec clutch-stage-treasury-postgres-1 psql -U treasury -d treasury \
    -c "select count(*) as swept, max(swept_at) as most_recent from mint_intents where swept_at is not null;" 2>/dev/null \
    || echo "(could not query treasury db)"

  echo ""
  echo "=== open alerts ==="
  docker exec clutch-stage-treasury-postgres-1 psql -U treasury -d treasury \
    -c "select severity, source, left(message, 90) as message, created_at
        from alerts order by created_at desc limit 10;" 2>/dev/null \
    || echo "(could not query treasury db)"
fi

if [ "$PROBE" = "bitcart" ]; then
  echo "=== bitcart containers ==="
  docker ps -a --format '{{.Names}}\t{{.Status}}' | grep bitcart || echo "(none)"

  echo ""
  echo "=== bitcart-trx daemon log (does it see the custody address / sync at all?) ==="
  docker logs --tail 60 clutch-stage-bitcart-trx-1 2>&1 | tail -60 || true

  echo ""
  echo "=== bitcart-worker log (invoice/payment processing) ==="
  docker logs --tail 40 clutch-stage-bitcart-worker-1 2>&1 | tail -40 || true

  echo ""
  echo "=== orchestrator log (webhook + poller) ==="
  docker logs --tail 40 clutch-stage-payment-orchestrator-1 2>&1 | tail -40 || true

  echo ""
  echo "=== treasury-service log (verifier) ==="
  docker logs --tail 30 clutch-stage-treasury-service-1 2>&1 | tail -30 || true

  echo ""
  echo "=== is a TronGrid API key wired to the trx daemon? (unkeyed TronGrid rate-limits hard) ==="
  KEYSET=$(docker exec clutch-stage-bitcart-trx-1 printenv TRX_TRONGRID_API_KEY 2>/dev/null || true)
  if [ -n "$KEYSET" ]; then
    echo "  TRX_TRONGRID_API_KEY=<set>"
  else
    echo "  TRX_TRONGRID_API_KEY EMPTY — TronGrid throttles unkeyed clients, which looks"
    echo "  exactly like a daemon that is not scanning"
  fi

  echo ""
  echo "=== deposit intents ==="
  # -U orchestrator, not postgres: POSTGRES_USER is 'orchestrator' (see
  # docker-compose.treasury.yml), and the wrong user just prints "could not query".
  docker exec clutch-stage-orchestrator-postgres-1 psql -U orchestrator -d orchestrator \
    -c "select left(id::text,8) id, status, pay_amount_usdt, left(coalesce(tron_tx_id,'-'),12) tx, payment_window_closed pwc from deposit_intents order by created_at desc limit 10;" 2>&1 | tail -14 \
    || echo "(could not query orchestrator db -- container down, or the user/db names changed)"

  echo ""
  echo "=== recent alerts (the unattributed-payment reporter writes here) ==="
  docker exec clutch-stage-orchestrator-postgres-1 psql -U orchestrator -d orchestrator     -c "select severity, source, left(message,100) message from alerts order by created_at desc limit 8;" 2>&1 | tail -12     || echo "(could not query alerts)"
fi

if [ "$PROBE" = "git" ]; then
  echo "=== checkout state (a dirty tree blocks git pull --ff-only, silently) ==="
  git status --porcelain || true
  echo "--- HEAD ---"
  git log --oneline -3 || true
  echo "--- fileMode setting ---"
  git config core.fileMode || echo "(unset)"
fi

if [ "$PROBE" = "bitcart-daemon" ]; then
  echo "=== bitcart TRX daemon: which chain, and is it syncing? ==="
  for k in TRX_SERVER TRX_NETWORK TRX_HOST TRX_PORT; do
    v=$(docker exec clutch-stage-bitcart-trx-1 printenv "$k" 2>/dev/null || true)
    if [ -n "$v" ]; then echo "  $k=$v"; fi
  done
  KEY=$(docker exec clutch-stage-bitcart-trx-1 printenv TRX_TRONGRID_API_KEY 2>/dev/null || true)
  if [ -n "$KEY" ]; then echo "  TRX_TRONGRID_API_KEY=<set>"; else
    echo "  TRX_TRONGRID_API_KEY EMPTY — unkeyed TronGrid throttles, which looks identical to a"
    echo "  daemon that is not scanning"
  fi

  # The daemon speaks JSON-RPC on 5009 behind basic auth. `getinfo` reports its synced height:
  # if that is 0 or far behind Nile's head, nothing is being scanned and no address would ever
  # match, regardless of what is registered.
  LOGIN=$(docker exec clutch-stage-bitcart-trx-1 printenv LOGIN 2>/dev/null || echo electrum)
  PASSWORD=$(docker exec clutch-stage-bitcart-trx-1 printenv PASSWORD 2>/dev/null || echo electrumz)
  echo "  --- getinfo ---"
  docker run --rm --network clutch-stage_clutch-network curlimages/curl:8.10.1     -s -m 20 -u "$LOGIN:$PASSWORD" -H 'content-type: application/json'     -d '{"id":1,"method":"getinfo","params":[]}' http://bitcart-trx:5009 2>&1 | head -c 700
  echo ""
  echo "  --- which addresses is it watching? ---"
  docker run --rm --network clutch-stage_clutch-network curlimages/curl:8.10.1     -s -m 20 -u "$LOGIN:$PASSWORD" -H 'content-type: application/json'     -d '{"id":1,"method":"listaddresses","params":[]}' http://bitcart-trx:5009 2>&1 | head -c 700
  echo ""
  echo "  --- Nile head, for comparison ---"
  docker run --rm curlimages/curl:8.10.1 -s -m 20 -X POST     https://nile.trongrid.io/wallet/getnowblock 2>/dev/null     | head -c 300
  echo ""
fi

# Always succeed. This is a read-only probe whose OUTPUT is the deliverable — a trailing non-zero
# from the last grep/test would fail the step and throw away everything printed above it, which is
# exactly how two earlier runs "failed" while having already answered the question.
exit 0
