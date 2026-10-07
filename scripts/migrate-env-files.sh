#!/usr/bin/env bash
#
# One env file per network, once: the host's old .env becomes .env.testnet, and the mainnet keys it
# held move into .env.mainnet, which until now held only the mainnet treasury's settings.
#
#   before   .env           testnet + shared settings + the mainnet validators', hub's and explorer's keys
#            .env.mainnet   the mainnet treasury
#   after    .env.testnet   testnet (the stage stack: chain, hub, explorer, treasury, monitoring)
#            .env.mainnet   all of mainnet (validators, hub, explorer, treasury)
#
# deploy-stage.sh runs it first, so the deploy that ships it is the one that splits the files. It is a
# no-op once .env.testnet exists and .env does not.
#
# What moves, by name (values are never printed; the deploy log is public):
#   MAINNET_NODE1..3_AUTHOR_SECRET, MAINNET_EXPLORER_POSTGRES_PASSWORD, MAINNET_ALLOWED_ORIGINS
#                       moved as they are
#   MAINNET_JWT_SECRET  becomes JWT_SECRET, which .env.mainnet already has and the mainnet hub now
#                       reads; refused if the two differ (the preflight required them equal)
#   SEQ_API_KEY         copied: Seq is shared, and the mainnet services log to it too
# Any other MAINNET_ name in .env is refused rather than guessed at.
#
# Nothing is written until it is proven that the split changes nothing: the stage, mainnet and
# mainnet treasury projects must render exactly the same from the new files as from the old ones,
# every service and every field. Then the two old files are copied to
# backups/env-split-<time>/ (mode 700), .env.mainnet is rewritten in place, .env.testnet is written,
# and .env moves into that backup folder.

set -euo pipefail
cd "$(dirname "$0")/.."

# shellcheck source=lib/mainnet-preflight.sh
. scripts/lib/mainnet-preflight.sh

OLD=.env
T=.env.testnet
M=.env.mainnet
MOVE="MAINNET_NODE1_AUTHOR_SECRET MAINNET_NODE2_AUTHOR_SECRET MAINNET_NODE3_AUTHOR_SECRET MAINNET_EXPLORER_POSTGRES_PASSWORD MAINNET_ALLOWED_ORIGINS"
MOVED_RE='^(MAINNET_NODE[123]_AUTHOR_SECRET|MAINNET_JWT_SECRET|MAINNET_EXPLORER_POSTGRES_PASSWORD|MAINNET_ALLOWED_ORIGINS)='

die() { echo "ENV SPLIT ABORTED: $*"; echo "Nothing was changed: .env and .env.mainnet are as they were."; exit 1; }

if [ ! -e "$OLD" ]; then
  if [ -f "$T" ]; then echo "env files: already split (.env.testnet and .env.mainnet)"; exit 0; fi
  echo "env files: neither .env nor .env.testnet exists here; nothing to split"
  exit 0
fi
[ -e "$T" ] && die "both .env and .env.testnet exist. Merge them by hand into .env.testnet and remove .env."

# A value read the way compose reads it, then refused unless it can be written as a plain line, which
# is what .env.mainnet allows (pf_lint). Returns 1 for one that cannot.
plain_value() {  # plain_value <name>  (from .env)
  local v
  v=$(pf_get_stage "$OLD" "$1")
  case "$v" in
    *'$'*|*'`'*|*'"'*|*"'"*|*' #'*|[[:blank:]]*|*[[:blank:]]) return 1 ;;
  esac
  printf '%s' "$v"
}

unknown=$(grep -oE '^MAINNET_[A-Z0-9_]+=' "$OLD" | tr -d '=' | grep -vxE 'MAINNET_NODE[123]_AUTHOR_SECRET|MAINNET_JWT_SECRET|MAINNET_EXPLORER_POSTGRES_PASSWORD|MAINNET_ALLOWED_ORIGINS' || true)
[ -z "$unknown" ] || die "unexpected mainnet setting(s) in .env, not moved automatically: $(echo $unknown)"

has_mainnet=$(grep -cE "$MOVED_RE" "$OLD" || true)
if [ "$has_mainnet" -gt 0 ] && [ ! -f "$M" ]; then
  die ".env holds mainnet keys but there is no .env.mainnet to move them into"
fi

WORK=$(mktemp -d)
chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT
NEW_T="$WORK/testnet"
NEW_M="$WORK/mainnet"

grep -vE "$MOVED_RE" "$OLD" > "$NEW_T" || true
chmod 600 "$NEW_T"

moved=""
if [ -f "$M" ]; then
  cp "$M" "$NEW_M"
  chmod 600 "$NEW_M"
  # The file may not end in a newline; an append must not join two lines.
  [ -z "$(tail -c1 "$NEW_M")" ] || echo >> "$NEW_M"
  add() {  # add <name> <value>: append, or require the value already there to be the same
    local cur
    cur=$(pf_get "$NEW_M" "$1")
    if [ -z "$cur" ]; then
      if grep -qE "^$1=" "$NEW_M"; then
        sed -i "/^$1=/d" "$NEW_M"
      fi
      printf '%s=%s\n' "$1" "$2" >> "$NEW_M"
      moved="$moved $1"
    elif [ "$cur" != "$2" ]; then
      die "$1 is set in both files with different values; decide which is right and fix one by hand"
    fi
  }
  if [ "$has_mainnet" -gt 0 ]; then
    printf '\n# Mainnet chain and apps: moved here from .env by migrate-env-files.sh on %s.\n' "$(date -u +%Y-%m-%d)" >> "$NEW_M"
  fi
  for n in $MOVE MAINNET_JWT_SECRET SEQ_API_KEY; do
    v=$(plain_value "$n") || die "$n in .env is not a plain value (quotes, a \$, a backtick, a space-hash or blanks at an end); move it by hand"
    [ -n "$v" ] || continue
    case "$n" in
      MAINNET_JWT_SECRET) add JWT_SECRET "$v" ;;
      *) add "$n" "$v" ;;
    esac
  done

  PF_FAIL=0
  pf_lint "$NEW_M" >/dev/null || die "the new .env.mainnet would not pass the preflight's line check (run the preflight to see which line)"
fi

# --- prove the split changes nothing --------------------------------------------------------------
# Each project is rendered twice with the compose files of this checkout: once the way it read its
# settings until now, once from the new file. The two must be the same, every service and every
# field. Comparing renders rather than running containers keeps a compose change that is merely not
# deployed yet (a mainnet pin, a new setting) from stopping the split; that change is not the split's.
render() {  # render <out> <env file> <compose arguments...>
  local out="$1" f="$2"; shift 2
  docker compose --env-file "$f" "$@" config --format json > "$out" 2>/dev/null
}
same() {  # same <label> <old env file> <new env file> <compose arguments...>
  local label="$1" old="$2" new="$3"; shift 3
  render "$WORK/new.json" "$new" "$@" \
    || die "$label does not render with the new env file (run 'docker compose config' on the host to see why)"
  if ! render "$WORK/old.json" "$old" "$@"; then
    echo "    $label: did not render before the split, not compared"
    return 0
  fi
  python3 - "$label" "$WORK/old.json" "$WORK/new.json" <<'PYEOF' || die "$label would get a different setting (above)"
import json, sys
label, old, new = sys.argv[1], json.load(open(sys.argv[2])), json.load(open(sys.argv[3]))
bad = 0
for svc in sorted(set(old.get("services", {})) | set(new.get("services", {}))):
    o, n = old["services"].get(svc), new["services"].get(svc)
    if o == n:
        continue
    bad = 1
    if o is None or n is None:
        print(f"    {label}/{svc}: DIFFERENT: the service itself")
        continue
    oe, ne = o.get("environment") or {}, n.get("environment") or {}
    keys = sorted(k for k in set(oe) | set(ne) if oe.get(k) != ne.get(k))
    fields = sorted(k for k in set(o) | set(n) if o.get(k) != n.get(k))
    print(f"    {label}/{svc}: DIFFERENT: {' '.join(keys or fields)}")
for k in sorted(set(old) | set(new)):
    if k != "services" and old.get(k) != new.get(k):
        bad = 1
        print(f"    {label}: DIFFERENT: {k}")
if not bad:
    print(f"    {label}: same")
sys.exit(bad)
PYEOF
}

echo "=== env split: comparing each project's settings before and after ==="
# Until now compose read .env by default for the stage and the mainnet chain projects.
same clutch-stage "$OLD" "$NEW_T" -p clutch-stage -f docker-compose.yml -f docker-compose.treasury.yml \
  -f docker-compose.stage.cloudflare-flex.yml -f docker-compose.stage.treasury.yml
if [ -f "$M" ]; then
  # The mainnet hub read MAINNET_JWT_SECRET from .env, and this checkout's compose file names
  # JWT_SECRET, so "before" is .env with that one name swapped in, its value and quoting untouched.
  { grep -vE '^(JWT_SECRET|MAINNET_JWT_SECRET)=' "$OLD" || true
    sed -n 's/^MAINNET_JWT_SECRET=/JWT_SECRET=/p' "$OLD"; } > "$WORK/old-main"
  same clutch-main "$WORK/old-main" "$NEW_M" -p clutch-main -f docker-compose.mainnet.yml
  same clutch-main-treasury "$M" "$NEW_M" -p clutch-main-treasury -f docker-compose.mainnet.treasury.yml
fi

# --- write ----------------------------------------------------------------------------------------
BK="backups/env-split-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$BK"
chmod 700 backups "$BK" 2>/dev/null || chmod 700 "$BK"
[ -f "$M" ] && cp -p "$M" "$BK/.env.mainnet"
if [ -f "$M" ]; then
  # In place, so the file keeps its owner and its mode 600.
  cat "$NEW_M" > "$M"
fi
cp "$NEW_T" "$T"
chmod 600 "$T"
mv "$OLD" "$BK/.env"

echo "=== env split: done ==="
echo "    .env.testnet written from .env, without the mainnet keys"
[ -f "$M" ] && echo "    .env.mainnet gained:${moved:- nothing (it already had them)}"
echo "    the old .env and .env.mainnet are in $BK (mode 700); delete that folder once mainnet has restarted cleanly"
