#!/usr/bin/env bash
#
# One-shot: fill in the treasury secrets stage's .env is missing, and read the deposit wallet's
# public material back out.
#
# .env on this host is the source of truth -- deploy-stage.sh READS it and never writes it, which
# is what makes hand-provisioning work at all. This script is that hand-provisioning, done once,
# from a workflow, so the SSH password stays in GitHub's secret store instead of someone's laptop.
#
# # Idempotent, and that is load-bearing
#
# Every variable is written ONLY if absent. Re-running must never mint a second wallet: the first
# one would already be holding user deposits at addresses derived from it, and overwriting
# DEPOSIT_MNEMONIC orphans every one of them permanently. There is no recovery from that -- the
# addresses are still on chain, still receiving, and nothing left can sign for them.
#
# So: no --force, no overwrite flag, no "regenerate" mode. If a value needs replacing, that is a
# deliberate migration with a sweep of the old wallet first, not a re-run of this.
#
# # Nothing secret is ever printed
#
# The generated mnemonic is piped straight into .env and never touches stdout. What this prints is
# variable NAMES, and the account xpub plus the fee address -- both public by construction: an
# xpub derives receive addresses and cannot spend, and the fee address is where an operator sends
# TRX. The workflow log is readable by anyone with repo access; assume it is public.

set -euo pipefail

SIGNER_IMAGE="ghcr.io/clutchprotocol/clutch-tron-signer:latest"
PROBE="tron-signer-xpub-probe"

# Secrets we can generate ourselves. 32 random bytes covers all of them: the four-eyes tokens and
# both Postgres passwords are opaque strings, and MINT_AUTHORITY_SECRET is a secp256k1 scalar,
# for which any 32-byte value is valid with overwhelming probability.
# JWT_SECRET and GRAFANA_ADMIN_PASSWORD are in this list because they had committed fallbacks in
# docker-compose, which means the value protecting stage was published in a public repository.
# The first run here generates real ones; every later run leaves them alone like everything else.
#
# Generating JWT_SECRET rotates it, so tokens signed with the old value stop being accepted and
# anyone signed into the demo app authenticates again. That is the point: the old one is readable
# by anybody. The hub API and the orchestrator both read this variable, so they move together.
GENERATED="TREASURY_POSTGRES_PASSWORD ORCHESTRATOR_POSTGRES_PASSWORD MINT_AUTHORITY_SECRET \
           TREASURY_INITIATOR_TOKEN TREASURY_APPROVER_TOKEN TREASURY_READONLY_TOKEN SIGNER_TOKEN \
           JWT_SECRET GRAFANA_ADMIN_PASSWORD"

# The env file to fill. Defaults to .env, the testnet stack's. The mainnet treasury runs from
# its own file (compose --env-file .env.mainnet) and every secret in it MUST be a different value:
# TRON addresses are network-agnostic, so a shared DEPOSIT_MNEMONIC derives the SAME deposit
# addresses on both networks, and two orchestrators with separate databases would hand one address
# to two different users.
#
# Nothing else changes. The no-overwrite rule matters more here, not less: replacing a mnemonic
# orphans every address already handed out, on a network where those addresses hold real money.
ENV_FILE="${ENV_FILE:-.env}"

if [ ! -f "$ENV_FILE" ]; then
  echo "ABORT: no $ENV_FILE here ($(pwd)). Expected the stage deploy checkout."
  if [ "$ENV_FILE" != ".env" ]; then
    echo "Copy .env.mainnet.example to $ENV_FILE first and fill in CUSTODY_TRON_ADDRESS,"
    echo "TRONGRID_URL and USDT_CONTRACT. Everything else in it is generated here."
    echo "Do NOT copy secrets across from .env: a shared DEPOSIT_MNEMONIC derives the same"
    echo "deposit addresses on both networks, and two orchestrators would hand one address"
    echo "to two different users."
  fi
  exit 1
fi

# Present AND non-empty. `grep -q "^VAR="` would count `VAR=` as set, and an empty mnemonic is a
# boot failure several steps removed from its cause.
has() { grep -qE "^$1=.+" "$ENV_FILE"; }

# Read values with sed, never by sourcing .env -- the mnemonic contains spaces and `. ./.env`
# would try to run its words as commands.
val() { sed -n "s/^$1=//p" "$ENV_FILE" | head -1; }

# Write a NON-SECRET setting if absent, and say what it is. Printing the value is the point here:
# which chain and which contract stage is pointed at should be legible in the log.
pin() {
  if has "$1"; then
    echo "    $1: already pinned to $(val "$1")"
  else
    echo "$1=$2" >> "$ENV_FILE"
    echo "    $1: pinned to $2"
  fi
}

# The one value this script cannot invent. It is the sweep destination -- a wallet somebody must
# already control -- and generating one here would send every swept deposit to an address whose
# keys exist nowhere.
if ! has CUSTODY_TRON_ADDRESS; then
  echo "ABORT: CUSTODY_TRON_ADDRESS is not set in $ENV_FILE."
  echo "  It is the treasury address sweeps land in, so it has to be a wallet you already hold."
  echo "  Set it by hand, then re-run."
  exit 1
fi

# A well-formed address, checked before anything is generated against it.
#
# CUSTODY_TRON_ADDRESS is where every swept USDT lands and nothing in this stack can spend from it
# (readiness A4, A5). A typo is therefore not a bug that gets fixed later -- it is money sent to an
# address nobody holds a key for. Base58check exists to catch exactly this, so check it.
#
# The same python:3-alpine the xpub probe uses, so this adds no dependency to the host. It proves
# the address is well formed and on TRON MAINNET; it cannot prove the operator controls it, and
# nothing can.
echo "=== checking CUSTODY_TRON_ADDRESS is a valid TRON mainnet address ==="
if ! docker run --rm python:3-alpine python3 -c '
import hashlib, sys
A = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
a = sys.argv[1]
n = 0
for c in a:
    if c not in A:
        print("  not base58: the character %r cannot appear in a TRON address" % c); sys.exit(1)
    n = n * 58 + A.index(c)
raw = n.to_bytes((n.bit_length() + 7) // 8, "big")
raw = b"\x00" * (len(a) - len(a.lstrip("1"))) + raw
if len(raw) != 25:
    print("  wrong length: decoded %d bytes, a TRON address is 25" % len(raw)); sys.exit(1)
if raw[0] != 0x41:
    print("  wrong network: version byte 0x%02x, TRON mainnet is 0x41" % raw[0]); sys.exit(1)
if hashlib.sha256(hashlib.sha256(raw[:-4]).digest()).digest()[:4] != raw[-4:]:
    print("  CHECKSUM MISMATCH — this is a mistyped address, not a real one"); sys.exit(1)
print("  valid TRON mainnet address, hex 41%s" % raw[1:-4].hex())
' "$(val CUSTODY_TRON_ADDRESS)"; then
  echo "ABORT: CUSTODY_TRON_ADDRESS in $ENV_FILE is not a valid TRON mainnet address."
  echo "Nothing has been written. Fix it before running this again -- every sweep goes there"
  echo "and nothing in this stack can move it back."
  exit 1
fi

# ONE backup, overwritten each run -- not a timestamped pile. Every copy holds DEPOSIT_MNEMONIC,
# so each is exactly as sensitive as .env itself, and the old naming left one more of them on the
# host per run with no upper bound. Keeping the most recent one still makes a bad edit undoable,
# which is the only reason to copy .env at all.
#
# cp -a preserves the mode, and the FIRST backup this script ever took predated .env being
# chmodded 600, so it inherited whatever the file happened to be and sat on the host readable.
# The explicit chmod covers that. Copy before deleting, so a failed cp cannot leave nothing behind.
cp -a "$ENV_FILE" "$ENV_FILE.bak"
chmod 600 "$ENV_FILE.bak"
# Sweep the pile earlier runs left. This glob requires a character after `.bak.`, so it cannot
# match .env.bak itself.
rm -f "$ENV_FILE".bak.*
echo "=== backed up $ENV_FILE to $ENV_FILE.bak (mode 600); removed older timestamped copies ==="

# These two decide WHICH CHAIN and WHICH TOKEN stage is operating on. They have been coming from
# docker-compose.treasury.yml's defaults, so editing that file would move a running stage to a
# different network or a different contract on the next deploy -- no diff on this host, nothing in
# the deploy log, and the first symptom is deposits that are never matched because the watcher is
# looking at the wrong chain.
#
# The values below are exactly the defaults stage is already running, so pinning them changes
# nothing today. That is what makes it worth doing now rather than during an incident.
echo ""
echo "=== pinned settings (chain and token) ==="
pin TRONGRID_URL "https://nile.trongrid.io"
# Nile has TWO tokens reporting the symbol USDT. This is the one the faucet actually dispenses
# (contract name TetherToken, matching mainnet USDT). The other, TXLAQ63Xg1NAzckPwKHvzw7CSEmLMEqcdj,
# exists and answers "USDT" but nobody can obtain it -- deploy-stage.sh aborts if .env names it,
# because a stage pinned to it is untestable by construction.
pin USDT_CONTRACT "TXYZopYRdj2D9XRtbG411XZZ3kM5VkAeBf"

# The TronGrid API key, if one was passed in.
#
# Not generated and not defaulted -- it is issued by trongrid.io against an account, so it can only
# come from outside. It arrives as an environment variable forwarded from a repository secret, NOT
# as a workflow input: dispatch inputs are shown in plain text in the run UI, while secrets are
# masked in the log.
#
# Optional, and the stack runs without it. But unkeyed TronGrid throttles hard, and a throttled
# watcher is indistinguishable from "nobody paid" -- a deposit that is never detected looks exactly
# like a deposit that was never made.
echo ""
echo "=== TronGrid API key ==="
if has TRONGRID_API_KEY; then
  echo "    TRONGRID_API_KEY: already set, left alone"
elif [ -n "${TRONGRID_API_KEY:-}" ]; then
  # Length only. The value is a credential and this log is readable by anyone with repo access.
  echo "TRONGRID_API_KEY=$TRONGRID_API_KEY" >> "$ENV_FILE"
  echo "    TRONGRID_API_KEY: written (${#TRONGRID_API_KEY} chars)"
else
  echo "    TRONGRID_API_KEY: not provided -- stage keeps polling TronGrid unkeyed."
  echo "      Unkeyed means rate-limited, and a throttled watcher looks exactly like nobody paid."
  echo "      Set the repo secret, then re-run this workflow:"
  echo "        gh secret set TRONGRID_API_KEY --repo clutchprotocol/clutch-deploy"
fi

echo ""
echo "=== generated secrets ==="
for v in $GENERATED; do
  if has "$v"; then
    echo "    $v: already set, left alone"
  else
    echo "$v=$(openssl rand -hex 32)" >> "$ENV_FILE"
    echo "    $v: generated"
  fi
done

echo ""
echo "=== deposit wallet ==="
if has DEPOSIT_MNEMONIC; then
  echo "    DEPOSIT_MNEMONIC: already set, left alone"
else
  # Piped straight into .env: the phrase can spend every deposit address, and a workflow log is
  # not a place it can ever appear. Unquoted on purpose -- Compose reads the rest of the line as
  # the value, and quotes would end up inside the phrase on some Compose versions.
  #
  # Generated on the host because stage is Nile testnet, where this wallet is throwaway. A MAINNET
  # mnemonic does not get generated on an internet-facing box by a CI job.
  docker run --rm python:3-alpine sh -c \
    'pip install -q mnemonic && python -c "from mnemonic import Mnemonic; print(Mnemonic(\"english\").generate(128))"' \
    | sed 's/^/DEPOSIT_MNEMONIC=/' >> "$ENV_FILE"
  if has DEPOSIT_MNEMONIC; then
    echo "    DEPOSIT_MNEMONIC: generated (12 words, never printed)"
  else
    echo "ABORT: mnemonic generation produced nothing."
    exit 1
  fi
fi

# The xpub has to come FROM the mnemonic, and the only thing that derives it is the signer. Run a
# throwaway one rather than deriving it here: a second implementation of the derivation path is
# exactly how the orchestrator ends up watching addresses the signer cannot sign for.
echo ""
echo "=== reading the wallet's public material from a throwaway signer ==="
cleanup() { docker rm -f "$PROBE" >/dev/null 2>&1 || true; }
trap cleanup EXIT

cleanup
docker pull -q "$SIGNER_IMAGE" >/dev/null

# Same defaults docker-compose.treasury.yml applies, so the probe derives from the same wallet
# the real signer will. Neither is used by /internal/xpub -- derivation touches no network --
# but the signer requires both at boot, and a divergent value here would be a trap for whoever
# copies this block later.
TRONGRID=$(val TRONGRID_URL)
[ -n "$TRONGRID" ] || TRONGRID="https://nile.trongrid.io"
USDT=$(val USDT_CONTRACT)
[ -n "$USDT" ] || USDT="TXYZopYRdj2D9XRtbG411XZZ3kM5VkAeBf"

# tron-signer refuses to boot without a payout cap -- validate_payout_cap rejects anything
# non-positive, because a zero cap would refuse every payout silently. This container never signs
# one: it is started only to read /internal/xpub, which is pure derivation with no network call.
# So use the configured value when the env file already has it, and a minimal 1 otherwise, purely
# to satisfy the boot check.
#
# Missing here since that requirement was added to the signer, which made this script fail on any
# NEW env file while the existing .env kept working -- it had been provisioned before the check
# existed. Found provisioning .env.mainnet on 2026-09-21.
PAYOUT_CAP=$(val PER_TX_PAYOUT_CAP_USDT)
[ -n "$PAYOUT_CAP" ] || PAYOUT_CAP=1

docker run -d --name "$PROBE" \
  -e APP_PER_TX_PAYOUT_CAP_USDT="$PAYOUT_CAP" \
  -e APP_DEPOSIT_MNEMONIC="$(val DEPOSIT_MNEMONIC)" \
  -e APP_SIGNER_TOKEN="$(val SIGNER_TOKEN)" \
  -e APP_TREASURY_ADDRESS="$(val CUSTODY_TRON_ADDRESS)" \
  -e APP_TRONGRID_URL="$TRONGRID" \
  -e APP_USDT_CONTRACT="$USDT" \
  "$SIGNER_IMAGE" >/dev/null

# No network call in this path -- /internal/xpub is pure derivation -- so this is only waiting for
# the process to bind its port.
JSON=""
for _ in $(seq 1 30); do
  JSON=$(docker exec "$PROBE" sh -c \
    'curl -fsS -H "Authorization: Bearer $APP_SIGNER_TOKEN" http://localhost:8093/internal/xpub' 2>/dev/null || true)
  if [ -n "$JSON" ]; then break; fi
  sleep 1
done

if [ -z "$JSON" ]; then
  echo "ABORT: the signer never answered /internal/xpub. Its log:"
  docker logs "$PROBE" 2>&1 | tail -20
  exit 1
fi

XPUB=$(printf '%s' "$JSON" | sed -n 's/.*"account_xpub"[ ]*:[ ]*"\([^"]*\)".*/\1/p')
FEE=$(printf '%s' "$JSON" | sed -n 's/.*"fee_address"[ ]*:[ ]*"\([^"]*\)".*/\1/p')

if [ -z "$XPUB" ] || [ -z "$FEE" ]; then
  echo "ABORT: could not parse the signer's response."
  exit 1
fi

if has DEPOSIT_ACCOUNT_XPUB; then
  EXISTING=$(val DEPOSIT_ACCOUNT_XPUB)
  if [ "$EXISTING" = "$XPUB" ]; then
    echo "    DEPOSIT_ACCOUNT_XPUB: already set and matches the mnemonic"
  else
    # The orchestrator would hand out addresses from one wallet while the signer holds another.
    # Deposits would arrive at addresses nothing can sweep, and nothing would look wrong until
    # someone tried to move the money.
    echo "ABORT: DEPOSIT_ACCOUNT_XPUB in $ENV_FILE does NOT match DEPOSIT_MNEMONIC."
    echo "  These must be the same wallet. Sweep the old one before changing either."
    exit 1
  fi
else
  echo "DEPOSIT_ACCOUNT_XPUB=$XPUB" >> "$ENV_FILE"
  echo "    DEPOSIT_ACCOUNT_XPUB: written"
fi

chmod 600 "$ENV_FILE"

echo ""
echo "=== public material (safe to copy) ==="
echo "    account_xpub = $XPUB"
echo "    fee_address  = $FEE"
echo ""
echo "    Send Nile TRX to fee_address -- 31+ TRX, or no deposit can be swept."
echo ""
echo "=== $ENV_FILE now defines ==="
grep -oE '^[A-Z_]+'  "$ENV_FILE" | sort | tr '\n' ' '
echo ""
exit 0
