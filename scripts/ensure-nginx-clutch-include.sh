#!/usr/bin/env bash
#
# Give the clutch vhost's nginx config an owner.
#
# Readiness item G1. The file serving stage belongs to the `v2ray` compose project and is
# hand-maintained on the host; `config/nginx/*.conf` in this repo is not mounted anywhere and
# editing it changes nothing. Every clutch route therefore lives in a file no repository owns, and
# the only way to change one has been to patch that file in place on each deploy.
#
# This replaces patching with an include. One line goes into the clutch vhost:
#
#     include /etc/nginx/clutch.d/*.conf;
#
# and the directory behind it is synced from `config/nginx/clutch.d/` in this repo. After that,
# clutch routes are repo-owned, reviewable and diffable, and v2ray's own vhosts are untouched by
# anything clutch does.
#
# The include is a GLOB on purpose: nginx errors on an `include` naming a file that does not
# exist, but a glob matching nothing is fine. So the include can be added before the directory has
# any content, and the two steps do not have to be atomic.
#
# Idempotent, and safe to run on every deploy.
#
# Usage: bash scripts/ensure-nginx-clutch-include.sh [container]
#
# Env:
#   DRY_RUN=1        patch a copy, print the result, touch nothing
#   CONF_OVERRIDE=p  patch p instead of reading the path off the container mount (for tests)
#   SKIP_NGINX=1     skip docker/nginx entirely (for tests against a plain file)

set -euo pipefail

CONTAINER="${1:-nginx-stage}"
VHOST="${VHOST:-app-stage.clutchprotocol.io}"
INCLUDE_DIR="${INCLUDE_DIR:-/etc/nginx/clutch.d}"
REPO_DIR="${REPO_DIR:-config/nginx/clutch.d}"

log() { echo "nginx-include: $*"; }
die() { echo "nginx-include: FAILED: $*" >&2; exit 1; }

# Every server_name in the file, sorted. Compared before and after: this config serves vhosts that
# are not ours, and the deploy's own health gate only checks a clutch route. Losing somebody else's
# vhost while ours still answers is exactly the failure that would go unnoticed.
server_names() {
  grep -hoE '^[[:space:]]*server_name[[:space:]]+[^;]+;' "$1" \
    | sed -e 's/^[[:space:]]*server_name[[:space:]]*//' -e 's/;$//' \
    | tr ' ' '\n' | sed '/^$/d' | sort -u
}

# ---------------------------------------------------------------------------
# Locate the config actually being served.
# ---------------------------------------------------------------------------
if [ -n "${CONF_OVERRIDE:-}" ]; then
  CONF="$CONF_OVERRIDE"
  log "using CONF_OVERRIDE=$CONF"
else
  docker inspect "$CONTAINER" >/dev/null 2>&1 || die "no container named $CONTAINER"
  CONF=$(docker inspect "$CONTAINER" \
    --format '{{range .Mounts}}{{if eq .Destination "/etc/nginx/nginx.conf"}}{{.Source}}{{end}}{{end}}')
  [ -n "$CONF" ] || die "$CONTAINER has no bind mount at /etc/nginx/nginx.conf"
  log "container=$CONTAINER conf=$CONF"
fi

[ -f "$CONF" ] || die "$CONF does not exist"
[ -r "$CONF" ] || die "$CONF is not readable"

BEFORE_NAMES=$(server_names "$CONF")
[ -n "$BEFORE_NAMES" ] || die "no server_name found in $CONF — refusing to edit a file I cannot read"

# ---------------------------------------------------------------------------
# Sync the repo-owned directory onto the host, next to the config that includes it.
# ---------------------------------------------------------------------------
if [ -z "${SKIP_NGINX:-}" ]; then
  [ -d "$REPO_DIR" ] || die "$REPO_DIR is missing from this checkout"
  HOST_DIR="$(dirname "$CONF")/clutch.d"
  mkdir -p "$HOST_DIR"
  # Copy contents rather than the directory, so a file deleted from the repo is not left behind on
  # the host serving a route nobody can see in a diff.
  rm -f "$HOST_DIR"/*.conf
  cp "$REPO_DIR"/*.conf "$HOST_DIR"/ 2>/dev/null || log "no .conf files in $REPO_DIR yet"
  log "synced $(ls -1 "$HOST_DIR"/*.conf 2>/dev/null | wc -l) file(s) to $HOST_DIR"
fi

# ---------------------------------------------------------------------------
# Add the include, once.
# ---------------------------------------------------------------------------
if grep -q "include[[:space:]]\+${INCLUDE_DIR}/\*\.conf;" "$CONF"; then
  log "include already present"
else
  grep -q "server_name[[:space:]]\+${VHOST};" "$CONF" \
    || die "no '$VHOST' server block in $CONF — refusing to guess where the include belongs"

  TMP=$(mktemp)
  trap 'rm -f "$TMP"' EXIT

  awk -v vhost="$VHOST" -v dir="$INCLUDE_DIR" '
    $0 ~ "^[[:space:]]*server_name[[:space:]]+" vhost ";" && !ins {
      print
      print ""
      print "        # Added by clutch-deploy (scripts/ensure-nginx-clutch-include.sh)."
      print "        # Clutch routes live in files this repo owns, synced on each deploy."
      print "        # A glob include matching nothing is valid nginx, so this line is safe"
      print "        # even when the directory is empty."
      print "        include " dir "/*.conf;"
      ins = 1
      next
    }
    { print }
    END { if (!ins) exit 3 }
  ' "$CONF" > "$TMP" || die "awk could not find the $VHOST anchor — config untouched"

  if [ -n "${DRY_RUN:-}" ]; then
    log "DRY_RUN — patched result around the anchor:"
    grep -n -B2 -A6 "include ${INCLUDE_DIR}" "$TMP"
    exit 0
  fi

  cp "$CONF" "$CONF.clutch-include.bak"
  # cat, NOT mv: docker bind-mounts a single file by inode, and mv would give the path a new one
  # while the container kept serving the old content forever.
  cat "$TMP" > "$CONF"
  log "added include ${INCLUDE_DIR}/*.conf to the $VHOST vhost"
fi

# ---------------------------------------------------------------------------
# The neighbour's vhosts must survive. Checked before nginx -t, because a config that is
# syntactically valid and has silently lost a server block would otherwise pass.
# ---------------------------------------------------------------------------
AFTER_NAMES=$(server_names "$CONF")
if [ "$BEFORE_NAMES" != "$AFTER_NAMES" ]; then
  log "server_name set CHANGED — restoring backup"
  [ -f "$CONF.clutch-include.bak" ] && cat "$CONF.clutch-include.bak" > "$CONF"
  echo "--- before ---"; echo "$BEFORE_NAMES"
  echo "--- after ----"; echo "$AFTER_NAMES"
  die "this file serves vhosts that are not ours; refusing to change which ones exist"
fi
log "server_name set unchanged ($(echo "$BEFORE_NAMES" | wc -l) names)"

if [ -n "${SKIP_NGINX:-}" ]; then
  log "SKIP_NGINX — not validating or reloading"
  exit 0
fi

if docker exec "$CONTAINER" nginx -t; then
  log "config valid"
else
  log "config INVALID — restoring backup"
  [ -f "$CONF.clutch-include.bak" ] && cat "$CONF.clutch-include.bak" > "$CONF"
  die "nginx -t rejected the config with the include in place"
fi

docker exec "$CONTAINER" nginx -s reload
log "reloaded"
