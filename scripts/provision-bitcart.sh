#!/usr/bin/env bash
# Provision Bitcart for a deployed stack: admin user, watch-only wallet, store — then write
# BITCART_TOKEN / BITCART_STORE_ID into .env so payment-orchestrator can start.
#
# Lives as a FILE rather than inline in the workflow deliberately. Inlined, it aborted silently
# after the first few lines with no trap output and no error, and four rounds of guesswork did not
# find it — the SSH action's handling of a long multi-line script was itself the variable. As a
# file it can be `bash -n` checked, run by hand, and read in isolation.
#
# Usage:  scripts/provision-bitcart.sh <custody_address> [usdt_contract] [compose_project]
#
# IDEMPOTENT: an existing user, wallet or store is detected and reused.
# NOTHING SECRET IS PRINTED: the API token and generated admin password go straight into .env.
set -Eeuo pipefail
# shellcheck disable=SC2154  # `rc` is assigned in this very trap, before it is read
trap 'rc=$?; echo "ABORT: exit $rc at line ${LINENO}: ${BASH_COMMAND}"; exit $rc' ERR

CUSTODY="${1:?usage: provision-bitcart.sh <custody_address> [usdt_contract] [compose_project]}"
# NILE testnet USDT — the token the nileex.io faucet dispenses (contract name
# `TetherToken`, same as mainnet USDT). NOT TXLAQ63Xg1NAzckPwKHvzw7CSEmLMEqcdj,
# which also reports symbol "USDT" on Nile but is not faucet-dispensed, so no one
# could ever fund a test deposit against it.
CONTRACT="${2:-TXYZopYRdj2D9XRtbG411XZZ3kM5VkAeBf}"
PROJECT="${3:-clutch-stage}"

NET="${PROJECT}_clutch-network"
API="http://bitcart-backend:8000"
EMAIL="admin@clutch-stage.example.com"
CURL_IMAGE="curlimages/curl:8.10.1"

# Bitcart's port is unpublished on stage (`ports: !reset []`) because 8092 is its ADMIN API and
# must not sit on a public interface. So reach it over the compose network by service name, on the
# INTERNAL port — the same way the deploy's health gate does.
bc() { docker run --rm --network "$NET" "$CURL_IMAGE" -s "$@"; }

json_get() { # json_get <key>  — reads stdin, regex not a parser, so a non-JSON body can't crash it
  python3 -c "import sys,re; m=re.search(r'\"$1\"\s*:\s*\"([^\"]+)\"', sys.stdin.read()); print(m.group(1) if m else '')"
}

setenv() { # replace-or-append KEY=VALUE in .env; the value is never echoed
  local k="$1" v="$2"
  touch .env
  grep -vE "^${k}=" .env > .env.tmp 2>/dev/null || true
  printf '%s=%s\n' "$k" "$v" >> .env.tmp
  mv .env.tmp .env
  chmod 600 .env
  echo "  .env: ${k} set"
}

echo "network=$NET  project=$PROJECT  contract=$CONTRACT"

if ! docker run --rm --network "$NET" "$CURL_IMAGE" -sf -m 10 "$API/manage/policies" >/dev/null 2>&1; then
  echo "ABORT: Bitcart is not answering at $API on network $NET."
  docker ps --filter name=bitcart --format '  {{.Names}}  {{.Status}}' || true
  exit 1
fi
echo "bitcart: reachable"

# --- admin user ---------------------------------------------------------------------------
if grep -qE '^BITCART_ADMIN_PASSWORD=.+' .env 2>/dev/null; then
  PW="$(grep -m1 -E '^BITCART_ADMIN_PASSWORD=' .env | cut -d= -f2-)"
  echo "admin: reusing password from .env"
else
  # No `| head -c`: that closes the pipe, upstream takes SIGPIPE, and pipefail turns it into a
  # failed pipeline. Trim with parameter expansion, which cannot fail.
  PW="$(od -An -tx1 -N24 /dev/urandom | tr -d '[:space:]')"
  PW="${PW:0:32}"
  setenv BITCART_ADMIN_PASSWORD "$PW"
  echo "admin: generated a new password"
fi
setenv BITCART_ADMIN_EMAIL "$EMAIL"

# A 4xx here just means the user already exists — a valid re-run.
bc -o /dev/null -X POST "$API/users" -H 'content-type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PW\"}" || true

TOKRESP="$(bc -X POST "$API/token" -H 'content-type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PW\",\"permissions\":[\"full_control\"]}" || true)"
TOK="$(printf '%s' "$TOKRESP" | json_get access_token)"
if [ -z "$TOK" ]; then
  echo "ABORT: could not authenticate to Bitcart. Response was:"
  echo "$TOKRESP"
  echo ""
  echo "If the admin user exists under a different password, clear BITCART_ADMIN_PASSWORD"
  echo "from .env and re-run."
  exit 1
fi
echo "auth: ok"

echo "custody: $CUSTODY"
setenv CUSTODY_TRON_ADDRESS "$CUSTODY"

# Refresh the TRX daemon against the CURRENT compose before validating a contract against it.
#
# Bitcart validates the wallet's contract by asking its daemon, and the daemon only knows the
# network it was started with. Stage hit "Invalid contract" for exactly this reason: the running
# daemon predated the fix that moved everything to Nile, so it was checking a Nile-only contract
# against Shasta. Deploys could not correct it either — they were blocked on the very secrets this
# script exists to produce.
#
# Safe to run unconditionally: recreating these two containers touches nothing else, and both
# BITCART_* values use `:-` defaults in the compose, so a not-yet-provisioned .env still renders.
COMPOSE_FILES=(-f docker-compose.yml -f docker-compose.treasury.yml -f docker-compose.bitcart.yml
               -f docker-compose.stage.cloudflare-flex.yml -f docker-compose.stage.treasury.yml)
echo "trx daemon: recreating against current compose (network must match the contract)"
docker compose -p "$PROJECT" "${COMPOSE_FILES[@]}" up -d --force-recreate bitcart-trx bitcart-backend

# The backend needs a moment to come back before it will answer, and the daemon needs to have
# connected upstream before it can validate anything.
for _ in $(seq 1 30); do
  if docker run --rm --network "$NET" "$CURL_IMAGE" -sf -m 5 "$API/manage/policies" >/dev/null 2>&1; then
    echo "trx daemon: backend back up"
    break
  fi
  sleep 3
done

# The token was issued by the previous backend process; re-authenticate against the new one.
TOKRESP="$(bc -X POST "$API/token" -H 'content-type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PW\",\"permissions\":[\"full_control\"]}" || true)"
TOK="$(printf '%s' "$TOKRESP" | json_get access_token)"
if [ -z "$TOK" ]; then
  echo "ABORT: lost authentication after recreating the backend. Response was:"
  echo "$TOKRESP"
  exit 1
fi
echo "auth: refreshed"

# --- watch-only wallet --------------------------------------------------------------------
WALLETS="$(bc "$API/wallets" -H "Authorization: Bearer $TOK" || true)"
WINFO="$(printf '%s' "$WALLETS" | python3 -c "import sys,json
try:
    d = json.load(sys.stdin).get('result', [])
except Exception:
    d = []
w = next((w for w in d if w.get('name') == 'clutch-custody-usdt'), None)
print((w.get('id') or '') if w else '')
print((w.get('contract') or '') if w else '')")"
WID="$(printf '%s' "$WINFO" | sed -n 1p)"
WCONTRACT="$(printf '%s' "$WINFO" | sed -n 2p)"

if [ -z "$WID" ]; then
  # `contract` is what denominates invoices in USDT. Without it Bitcart prices in native TRX at an
  # exchange rate, which rounds away the amount discriminator — the only thing telling two payers
  # apart on one shared custody address.
  WRESP="$(bc -X POST "$API/wallets" -H "Authorization: Bearer $TOK" -H 'content-type: application/json' \
    -d "{\"name\":\"clutch-custody-usdt\",\"xpub\":\"$CUSTODY\",\"currency\":\"trx\",\"contract\":\"$CONTRACT\"}" || true)"
  WID="$(printf '%s' "$WRESP" | json_get id)"
  if [ -z "$WID" ]; then
    echo "ABORT: wallet creation failed. Response was:"
    echo "$WRESP"
    echo ""
    echo "Check the address is valid base58check and that the contract exists on the network"
    echo "TRX_SERVER points at (they must be the SAME network)."
    exit 1
  fi
  echo "wallet: created (contract $CONTRACT)"
elif [ "$WCONTRACT" != "$CONTRACT" ]; then
  # Matching on NAME alone is not idempotency, it is a stale read. The contract is baked into the
  # wallet at creation and decides which TRC-20 token Bitcart watches; without this branch,
  # re-running after a contract change reported "reusing existing" and left Bitcart watching the
  # old token, while treasury-service verified against the new one. Deposits would then be seen
  # by neither, or by only one of the two, with nothing in any log naming the cause.
  echo "wallet: contract changed ('$WCONTRACT' -> '$CONTRACT') — updating"
  PRESP="$(bc -X PATCH "$API/wallets/$WID" -H "Authorization: Bearer $TOK" -H 'content-type: application/json' \
    -d "{\"name\":\"clutch-custody-usdt\",\"xpub\":\"$CUSTODY\",\"currency\":\"trx\",\"contract\":\"$CONTRACT\"}" || true)"
  NEWC="$(printf '%s' "$PRESP" | python3 -c "import sys,json
try: print(json.load(sys.stdin).get('contract') or '')
except Exception: print('')")"
  if [ "$NEWC" != "$CONTRACT" ]; then
    echo "ABORT: could not update the wallet contract. Response was:"
    echo "$PRESP"
    echo ""
    echo "Delete the 'clutch-custody-usdt' wallet in Bitcart and re-run, or Bitcart will keep"
    echo "watching $WCONTRACT while treasury-service verifies against $CONTRACT."
    exit 1
  fi
  echo "wallet: contract updated"
else
  echo "wallet: reusing existing (contract $WCONTRACT)"
fi

# --- store ----------------------------------------------------------------------------------
STORES="$(bc "$API/stores" -H "Authorization: Bearer $TOK" || true)"
SID="$(printf '%s' "$STORES" | python3 -c "import sys,json
try:
    d = json.load(sys.stdin).get('result', [])
except Exception:
    d = []
print(next((s['id'] for s in d if s.get('name') == 'clutch-deposits'), ''))")"

if [ -z "$SID" ]; then
  SRESP="$(bc -X POST "$API/stores" -H "Authorization: Bearer $TOK" -H 'content-type: application/json' \
    -d "{\"name\":\"clutch-deposits\",\"wallets\":[\"$WID\"],\"default_currency\":\"USDT\"}" || true)"
  SID="$(printf '%s' "$SRESP" | json_get id)"
  if [ -z "$SID" ]; then
    echo "ABORT: store creation failed. Response was:"
    echo "$SRESP"
    exit 1
  fi
  echo "store: created"
else
  echo "store: reusing existing"
fi

setenv BITCART_TOKEN "$TOK"
setenv BITCART_STORE_ID "$SID"
setenv BITCART_URL "$API"

echo ""
echo "provisioned. store_id=$SID custody=$CUSTODY"
echo "token written to .env, not printed"
echo "Next: run 'Deploy stage (VPS)' with reset_chain unticked."
