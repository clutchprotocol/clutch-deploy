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
#   - a mint key that is not 64 hex characters, or whose recorded address (MINT_AUTHORITY_ADDRESS) is not
#     the `mint_authority` of the node configs. The key is a plain secret on this host since 2026-10-05
#     (readiness A1, "Mint key on the host"), made together with its address by mainnet-mint-key.sh.
#     A key that is not the chain's mint authority mints nothing: the treasury would halt itself at
#     start. This cannot prove the secret derives the address (no tool here does that); the treasury's
#     own check against the chain does, and the key and the address are written in one step.

MAINNET_USDT=TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t

# Every setting the mainnet compose file requires with `:?` or that the money path cannot run without,
# and BACKUP_PASSPHRASE: backup-treasury-db.sh aborts without it, so a treasury that started would have
# no backup the first night.
PF_REQUIRED="CUSTODY_TRON_ADDRESS TRONGRID_URL USDT_CONTRACT MINT_AUTHORITY_SECRET MINT_AUTHORITY_ADDRESS DEPOSIT_MNEMONIC DEPOSIT_ACCOUNT_XPUB PAYOUT_FLOAT_ADDRESS SIGNER_TOKEN TREASURY_INITIATOR_TOKEN TREASURY_APPROVER_TOKEN TREASURY_READONLY_TOKEN TREASURY_POSTGRES_PASSWORD ORCHESTRATOR_POSTGRES_PASSWORD JWT_SECRET PER_TX_MINT_CAP_CLT DAILY_MINT_CAP_CLT MAX_REDEMPTION_CLT MIN_REDEMPTION_CLT PER_TX_PAYOUT_CAP_USDT REDEMPTION_FEE_USDT DAILY_PAYOUT_CAP_CLT BACKUP_PASSPHRASE PILOT_ALLOWED_ADDRESSES"

# Settings that must differ between the two files.
PF_DIFFER="MINT_AUTHORITY_SECRET DEPOSIT_MNEMONIC DEPOSIT_ACCOUNT_XPUB CUSTODY_TRON_ADDRESS PAYOUT_FLOAT_ADDRESS SIGNER_TOKEN TREASURY_INITIATOR_TOKEN TREASURY_APPROVER_TOKEN TREASURY_READONLY_TOKEN TREASURY_POSTGRES_PASSWORD ORCHESTRATOR_POSTGRES_PASSWORD JWT_SECRET BACKUP_PASSPHRASE BACKUP_REMOTE"

pf_ok()  { printf 'OK    %s\n' "$1"; }
pf_bad() { printf 'FAIL  %s\n' "$1"; PF_FAIL=1; }

# The MAINNET file, plain text: pf_lint has refused everything that is not plain (a leading quote, a CR,
# blanks at the ends), so the value is exactly what follows the first `=`. Nothing is stripped: compose
# keeps a trailing quote, so a secret that ends in one must stay different from the same secret without
# it. First match wins. Empty when the name is absent: `|| true`, because a grep that matches nothing
# must not end a script that runs under `set -e`.
pf_get() {  # pf_get <file> <name>
  { grep -E "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2-; } || true
}

# The STAGE file, read the way compose reads it, because a secret copied by hand is the same secret to
# compose even when its text differs: the LAST of a duplicated name wins, a trailing CR and the spaces
# and tabs around the value go, a value that starts with a quote stops at the next quote of the same kind
# (so a comment after it goes too), and an unquoted value stops at a space followed by #. The stage file
# is not linted (it holds many other settings); this only reads it. Prints the value, or nothing.
pf_get_stage() {  # pf_get_stage <file> <name>
  local v q cr=$'\r'
  v=$(grep -E "^$2=" "$1" 2>/dev/null | tail -n 1) || true
  v="${v#*=}"
  v="${v%"$cr"}"
  v="${v#"${v%%[![:blank:]]*}"}"
  v="${v%"${v##*[![:blank:]]}"}"
  case "$v" in
    '"'*|"'"*) q="${v:0:1}"; v="${v#?}"; v="${v%%"$q"*}" ;;
    *' #'*) v="${v%% #*}"; v="${v%"${v##*[![:blank:]]}"}" ;;
  esac
  printf '%s' "$v"
}

# The MAINNET file, line by line. Every line must be blank (spaces and tabs only), a comment (# in
# column 1) or NAME=value, and a name may be set once. A name is UPPER case, on purpose: a secret pasted
# on a line of its own (padded base64, say) has an `=` in it, and its text before the `=` is mixed case.
# That line must be refused as "not NAME=value", and the text before the `=` must not be printed as if it
# were a name. A value must be plain, because compose and the services read it more loosely than its
# text says: they drop a carriage return and the spaces around it, take quotes off, cut a " #" comment,
# expand a dollar sign and take the LAST of a duplicated name. A stray line is refused too: `docker
# compose config` prints the line it cannot parse, and the log of the workflow is public. Prints line
# numbers and names only, never a line or a value. Returns 1 when it refused something, and sets
# PF_FAIL through pf_bad like every other check, so it works on its own.
pf_lint() {  # pf_lint <file>
  local f="$1" line="" name value n=0 bad=0 seen=" " dups=" " cr=$'\r'
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    if [ -z "${line//[[:blank:]]/}" ]; then continue; fi
    case "$line" in '#'*) continue ;; esac
    name=""; value=""
    case "$line" in *=*) name="${line%%=*}"; value="${line#*=}" ;; esac
    case "$name" in
      ''|[!A-Z_]*|*[!A-Z0-9_]*)
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

preflight() {  # preflight <mainnet env file> <stage env file> [<node config>, default config/node-mainnet/node1.toml]
  local m="$1" s="$2" nodecfg="${3:-config/node-mainnet/node1.toml}" n mv sv mode
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
    if [ "$n" = DEPOSIT_MNEMONIC ]; then  # tron-signer reads any run of whitespace as one space, and trims the ends
      mv=$(printf '%s' "$mv" | tr -s '[:space:]' ' '); mv="${mv# }"; mv="${mv% }"
      sv=$(printf '%s' "$sv" | tr -s '[:space:]' ' '); sv="${sv# }"; sv="${sv% }"
    fi
    if [ -n "$mv" ] && [ "$mv" = "$sv" ]; then
      pf_bad "$n is the same in both files (never share secrets between .env.testnet and .env.mainnet)"
      same=1
    fi
  done
  [ "$same" -eq 0 ] && pf_ok "no secret is shared with the stage file"

  # Who may use mainnet while it is a pilot: `*` (everyone, and only because someone typed it) or a
  # comma-separated list of addresses, each 0x and 40 hex characters, with no spaces. The orchestrator
  # treats a blank list as nobody, so a typo cannot open the service. It can lock the maintainer out, or
  # leave out an address that was meant to be in, so a malformed list is refused here and not guessed at.
  # Only a count is printed: the log of the workflow that runs this is public.
  mv=$(pf_get "$m" PILOT_ALLOWED_ADDRESSES)
  if [ -z "$mv" ]; then
    :  # already reported as missing above
  elif [ "$mv" = "*" ]; then
    pf_ok "PILOT_ALLOWED_ADDRESSES is *: EVERY account may use mainnet through /payment/"
  elif printf '%s' "$mv" | grep -Eq '^0x[0-9a-fA-F]{40}(,0x[0-9a-fA-F]{40})*$'; then
    pf_ok "the pilot allowlist names $(( $(printf '%s' "$mv" | tr -cd ',' | wc -c) + 1 )) address(es)"
  else
    pf_bad "PILOT_ALLOWED_ADDRESSES is neither * nor a comma-separated list of 0x addresses (40 hex characters each, no spaces)"
  fi

  # The mint key: 64 lower-case hex characters, as mainnet-mint-key.sh writes it. The treasury also takes
  # a 0x prefix; this refuses it, so there is one form. Empty or missing is already reported above, so
  # it is not reported twice.
  mv=$(pf_get "$m" MINT_AUTHORITY_SECRET)
  if [ -z "$mv" ]; then
    :
  elif printf '%s' "$mv" | grep -Eq '^[0-9a-f]{64}$'; then
    pf_ok "the mint key is 64 hex characters"
  else
    pf_bad "MINT_AUTHORITY_SECRET is not 64 lower-case hex characters (run \"Mainnet - create the mint key\")"
  fi
  # Its address is the chain's mint_authority, in every node config. Only the first config is read here:
  # check-genesis.sh makes the three agree, and the start refuses when they do not.
  mv=$(pf_get "$m" MINT_AUTHORITY_ADDRESS | tr 'A-F' 'a-f')
  if [ -z "$mv" ]; then
    :
  elif ! printf '%s' "$mv" | grep -Eq '^0x[0-9a-f]{40}$'; then
    pf_bad "MINT_AUTHORITY_ADDRESS is not a 0x address of 40 hex characters"
  elif [ ! -f "$nodecfg" ]; then
    pf_bad "the node config is missing, so the mint address cannot be checked against it"
  else
    sv=$(sed -n 's/^mint_authority = "\(0x[0-9a-fA-F]\{40\}\)".*/\1/p' "$nodecfg" | head -1 | tr 'A-F' 'a-f')
    if [ "$mv" = "$sv" ]; then
      pf_ok "MINT_AUTHORITY_ADDRESS is the mint_authority of the node configs"
    else
      pf_bad "MINT_AUTHORITY_ADDRESS is not the mint_authority in $nodecfg: this key would not be the chain's mint authority"
    fi
  fi

  return "$PF_FAIL"
}
