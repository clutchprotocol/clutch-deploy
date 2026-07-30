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
trap 'rc=$?; echo "ABORT: exit $rc at line ${LINENO}: ${BASH_COMMAND}"; exit $rc' ERR

CUSTODY="${1:?usage: provision-bitcart.sh <custody_address> [usdt_contract] [compose_project]}"
CONTRACT="${2:-TXLAQ63Xg1NAzckPwKHvzw7CSEmLMEqcdj}"  # NILE testnet USDT
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

# --- watch-only wallet --------------------------------------------------------------------
WALLETS="$(bc "$API/wallets" -H "Authorization: Bearer $TOK" || true)"
WID="$(printf '%s' "$WALLETS" | python3 -c "import sys,json
try:
    d = json.load(sys.stdin).get('result', [])
except Exception:
    d = []
print(next((w['id'] for w in d if w.get('name') == 'clutch-custody-usdt'), ''))")"

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
  echo "wallet: created"
else
  echo "wallet: reusing existing"
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
