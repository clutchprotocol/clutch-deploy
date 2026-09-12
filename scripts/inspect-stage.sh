#!/usr/bin/env bash
#
# Read-only inspection of the stage VPS. Run ON the host, from the clutch-deploy checkout.
#
#   PROBE=nginx|containers|git|treasury|sweeper|chain|metrics|bitcart|energy bash scripts/inspect-stage.sh
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

    # Readiness item G1. The clutch-owned routes are injected between markers by
    # scripts/ensure-nginx-clutch-block.sh, and markers are comments -- so the server_name and
    # location greps above cannot show them, and "the block is live" was unanswerable without this.
    # The whole /payment/ block, not just the lines containing the word: before moving a live
    # money route into the repo, what is on the host has to be read rather than assumed to match
    # whatever generated it. grep -A rather than awk brace-counting -- an awk program has to
    # survive YAML, the ssh-action and a remote shell, and the brace-counting version silently
    # matched nothing.
    echo "--- live /payment/ block (12 lines of context) ---"
    docker exec "$LIVE" grep -n -A 12 'location /payment/' /etc/nginx/nginx.conf 2>/dev/null       || echo "(no /payment/ block)"

    echo "--- clutch-deploy managed block (G1) ---"
    if docker exec "$LIVE" grep -q 'clutch-deploy managed block' /etc/nginx/nginx.conf 2>/dev/null; then
      docker exec "$LIVE" sed -n '/>>> clutch-deploy managed block/,/<<< clutch-deploy managed block/p' \
        /etc/nginx/nginx.conf 2>/dev/null || true
    else
      echo "(no managed block in the LIVE config — routes are still hand-maintained)"
    fi

    # An include pointing into the container's own filesystem loads nothing and passes nginx -t,
    # so it is invisible unless asked for by name. One was shipped and removed on 2026-09-13.
    echo "--- stale clutch.d include (should be absent) ---"
    docker exec "$LIVE" grep -n 'include .*clutch\.d' /etc/nginx/nginx.conf 2>/dev/null \
      || echo "(none — correct; that include could never have loaded anything)"
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
  # Unkeyed TronGrid throttles, and a throttled watcher looks exactly like "nobody paid" -- the
  # failure this stack is most likely to misread. Nothing surfaced it before, so the API-key
  # question could only be argued from theory.
  echo "=== TronGrid throttling actually observed? ==="
  HITS=$(docker logs --since 24h clutch-stage-payment-orchestrator-1 2>&1     | grep -aciE "429|rate.?limit|too many request" || true)
  echo "    ${HITS:-0} throttle-shaped lines in the last 24h of orchestrator logs"
  if [ "${HITS:-0}" != "0" ]; then
    docker logs --since 24h clutch-stage-payment-orchestrator-1 2>&1       | grep -aiE "429|rate.?limit|too many request" | tail -5 | sed 's/^/    /'
    echo "    -> an API key is no longer optional; deposits may be going unseen."
  else
    echo "    -> unkeyed polling is coping at current volume. A key is headroom, not a live fault."
  fi
  echo ""

  echo "=== treasury / orchestrator settings (non-secret keys only) ==="
  # tron-signer is in this list for its payout cap alone. That cap and the orchestrator's
  # max_redemption_clt are enforced in different services and can silently disagree -- and a
  # redemption the orchestrator accepts but the signer refuses is CLT already burned that no
  # retry can ever pay. Show them side by side so a mismatch is visible without reading two repos.
  for c in treasury-service payment-orchestrator tron-signer; do
    echo "--- clutch-stage-${c}-1"
    for k in APP_TRONGRID_URL APP_CUSTODY_TRON_ADDRESS APP_USDT_CONTRACT \
             APP_REDEMPTIONS_ENABLED APP_PERMANENT_DEPOSIT_ADDRESSES_ENABLED \
             APP_DEPOSIT_HOT_WINDOW_HOURS APP_DEPOSIT_MATCH_WINDOW_HOURS \
             APP_MIN_REDEMPTION_CLT APP_MAX_REDEMPTION_CLT APP_REDEMPTION_FEE_USDT \
             APP_DAILY_PAYOUT_CAP_CLT APP_PER_TX_PAYOUT_CAP_USDT \
             APP_SWEEP_THRESHOLD_USDT APP_SWEEP_MAX_AGE_HOURS APP_SWEEP_MIN_USDT \
             APP_PER_TX_MINT_CAP_CLT APP_DAILY_MINT_CAP_CLT; do
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

  # The USDT payout float at <account>/2/0. Redemption payouts are paid from here and nowhere
  # else: nothing in this stack holds a key for the custody address, which is the whole reason
  # this account exists. An operator tops it up from custody, and its balance is the ceiling on
  # what a compromised treasury-service could move.
  #
  # Reuses FEE_JSON above rather than calling the signer twice. An absent payout_address means
  # the signer predates the payout rail, not that it is down -- the fee_address read above
  # already proves it is answering.
  echo ""
  echo "=== USDT float (payout account) ==="
  PAYOUT_ADDR=$(printf '%s' "$FEE_JSON" | sed -n 's/.*"payout_address"[ ]*:[ ]*"\([^"]*\)".*/\1/p')
  if [ -z "$PAYOUT_ADDR" ]; then
    echo "    (no payout_address in the signer's response -- this image predates the payout rail)"
  else
    echo "    payout_address=$PAYOUT_ADDR"
    echo "    (USDT balance: run PROBE=balance with ADDRESS=$PAYOUT_ADDR -- balanceOf lives there)"
  fi
fi

if [ "$PROBE" = "balance" ]; then
  # What an address ACTUALLY holds on chain, read from the explorer's index rather than inferred
  # from total_supply. Inferring is how a missing mint stayed invisible: supply sitting a round
  # number above genesis looks correct until you ask who holds it.
  #
  # Read-only. ADDRESS comes from the workflow input.
  : "${ADDRESS:?ADDRESS must be set for the balance probe}"

  PG=clutch-stage-clutch-explorer-postgres-1
  # Credentials come from EXPLORER_POSTGRES_{USER,DB} in .env, so read them out of the container
  # rather than hardcoding: guessing "explorer" failed with role "explorer" does not exist.
  PGU=$(docker exec "$PG" printenv POSTGRES_USER)
  PGD=$(docker exec "$PG" printenv POSTGRES_DB)
  # Ask the node itself first. The explorer index can be empty or behind, and an empty index
  # reads exactly like an empty account -- which is the mistake this probe exists to prevent.
  echo "=== balance straight from the node (authoritative) ==="
  # The node images are Rust-slim with no interpreter, so the client runs in a throwaway python
  # container on the stack's own network. Cheap, and it leaves nothing behind.
  for n in 1 2 3; do
    R=$(docker run --rm --network clutch-stage_clutch-network -v "$PWD/scripts:/s:ro"           python:3-alpine python3 /s/node-rpc.py "ws://node$n:808$n/ws"           get_account_balance "{\"address\":\"$ADDRESS\"}" 2>&1 | tail -1)
    echo "    node$n: $R"
  done

  echo ""
  echo "=== the explorer's index (secondary — can be empty or behind) ==="
  docker exec "$PG" psql -U "$PGU" -d "$PGD" -c     "select address, balance, nonce, tx_count, updated_at from accounts where address = '$ADDRESS';"     2>&1 | sed 's/^/    /'

  echo ""
  echo "=== how far behind is the index? ==="
  docker exec "$PG" psql -U "$PGU" -d "$PGD" -c     "select * from indexer_cursor;" 2>&1 | sed 's/^/    /'
  echo "    (a stale cursor means this balance is stale too, not that the account is empty)"

  echo ""
  echo "=== what the ledger believes it credited this address ==="
  docker exec clutch-stage-treasury-postgres-1 psql -U treasury -d treasury -c     "select amount_clt, status, created_at from mint_intents
     where beneficiary = '$ADDRESS' order by created_at;" 2>&1 | sed 's/^/    /'
fi

if [ "$PROBE" = "energy" ]; then
  # Does the payout float pay for TRC-20 transfers with staked energy, or by burning TRX?
  #
  # The redemption fee exists to cover that burn: about 13 TRX per payout to an address holding no
  # USDT yet. Energy delegated to the float from any wallet -- no key of ours involved -- replaces
  # the burn with a daily allowance, and this probe is how an operator confirms the delegation
  # landed BEFORE lowering the fee on the strength of it. See docs: Redemptions > Energy for payouts.
  #
  # Read-only. Everything here is public chain state.
  echo "=== payout float energy ==="
  FEE_JSON=$(docker exec clutch-stage-tron-signer-1 sh -c \
    'curl -fsS -H "Authorization: Bearer $APP_SIGNER_TOKEN" http://localhost:8093/internal/xpub' \
    2>/dev/null || true)
  PAYOUT_ADDR=$(printf '%s' "$FEE_JSON" | sed -n 's/.*"payout_address"[ ]*:[ ]*"\([^"]*\)".*/\1/p')
  if [ -z "$PAYOUT_ADDR" ]; then
    echo "    (could not read payout_address from tron-signer -- is the service up?)"
  else
    echo "    payout_address=$PAYOUT_ADDR"
    # Queried from inside the signer so it reads the same chain the payouts run against.
    RES=$(docker exec clutch-stage-tron-signer-1 sh -c \
      "curl -fsS -X POST \"\$APP_TRONGRID_URL/wallet/getaccountresource\" \
         -H 'Content-Type: application/json' \
         -d '{\"address\":\"$PAYOUT_ADDR\",\"visible\":true}'" 2>/dev/null || true)
    num() { printf '%s' "$RES" | sed -n "s/.*\"$1\"[ ]*:[ ]*\([0-9]*\).*/\1/p" | head -1; }
    LIMIT=$(num EnergyLimit); USED=$(num EnergyUsed)
    TEL=$(num TotalEnergyLimit); TEW=$(num TotalEnergyWeight)
    echo "    EnergyLimit=${LIMIT:-0}  EnergyUsed=${USED:-0}  (need 130,285 per payout to a fresh address)"
    if [ "${LIMIT:-0}" -eq 0 ]; then
      echo "    -> no energy delegated: every payout burns TRX, and the fee has to cover it."
    fi
    if [ -n "$TEL" ] && [ -n "$TEW" ] && [ "$TEW" -gt 0 ]; then
      # Energy one staked TRX earns per day, and what one daily payout therefore costs to stake.
      awk -v tel="$TEL" -v tew="$TEW" 'BEGIN {
        r = tel / tew;
        printf "    chain yields %.2f energy per TRX staked per day\n", r;
        printf "    one payout per day needs about %.0f TRX staked\n", 130285 / r }'
    fi
  fi

  # Who paid for the most recent payout's energy? The signer logs every payout's tx_id, and the
  # receipt splits the answer three ways:
  #   energy_usage         energy the SENDER supplied, own or delegated. Non-zero here with
  #                        energy_fee=0 is the delegation working. The only real proof.
  #   origin_energy_usage  energy the CONTRACT's deployer supplied. Nile's test USDT sponsors
  #                        every transfer this way, so on Nile energy_fee is 0 with or without a
  #                        delegation and proves nothing -- a payout made before delegating read
  #                        the same. Mainnet USDT makes the sender pay.
  #   energy_fee           TRX burned, in sun. What the redemption fee exists to cover.
  echo ""
  echo "=== last payout's energy: who paid ==="
  TX=$(docker logs clutch-stage-tron-signer-1 2>&1 | grep -a " paid " | tail -1 \
       | sed -n 's/.*tx_id[^0-9a-f]*\([0-9a-f]\{64\}\).*/\1/p')
  if [ -z "$TX" ]; then
    echo "    (no payout in the signer log since container start)"
  else
    INFO=$(docker exec clutch-stage-tron-signer-1 sh -c \
      "curl -fsS -X POST \"\$APP_TRONGRID_URL/wallet/gettransactioninfobyid\" \
         -H 'Content-Type: application/json' -d '{\"value\":\"$TX\"}'" 2>/dev/null || true)
    EF=$(printf '%s' "$INFO" | sed -n 's/.*"energy_fee"[ ]*:[ ]*\([0-9]*\).*/\1/p' | head -1)
    EU=$(printf '%s' "$INFO" | sed -n 's/.*"energy_usage_total"[ ]*:[ ]*\([0-9]*\).*/\1/p' | head -1)
    # The closing quote after energy_usage keeps this from matching energy_usage_total.
    ES=$(printf '%s' "$INFO" | sed -n 's/.*"energy_usage"[ ]*:[ ]*\([0-9]*\).*/\1/p' | head -1)
    EO=$(printf '%s' "$INFO" | sed -n 's/.*"origin_energy_usage"[ ]*:[ ]*\([0-9]*\).*/\1/p' | head -1)
    echo "    tx=$TX"
    echo "    energy_usage (sender, own or delegated)=${ES:-0}  origin_energy_usage (contract paid)=${EO:-0}  total=${EU:-?}"
    echo "    energy_fee=${EF:-0} sun ($(( ${EF:-0} / 1000000 )) TRX burned)"
    if [ "${EF:-0}" -gt 0 ]; then
      echo "    -> burned TRX: no delegation, or the allowance is exhausted."
    elif [ "${ES:-0}" -gt 0 ]; then
      echo "    -> paid with the sender's energy: the delegation is working."
    elif [ "${EO:-0}" -gt 0 ]; then
      echo "    -> paid by the contract's deployer. Says NOTHING about the delegation; expected on Nile."
    fi
  fi
fi

if [ "$PROBE" = "sweeper" ]; then
  # Tailing this service is useless: clutch_chain::node_client logs a get_chain_info request AND
  # its response at INFO every 2 seconds (the outbox poll), so `docker logs --tail 30` is thirty
  # lines of the same poll and nothing else. Grep for what actually matters instead.
  echo "=== sweeper / signer activity (filtered out of the 2s chain poll) ==="
  # Two filters, in this order, and the order is the whole fix. `clutch_chain::node_client` logs the
  # get_chain_info request AND its response at INFO every 2 seconds, and that response is a JSON blob
  # carrying `mint_authority` -- so the keyword `authority` below matched every single poll line and
  # this probe printed the exact noise it exists to strip. Excluding the poll by its own message
  # shape, rather than dropping the keyword, keeps `authority` doing its real job (main.rs logs
  # "mint authority confirmed by the chain" once at startup) and stops any keyword added here later
  # from colliding with the poll the same way.
  SWEEPER_LINES=$(docker logs --tail 4000 clutch-stage-treasury-service-1 2>&1 | grep -avE "Sending request to node|Received response" | grep -aiE "sweep|swept|funded|fee_account|signer|alert|authority|outbox" | tail -25)
  # Tested for emptiness, not exit status. This was a `|| echo` before, which could never fire: a
  # pipeline exits with tail's status and tail succeeds on empty input, so a probe with nothing to
  # report printed nothing at all and read as a truncated run rather than a quiet one.
  if [ -n "$SWEEPER_LINES" ]; then
    echo "$SWEEPER_LINES"
  else
    echo "(no sweeper lines in the last 4000 log lines)"
  fi

  # The signer's own log. treasury-service only ever reports "signer returned 500" -- the actual
  # reason lives here, and without it a failing sweep is unattributable.
  echo ""
  echo "=== tron-signer log ==="
  docker logs --tail 40 clutch-stage-tron-signer-1 2>&1 | tail -40 || echo "(no tron-signer container)"

  echo ""
  echo "=== is the worker alive? ==="
  # A count, not a sample. But read it correctly: the sweeper logs its heartbeat once per pass and
  # the interval is an hour, so 0 on a freshly recreated container means "no pass has come round
  # yet", NOT "dead". Only 0 on a container that has been up longer than the interval is a fault.
  N=$(docker logs clutch-stage-treasury-service-1 2>&1 | grep -aciE "sweeper" || true)
  echo "    lines mentioning the sweeper since container start: ${N:-0}"
  echo "    container up since: $(docker inspect -f '{{.State.StartedAt}}' clutch-stage-treasury-service-1 2>/dev/null || echo '?')"
  echo "    (sweep interval is 1h — expect the first heartbeat within that of startup)"

  # stderr is SHOWN, not swallowed. `2>/dev/null || echo "(could not query)"` makes a renamed table
  # and a stopped container produce identical output, and every misread probe today did exactly
  # that.
  tq() {
    echo ""
    echo "=== $1 ==="
    docker exec clutch-stage-treasury-postgres-1 psql -U treasury -d treasury -c "$2" 2>&1 | sed 's/^/    /'
  }

  # deposit_address IS NOT NULL skips discriminator-era rows, which have no address to sweep.
  tq "addresses waiting to be swept" \
     "select status, count(*), min(created_at)::date as oldest
      from mint_intents
      where deposit_address is not null and swept_at is null
      group by status order by 2 desc;"

  echo "--- the actual addresses waiting, with the index a sweep needs ---"
  # Counts are not enough. The derivation_index lives ONLY in this database, so anything that
  # wipes it (a reset_chain deploy, down -v) strands the USDT at these addresses: recoverable
  # only by scanning derivations. Print them, so a reset is never run blind over one.
  tq "addresses waiting, in full" \
    "select left(id::text,8) id, status, amount_clt, deposit_address, derivation_index idx,
            created_at::date created
       from mint_intents
      where deposit_address is not null and swept_at is null
        and status in ('approved','submitted','credited','needs_manual')
      order by created_at;"

  tq "already swept" \
     "select count(*) as swept, max(swept_at) as most_recent from mint_intents where swept_at is not null;"

  tq "open alerts" \
     "select severity, source, left(message, 300) as message, created_at
      from alerts order by created_at desc limit 6;"

  # Whether minting is halted is the single most consequential piece of state in this service,
  # and reconciliation sets it without anything else surfacing it.
  tq "breaker" "select minting_halted, halt_reason, updated_at from breaker_state;"

  # Did the received_usdt migration actually land? The overpayment fix depends on this column
  # existing; without it every deposit credit falls back to the requested amount silently.
  echo ""
  echo "=== orchestrator: received_usdt column ==="
  docker exec clutch-stage-orchestrator-postgres-1 psql -U orchestrator -d orchestrator     -c "select column_name, data_type from information_schema.columns
        where table_name = 'deposit_intents' and column_name = 'received_usdt';" 2>&1 | sed 's/^/    /'

  tq "last reconciliation runs" \
     "select status, ledger_liability, custody_reported, detail->>'trongrid_balance' as trongrid,
             run_at
      from reconciliation_runs order by run_at desc limit 5;"

  # Why a mint has not landed on chain. `submitted` in mint_intents means the outbox accepted
  # it, NOT that the chain has it -- the two are easy to confuse and the difference is whether
  # a depositor holds CLT.
  tq "mint outbox" \
     "select o.status, o.attempts, o.next_attempt_at, left(o.last_error, 120) as last_error,
             i.amount_clt, i.status as intent_status
      from chain_outbox o join mint_intents i on i.id = o.intent_id
      order by o.id desc limit 10;"

  # The watcher credits nothing while its cursor sits above the chain head: process_range returns
  # None when bound <= cursor, silently and forever. A chain reset leaves exactly that state, since
  # the cursor lives in Postgres and outlives the chain it was counting.
  tq "watcher chain cursor" "select last_processed_height from chain_cursor;"

  tq "mint intents" \
     "select id, status, beneficiary, amount_clt, expected_amount_usdt, deposit_address,
             swept_at is not null as swept,
             created_at
      from mint_intents order by created_at desc limit 10;"
fi

if [ "$PROBE" = "chain" ]; then
  # Chain height went 72778 -> 1309 -> 1105 across deploys: it is being wiped and restarted, not
  # merely resynced. Every reset destroys minted CLT while the backing USDT stays in the treasury,
  # which for a redeemable token is the worst direction for an error to run.
  #
  # DB_PATH and the nodeN-data volumes are set correctly in compose, so the question is whether the
  # node can actually WRITE there. Docker creates a mount path absent from the image as root-owned,
  # and the node runs as uid 999.
  echo "=== node data directory, from inside each node ==="
  for n in 1 2 3; do
    c="clutch-stage-node${n}-1"
    echo "--- $c"
    echo "    DB_PATH=$(docker exec "$c" printenv DB_PATH 2>/dev/null || echo '(unset)')"
    echo "    whoami:  $(docker exec "$c" id 2>/dev/null || echo '(could not run id)')"
    docker exec "$c" ls -la /app/data 2>&1 | sed 's/^/    /' | head -8
  done

  echo ""
  echo "=== is the volume actually mounted where the node writes? ==="
  docker inspect clutch-stage-node1-1 --format '{{range .Mounts}}    {{.Type}} {{.Name}}{{.Source}} -> {{.Destination}}{{"BREAK"}}{{end}}' 2>/dev/null | tr 'BREAK' '\n' | grep -v '^$' || true

  echo ""
  echo "=== node1 startup log: which DB path did it open, and did it complain? ==="
  docker logs clutch-stage-node1-1 2>&1 | head -40 | sed 's/^/    /'

  echo ""
  echo "=== volume creation time — the decisive one ==="
  # If a volume's CreatedAt is recent, it was DESTROYED and remade; the chain did not "reset", the
  # storage went away. If it is old and the chain is still short, the node is wiping its own data.
  for n in 1 2 3; do
    echo "    clutch-stage_node${n}-data: $(docker volume inspect "clutch-stage_node${n}-data" --format '{{.CreatedAt}}' 2>/dev/null || echo '(no such volume)')"
  done

  echo ""
  echo "=== on-disk size of each chain DB ==="
  # A 72k-block chain and a 900-block chain are not the same size. This distinguishes "node1 is
  # behind and resyncing" from "every node restarted from genesis".
  for n in 1 2 3; do
    echo "    node${n}: $(docker exec "clutch-stage-node${n}-1" du -sh /app/data 2>/dev/null || echo '?')"
  done

  echo ""
  echo "=== each node's own height, from its metrics endpoint ==="
  # NOT the JSON-RPC port: 8081-8083 speak WebSocket only, so curling them returns nothing and the
  # previous version reported "(no answer)" for every node -- true, but useless.
  # metric.rs serves a Prometheus gauge on 3001-3003 over plain HTTP, which is curl-able.
  #
  # And NOT grepped from the logs either: a node serving blocks to a syncing peer logs THAT peer's
  # block numbers, which made node3 look like it fell from 117,573 to 17,463 while it was feeding
  # node1, and sent an investigation the wrong way for an hour.
  for n in 1 2 3; do
    mport=$((3000 + n))
    h=$(docker exec clutch-stage-tron-signer-1 sh -c       "curl -fsS --max-time 8 http://node${n}:${mport}/metrics" 2>/dev/null       | grep -aE '^latest_block_index' | awk '{print $2}' | head -1)
    echo "    node${n}: height=${h:-<no answer on :${mport}>}"
    echo "            started $(docker inspect -f '{{.State.StartedAt}}' "clutch-stage-node${n}-1" 2>/dev/null || echo '?')"
  done

  echo ""
  echo "=== did any node wipe or re-create its chain at startup? ==="
  for n in 1 2 3; do
    echo "--- node${n}"
    docker logs "clutch-stage-node${n}-1" 2>&1 \
      | grep -aiE "genesis|wipe|reset|cleanup|creating database|chain params|mismatch|import" \
      | head -6 | sed 's/^/    /' || echo "    (nothing matched)"
  done
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

if [ "$PROBE" = "metrics" ]; then
  # Prometheus's own state first. Everything below depends on it, and a container that is not
  # running produces the same empty output as a working Prometheus with nothing to say — which is
  # how three separate wrong diagnoses happened before this block existed.
  echo "=== Prometheus container state ==="
  docker inspect -f '    state={{.State.Status}} exit={{.State.ExitCode}} restarts={{.RestartCount}} error={{.State.Error}}' \
    clutch-stage-prometheus-1 2>/dev/null || echo "    (no such container)"
  echo "    --- last 15 log lines ---"
  docker logs --tail 15 clutch-stage-prometheus-1 2>&1 | sed 's/^/    /' || echo "    (no logs)"
  echo ""

  # prom_get PATH [POST-DATA] — ask Prometheus without assuming anything about any image.
  #
  # Three earlier attempts failed, each looking obviously right, and all three were diagnosed
  # slowly because this function swallowed stderr and printed a generic "could not query" line.
  # A probe that hides its own errors is the same defect it exists to catch, so stderr reaches
  # the log now:
  #
  #   1. `docker exec clutch-stage-prometheus-1 wget ...` — recent prom/prometheus tags dropped
  #      busybox, so that image has no wget and no curl.
  #   2. curl from the host to the container IP — `docker inspect` rendered it as the literal
  #      string `invalidIP`.
  #   3. `docker exec` curl inside clutch-hub-api, whose healthcheck is a curl.
  #
  # This runs a throwaway container sharing Prometheus's own network namespace, so
  # `localhost:9090` IS Prometheus with no DNS and no IP involved. postgres:16-alpine is already
  # pulled here for the two databases and carries busybox wget.
  prom_get() {
    local path="$1" data="${2:-}"
    if ! docker inspect clutch-stage-prometheus-1 >/dev/null 2>&1; then
      echo "    prom_get: container clutch-stage-prometheus-1 does not exist" >&2
      return 1
    fi
    if [ -n "$data" ]; then
      docker run --rm --network "container:clutch-stage-prometheus-1" postgres:16-alpine \
        wget -qO- --post-data="$data" "http://localhost:9090$path"
    else
      docker run --rm --network "container:clutch-stage-prometheus-1" postgres:16-alpine \
        wget -qO- "http://localhost:9090$path"
    fi
  }

  # Does Prometheus actually have the treasury services, and are they UP?
  #
  # Worth its own probe because a scrape target can be wrong in two silent ways: the config lists a
  # job nobody can reach (DNS name, port, or network), or the service answers but with nothing in
  # it. Both look like "no alerts" on a dashboard, which is indistinguishable from healthy.
  # Are the alerting rules loaded at all? prometheus.yml globs /etc/prometheus/rules/*.yml, and a
  # glob matching nothing is not an error, so a missing mount reports zero rules and no complaint.
  # Zero groups here means every alert in config/monitoring/prometheus/rules/ silently does not
  # exist — the same failure the nginx config taught this repo to check for rather than assume.
  echo "=== alerting rules Prometheus has loaded ==="
  prom_get '/api/v1/rules' | tr ',' '
' | grep -E '"name"|"state"|"health"' | sed 's/^/    /' \
    || echo "    (could not query Prometheus; is clutch-stage-prometheus-1 running?)"
  echo ""
  echo "    If the block above is empty, the rules directory is not mounted. See docs/ALERTING.md."

  echo ""
  echo "=== scrape targets Prometheus knows about ==="
  prom_get '/api/v1/targets?state=any' \
    | tr ',' '\n' | grep -E '"job"|"health"|"scrapeUrl"|"lastError"' | sed 's/^/    /' \
    || echo "    (could not query Prometheus; is clutch-stage-prometheus-1 running?)"

  echo ""
  echo "=== the numbers Prometheus is actually holding ==="
  # Asked through Prometheus's own query API rather than by curling the services: it uses the same
  # path the scrape uses, so a value here proves the whole chain, and it avoids this probe claiming
  # "unreachable" on its own pipeline quirk while the target list says the target is up.
  # The same expressions the Grafana Treasury row uses, so this probe and the dashboard cannot
  # drift into disagreeing about what the numbers are.
  for q in clutch_treasury_up clutch_treasury_minting_halted            'clutch_treasury_clt_liability / 1000000'            'clutch_treasury_custody_usdt / 1000000'            '100 * clutch_treasury_custody_usdt / clamp_min(clutch_treasury_clt_liability, 1)'            'clutch_treasury_mint_intents{status="credited"}'            'sum(clutch_treasury_mint_intents{status="needs_manual"}) + sum(clutch_orchestrator_deposit_intents{status="needs_manual"})'            clutch_treasury_unswept_deposit_addresses            'clutch_treasury_reconciliation_status{status="ok"}'            clutch_treasury_reconciliation_age_seconds            'sum(increase(clutch_treasury_alerts_total{severity="p1"}[24h])) + sum(increase(clutch_orchestrator_alerts_total{severity="p1"}[24h]))'            clutch_orchestrator_up            clutch_orchestrator_addresses_never_polled; do
    # '+' is a SPACE in form-encoded data, so any expression adding two terms arrived at
    # Prometheus mangled and came back empty -- which read as "no such metric" rather than "this
    # probe sent nonsense". Encode it.
    enc=$(printf '%s' "$q" | sed 's/+/%2B/g')
    out=$(prom_get '/api/v1/query' "query=$enc" | tr ',' '
' | grep -A1 '"value"' | tail -1 | tr -dc '0-9.')
    printf '    %-96s %s
' "$q" "${out:-(no sample yet)}"
  done

  echo "=== what is actually parked for a human ==="
  # "Needs review: 2" on a dashboard is not actionable on its own. These are the rows behind it.
  docker exec clutch-stage-orchestrator-postgres-1 psql -U orchestrator -d orchestrator -c     "select left(id::text,8) id, status, amount_usdt, received_usdt,
            left(coalesce(tron_tx_id,'-'),16) tron_tx, left(coalesce(treasury_intent_id::text,'-'),8) treasury,
            clt_address, created_at::date created
       from deposit_intents where status = 'needs_manual' order by created_at;" 2>&1 | sed 's/^/    /'
  docker exec clutch-stage-treasury-postgres-1 psql -U treasury -d treasury -c     "select left(id::text,8) id, status, amount_clt, coalesce(deposit_address,'-') addr,
            derivation_index idx, swept_at is not null swept, created_at::date created
       from mint_intents where status in ('needs_manual','failed') order by created_at;" 2>&1 | sed 's/^/    /'

  # Was the depositor ever made whole by a separate corrective mint? A failed intent's client_ref
  # is burned, so any repayment is a DIFFERENT intent to the same beneficiary.
  echo "    --- every mint intent for the beneficiaries of those failed intents ---"
  docker exec clutch-stage-treasury-postgres-1 psql -U treasury -d treasury -c     "select left(id::text,8) id, beneficiary, amount_clt, status, created_at::date created
       from mint_intents
      where beneficiary in (select beneficiary from mint_intents where status = 'failed')
      order by beneficiary, created_at;" 2>&1 | sed 's/^/    /'

  echo "=== anything the services alerted on that nobody has looked at ==="
  docker exec clutch-stage-treasury-postgres-1 psql -U treasury -d treasury -tAc \
    "select severity || '  ' || source || '  ' || left(message, 90) from alerts
      where created_at > now() - interval '24 hours' order by created_at desc limit 8;" 2>/dev/null \
    | sed 's/^/    /' || echo "    (could not read treasury alerts)"
  docker exec clutch-stage-orchestrator-postgres-1 psql -U orchestrator -d orchestrator -tAc \
    "select severity || '  ' || source || '  ' || left(message, 90) from alerts
      where created_at > now() - interval '24 hours' order by created_at desc limit 8;" 2>/dev/null \
    | sed 's/^/    /' || echo "    (could not read orchestrator alerts)"
fi

# Always succeed. This is a read-only probe whose OUTPUT is the deliverable — a trailing non-zero
# from the last grep/test would fail the step and throw away everything printed above it, which is
# exactly how two earlier runs "failed" while having already answered the question.
exit 0
