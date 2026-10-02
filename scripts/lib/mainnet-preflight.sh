#!/usr/bin/env bash
#
# The checks before the mainnet treasury is started: preflight <mainnet env file> <stage env file>.
#
# Every line is OK or FAIL, and names a setting, never a value: the two files hold the deposit
# mnemonic, the database passwords and the tokens, and the log of the workflow that runs this is
# public. A value is compared here and never echoed, even when the comparison is what failed.
#
# What it refuses, and why:
#   - a mainnet file that is missing, readable by other users, or lacks a setting the compose file
#     requires (compose would also refuse most of these, but one setting at a time, after pulling), or
#     lacks BACKUP_PASSPHRASE (the nightly backup aborts without it, and a treasury with no backup
#     must not start);
#   - TronGrid or the USDT contract of the testnet: watching the wrong token on the wrong network
#     credits nothing, and nothing says so;
#   - any secret equal to the stage one. One DEPOSIT_MNEMONIC derives the SAME TRON addresses on Nile
#     and on mainnet, so two orchestrators sharing one would hand an address to two users; the same
#     goes for the tokens and passwords, which exist to keep the two stacks apart;
#   - a JWT_SECRET that is not .env's MAINNET_JWT_SECRET: the mainnet hub signs user tokens with
#     that one, and the orchestrator rejects every request signed by anything else;
#   - a plaintext mint key (64 hex characters) in MINT_AUTHORITY_SECRET: the mint authority is the
#     KMS key, and a plaintext one on the host is exactly what the key ceremony removed. The
#     placeholder in .env.mainnet.example (not hex) is fine.

MAINNET_USDT=TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t

# Every setting the mainnet compose file requires with `:?` or that the money path cannot run without,
# and BACKUP_PASSPHRASE: backup-treasury-db.sh aborts without it, so a treasury that started would have
# no backup the first night.
PF_REQUIRED="CUSTODY_TRON_ADDRESS TRONGRID_URL USDT_CONTRACT AZURE_TENANT_ID AZURE_CLIENT_ID AZURE_CLIENT_SECRET AZURE_VAULT_URL AZURE_KEY_NAME AZURE_KEY_VERSION DEPOSIT_MNEMONIC DEPOSIT_ACCOUNT_XPUB PAYOUT_FLOAT_ADDRESS SIGNER_TOKEN TREASURY_INITIATOR_TOKEN TREASURY_APPROVER_TOKEN TREASURY_READONLY_TOKEN TREASURY_POSTGRES_PASSWORD ORCHESTRATOR_POSTGRES_PASSWORD JWT_SECRET PER_TX_MINT_CAP_CLT DAILY_MINT_CAP_CLT MAX_REDEMPTION_CLT MIN_REDEMPTION_CLT PER_TX_PAYOUT_CAP_USDT REDEMPTION_FEE_USDT DAILY_PAYOUT_CAP_CLT BACKUP_PASSPHRASE"

# Settings that must differ between the two files.
PF_DIFFER="DEPOSIT_MNEMONIC DEPOSIT_ACCOUNT_XPUB CUSTODY_TRON_ADDRESS SIGNER_TOKEN TREASURY_INITIATOR_TOKEN TREASURY_APPROVER_TOKEN TREASURY_READONLY_TOKEN TREASURY_POSTGRES_PASSWORD ORCHESTRATOR_POSTGRES_PASSWORD JWT_SECRET BACKUP_PASSPHRASE BACKUP_REMOTE"

pf_ok()  { printf 'OK    %s\n' "$1"; }
pf_bad() { printf 'FAIL  %s\n' "$1"; PF_FAIL=1; }

# First match wins, `=` split on the first one only, surrounding double quotes and a CR stripped.
# Empty when the name is absent: `|| true`, because a grep that matches nothing must not end a
# script that runs under `set -e`.
pf_get() {  # pf_get <file> <name>
  { grep -E "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//' | tr -d '\r'; } || true
}

preflight() {  # preflight <mainnet env file> <stage env file>
  local m="$1" s="$2" n mv sv mode
  PF_FAIL=0

  if [ ! -f "$m" ]; then pf_bad "$m does not exist"; return 1; fi
  if [ ! -f "$s" ]; then pf_bad "$s does not exist"; return 1; fi
  pf_ok "$m and $s exist"

  mode=$(stat -c %a "$m")
  if [ "${mode: -1}" = "0" ]; then
    pf_ok "$m is not readable by other users"
  else
    pf_bad "$m is readable by other users (mode $mode): run chmod 600 $m"
  fi

  local missing=0
  for n in $PF_REQUIRED; do
    if [ -z "$(pf_get "$m" "$n")" ]; then pf_bad "$n is empty or missing in $m"; missing=1; fi
  done
  [ "$missing" -eq 0 ] && pf_ok "every required setting is set"

  [ "$(pf_get "$m" TRONGRID_URL)" = "https://api.trongrid.io" ] \
    && pf_ok "TronGrid is mainnet's" || pf_bad "TRONGRID_URL is not https://api.trongrid.io"
  [ "$(pf_get "$m" USDT_CONTRACT)" = "$MAINNET_USDT" ] \
    && pf_ok "the USDT contract is mainnet's" || pf_bad "USDT_CONTRACT is not the mainnet USDT contract"

  local same=0
  for n in $PF_DIFFER; do
    mv=$(pf_get "$m" "$n")
    sv=$(pf_get "$s" "$n")
    if [ -n "$mv" ] && [ "$mv" = "$sv" ]; then
      pf_bad "$n is the same in both files (never share secrets between .env and .env.mainnet)"
      same=1
    fi
  done
  [ "$same" -eq 0 ] && pf_ok "no secret is shared with the stage file"

  # The stage hub's own JWT secret is JWT_SECRET in .env: the mainnet orchestrator must not trust it.
  mv=$(pf_get "$m" JWT_SECRET)
  sv=$(pf_get "$s" MAINNET_JWT_SECRET)
  if [ -n "$mv" ] && [ "$mv" = "$sv" ]; then
    pf_ok "JWT_SECRET matches MAINNET_JWT_SECRET, the mainnet hub's"
  else
    pf_bad "JWT_SECRET does not match MAINNET_JWT_SECRET in $s (the mainnet hub signs user tokens with that one)"
  fi

  mv=$(pf_get "$m" MINT_AUTHORITY_SECRET)
  if printf '%s' "$mv" | grep -Eq '^(0x)?[0-9a-fA-F]{64}$'; then
    pf_bad "a plaintext mint key (MINT_AUTHORITY_SECRET) is in the mainnet file: the mint authority is the KMS key"
  else
    pf_ok "no plaintext mint key in the mainnet file"
  fi

  return "$PF_FAIL"
}
