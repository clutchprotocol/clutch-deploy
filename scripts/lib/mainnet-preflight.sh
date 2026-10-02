#!/usr/bin/env bash
#
# The checks before the mainnet treasury is started: preflight <mainnet env file> <stage env file>.
#
# Every line is OK or FAIL, and names a setting or a line number, never a value and never the content
# of a line: the two files hold the deposit mnemonic, the database passwords and the tokens, and the
# log of the workflow that runs this is public. A value is compared here and never echoed, even when
# the comparison is what failed.
#
# What it refuses, and why:
#   - a mainnet file that is missing, readable by its group or by other users, or lacks a setting the
#     compose file requires (compose would also refuse most of these, but one setting at a time, after
#     pulling), or lacks BACKUP_PASSPHRASE (the nightly backup aborts without it, and a treasury with
#     no backup must not start);
#   - a mainnet file that is not plain (pf_lint): a line that is not blank, a # comment or NAME=value,
#     a name set twice, or a value that compose and the services read differently from its text. Then
#     the mainnet file can be compared as plain text, and a stray line cannot reach `docker compose
#     config`, which prints the line it cannot parse;
#   - TronGrid or the USDT contract of the testnet: watching the wrong token on the wrong network
#     credits nothing, and nothing says so;
#   - a GasFree network that is not mainnet: check-cap-invariants.sh only checks that the relay URL
#     fits the network, so a Nile pair passes it;
#   - any secret equal to the stage one. One DEPOSIT_MNEMONIC derives the SAME TRON addresses on Nile
#     and on mainnet, so two orchestrators sharing one would hand an address to two users; the same
#     goes for the tokens, the passwords and the float address, which exist to keep the two stacks
#     apart. The stage file is read the way compose reads it (pf_get_stage) and the mnemonic is
#     compared by its words, because tron-signer ignores the spacing: a stage secret copied by hand
#     with a trailing space, quotes or a double space is still the same secret;
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
PF_DIFFER="DEPOSIT_MNEMONIC DEPOSIT_ACCOUNT_XPUB CUSTODY_TRON_ADDRESS PAYOUT_FLOAT_ADDRESS SIGNER_TOKEN TREASURY_INITIATOR_TOKEN TREASURY_APPROVER_TOKEN TREASURY_READONLY_TOKEN TREASURY_POSTGRES_PASSWORD ORCHESTRATOR_POSTGRES_PASSWORD JWT_SECRET BACKUP_PASSPHRASE BACKUP_REMOTE"

pf_ok()  { printf 'OK    %s\n' "$1"; }
pf_bad() { printf 'FAIL  %s\n' "$1"; PF_FAIL=1; }

# The MAINNET file, plain text: pf_lint has refused everything that is not plain. First match wins,
# `=` split on the first one only, surrounding double quotes and a CR stripped. Empty when the name is
# absent: `|| true`, because a grep that matches nothing must not end a script that runs under `set -e`.
pf_get() {  # pf_get <file> <name>
  { grep -E "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//' | tr -d '\r'; } || true
}

# The STAGE file, read the way compose reads it, because a secret copied by hand is the same secret to
# compose even when its text differs: the LAST of a duplicated name wins, a trailing CR and the spaces
# and tabs around the value go, a value wrapped in one pair of quotes loses them, and an unquoted value
# stops at a space followed by #. The stage file is not linted (it holds many other settings); this only
# reads it. Prints the value, or nothing. Simplification: a quoted value followed by a comment keeps its
# quotes here, which compose would drop.
pf_get_stage() {  # pf_get_stage <file> <name>
  local v cr=$'\r'
  v=$(grep -E "^$2=" "$1" 2>/dev/null | tail -n 1) || true
  v="${v#*=}"
  v="${v%"$cr"}"
  v="${v#"${v%%[![:blank:]]*}"}"
  v="${v%"${v##*[![:blank:]]}"}"
  case "$v" in
    '"'*'"'|"'"*"'") v="${v#?}"; v="${v%?}" ;;
    *' #'*) v="${v%% #*}"; v="${v%"${v##*[![:blank:]]}"}" ;;
  esac
  printf '%s' "$v"
}

# The MAINNET file, line by line. Every line must be blank (spaces and tabs only), a comment (# in
# column 1) or NAME=value, and a name may be set once. A value must be plain, because compose and the
# services read it more loosely than its text says: they drop a carriage return and the spaces around
# it, take quotes off, cut a " #" comment, expand a dollar sign and take the LAST of a duplicated name.
# A stray line is refused too: `docker compose config` prints the line it cannot parse, and the log of
# the workflow is public. Prints line numbers and names only, never a line or a value. Returns 1 when it
# refused something, and sets PF_FAIL through pf_bad like every other check, so it works on its own.
pf_lint() {  # pf_lint <file>
  local f="$1" line="" name value n=0 bad=0 seen=" " dups=" " cr=$'\r'
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    if [ -z "${line//[[:blank:]]/}" ]; then continue; fi
    case "$line" in '#'*) continue ;; esac
    name=""; value=""
    case "$line" in *=*) name="${line%%=*}"; value="${line#*=}" ;; esac
    case "$name" in
      ''|[!A-Za-z_]*|*[!A-Za-z0-9_]*)
        pf_bad "line $n is not blank, a # comment, or NAME=value"; bad=1; continue ;;
    esac
    case "$value" in *"$cr"*) pf_bad "$name has a carriage return (line $n)"; bad=1 ;; esac
    case "$value" in [[:blank:]]*|*[[:blank:]]) pf_bad "$name has leading or trailing whitespace (line $n)"; bad=1 ;; esac
    case "$value" in '"'*|"'"*) pf_bad "$name starts with a quote (line $n)"; bad=1 ;; esac
    case "$value" in *' #'*|*'$'*|*'`'*) pf_bad "$name contains a space-hash comment, a dollar sign or a backtick (line $n)"; bad=1 ;; esac
    case "$seen" in
      *" $name "*)
        case "$dups" in
          *" $name "*) ;;
          *) pf_bad "$name is set more than once"; bad=1; dups="$dups$name " ;;
        esac ;;
      *) seen="$seen$name " ;;
    esac
  done < "$f"
  if [ "$bad" -eq 0 ]; then pf_ok "$f has only NAME=value lines, each name once"; fi
  return "$bad"
}

preflight() {  # preflight <mainnet env file> <stage env file>
  local m="$1" s="$2" n mv sv mode
  PF_FAIL=0

  if [ ! -f "$m" ]; then pf_bad "$m does not exist"; return 1; fi
  if [ ! -f "$s" ]; then pf_bad "$s does not exist"; return 1; fi
  pf_ok "$m and $s exist"

  # Not readable by the group either: the last TWO digits of the mode must be 00.
  mode=$(stat -c %a "$m")
  if [ "${mode: -2}" = "00" ]; then
    pf_ok "$m is not readable by other users or its group"
  else
    pf_bad "$m is readable by other users or its group (mode $mode): run chmod 600 $m"
  fi

  # Before every other check on this file: they read it by name, and a line they would skip is a line
  # this refuses. Its failures set PF_FAIL, so its own status is not needed here.
  pf_lint "$m" || true

  local missing=0
  for n in $PF_REQUIRED; do
    if [ -z "$(pf_get "$m" "$n")" ]; then pf_bad "$n is empty or missing in $m"; missing=1; fi
  done
  [ "$missing" -eq 0 ] && pf_ok "every required setting is set"

  [ "$(pf_get "$m" TRONGRID_URL)" = "https://api.trongrid.io" ] \
    && pf_ok "TronGrid is mainnet's" || pf_bad "TRONGRID_URL is not https://api.trongrid.io"
  [ "$(pf_get "$m" USDT_CONTRACT)" = "$MAINNET_USDT" ] \
    && pf_ok "the USDT contract is mainnet's" || pf_bad "USDT_CONTRACT is not the mainnet USDT contract"

  mv=$(pf_get "$m" GASFREE_NETWORK)
  if [ -n "$mv" ] && [ "$mv" != "mainnet" ]; then
    pf_bad "GASFREE_NETWORK is set and is not mainnet"
  else
    pf_ok "GasFree is off or on mainnet"
  fi

  local same=0
  for n in $PF_DIFFER; do
    mv=$(pf_get "$m" "$n")
    sv=$(pf_get_stage "$s" "$n")
    if [ "$n" = DEPOSIT_MNEMONIC ]; then  # tron-signer reads any run of whitespace as one space
      mv=$(printf '%s' "$mv" | tr -s '[:space:]' ' ')
      sv=$(printf '%s' "$sv" | tr -s '[:space:]' ' ')
    fi
    if [ -n "$mv" ] && [ "$mv" = "$sv" ]; then
      pf_bad "$n is the same in both files (never share secrets between .env and .env.mainnet)"
      same=1
    fi
  done
  [ "$same" -eq 0 ] && pf_ok "no secret is shared with the stage file"

  # The stage hub's own JWT secret is JWT_SECRET in .env: the mainnet orchestrator must not trust it.
  mv=$(pf_get "$m" JWT_SECRET)
  sv=$(pf_get_stage "$s" MAINNET_JWT_SECRET)
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
