#!/usr/bin/env bash
#
# Give the clutch vhost's nginx config an owner.
#
# Readiness item G1. The file serving stage belongs to the `v2ray` compose project and is
# hand-maintained on the host; `config/nginx/*.conf` in this repo is mounted nowhere, so every
# clutch route lives in a file no repository owns.
#
# HOW, AND WHY NOT AN INCLUDE
#
# The obvious design is `include /etc/nginx/clutch.d/*.conf;` with the directory synced from this
# repo. That was tried and shipped on 2026-09-13, and it cannot work here: the nginx container
# bind-mounts exactly ONE path, the single file at /etc/nginx/nginx.conf. No host directory is
# visible inside it, so the include resolved against the container's own filesystem where the
# directory does not exist. A glob matching nothing is valid nginx, so it passed `nginx -t`,
# reloaded cleanly, and would have silently loaded nothing forever. Adding the mount means editing
# another project's compose file, which is not ours to change.
#
# So the repo owns the CONTENT and this script injects it, between markers, into the file that is
# actually mounted:
#
#     # >>> clutch-deploy managed block >>>
#     ...concatenated config/nginx/clutch.d/*.conf...
#     # <<< clutch-deploy managed block <<<
#
# Everything outside the markers is v2ray's and is never touched. Everything inside is replaced
# wholesale on every deploy, so a file deleted from the repo disappears from the host rather than
# lingering as a route nobody can find in a diff.
#
# Idempotent, and safe to run on every deploy.
#
# Usage: bash scripts/ensure-nginx-clutch-include.sh [container]
#
# Env:
#   DRY_RUN=1        build the patched config, print the block, touch nothing
#   CONF_OVERRIDE=p  patch p instead of reading the path off the container mount (for tests)
#   SKIP_NGINX=1     skip docker/nginx entirely (for tests against a plain file)

set -euo pipefail

CONTAINER="${1:-nginx-stage}"
VHOST="${VHOST:-app-stage.clutchprotocol.io}"
REPO_DIR="${REPO_DIR:-config/nginx/clutch.d}"

BEGIN_MARK="        # >>> clutch-deploy managed block (config/nginx/clutch.d) >>>"
END_MARK="        # <<< clutch-deploy managed block <<<"

log() { echo "nginx-block: $*"; }
die() { echo "nginx-block: FAILED: $*" >&2; exit 1; }

# Every server_name in the file, sorted. Compared before and after: this config serves vhosts that
# are not ours -- 13 of them as of 2026-09-13 -- and the deploy's own health gate only reaches a
# clutch route. Losing somebody else's vhost while ours still answers is the failure that would go
# unnoticed.
# Not anchored to the start of a line: nginx allows a whole server block on one line, and an
# anchored pattern silently misses those -- so a vhost written that way could vanish without the
# guard noticing, which is the one thing the guard exists to prevent. Matching anywhere can also
# pick up a server_name inside a comment, which is harmless: it appears in both the before and the
# after set and cancels out.
server_names() {
  grep -hoE 'server_name[[:space:]]+[^;]+;' "$1" \
    | sed -e 's/^server_name[[:space:]]*//' -e 's/;$//' \
    | tr ' ' '\n' | sed '/^$/d' | sort -u
}

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
[ -d "$REPO_DIR" ] || die "$REPO_DIR is missing from this checkout"

BEFORE_NAMES=$(server_names "$CONF")
[ -n "$BEFORE_NAMES" ] || die "no server_name found in $CONF — refusing to edit a file I cannot read"

# ---------------------------------------------------------------------------
# Build the block from the repo.
# ---------------------------------------------------------------------------
BLOCK=$(mktemp); TMP=$(mktemp)
trap 'rm -f "$BLOCK" "$TMP"' EXIT

# nullglob so an empty directory yields an empty array rather than a literal glob. Set BEFORE the
# block and restored after: left on, it also turns an unmatched glob elsewhere into nothing, which
# once made `ls -1 $REPO_DIR/*.conf | wc -l` list the working directory and report 14 route files
# when there were none.
shopt -s nullglob
files=("$REPO_DIR"/*.conf)
shopt -u nullglob

{
  echo "$BEGIN_MARK"
  echo "        # Generated on each deploy from $REPO_DIR. Edits here are overwritten."
  if [ ${#files[@]} -eq 0 ]; then
    echo "        # (no route files in the repo yet)"
  else
    for f in "${files[@]}"; do
      echo "        # --- $(basename "$f") ---"
      sed 's/^/        /' "$f"
    done
  fi
  echo "$END_MARK"
} > "$BLOCK"
log "built block from ${#files[@]} route file(s)"

# ---------------------------------------------------------------------------
# Replace the existing block, or insert one after the vhost's server_name.
#
# Also drops the dead `include /etc/nginx/clutch.d/*.conf;` line from the first, broken attempt at
# this. It pointed at a path that does not exist inside the container and loaded nothing.
# ---------------------------------------------------------------------------
if grep -qF "${BEGIN_MARK#        }" "$CONF"; then
  log "managed block present — replacing its contents"
  awk -v blockfile="$BLOCK" '
    index($0, "# >>> clutch-deploy managed block") { inblock = 1; while ((getline line < blockfile) > 0) print line; close(blockfile); next }
    index($0, "# <<< clutch-deploy managed block") { inblock = 0; next }
    !inblock { print }
  ' "$CONF" > "$TMP" || die "could not rewrite the managed block"
else
  grep -q "server_name[[:space:]]\+${VHOST};" "$CONF" \
    || die "no '$VHOST' server block in $CONF — refusing to guess where the block belongs"
  log "no managed block yet — inserting one"
  awk -v vhost="$VHOST" -v blockfile="$BLOCK" '
    $0 ~ "^[[:space:]]*server_name[[:space:]]+" vhost ";" && !ins {
      print; print ""
      while ((getline line < blockfile) > 0) print line
      close(blockfile)
      ins = 1
      next
    }
    { print }
    END { if (!ins) exit 3 }
  ' "$CONF" > "$TMP" || die "awk could not find the $VHOST anchor — config untouched"
fi

# Remove the dead include from the earlier attempt, wherever it sits.
grep -v 'include[[:space:]]\+/etc/nginx/clutch\.d/\*\.conf;' "$TMP" > "$TMP.clean" && mv "$TMP.clean" "$TMP"

# ---------------------------------------------------------------------------
# Retire the legacy inline /payment/ block, but ONLY once the repo provides that route.
#
# Two mechanisms that can both write the same location is how you get a duplicate `location` and a
# config nginx refuses. The condition is therefore the repo's content, not a date or a flag: strip
# the old block exactly when the managed block carries a replacement, so the route is never absent
# from the file even for one line of it.
#
# Bounded on purpose. If the marker comment survives but its block does not, unbounded brace
# counting would eat whatever came next. 40 lines is far more than the block has ever been, and
# overrunning it aborts rather than guesses.
# ---------------------------------------------------------------------------
if grep -q 'location /payment/' "$BLOCK"; then
  LEGACY='# Added by clutch-deploy (scripts/ensure-nginx-payment-route.sh).'
  if grep -qF "$LEGACY" "$TMP"; then
    log "repo owns /payment/ now — removing the legacy inline block"
    awk -v marker="$LEGACY" -v budget=40 '
      index($0, marker) && !dropping { dropping = 1; depth = 0; seen = 0; used = 0; next }
      dropping {
        used++
        if (used > budget) { print "OVERRUN" > "/dev/stderr"; exit 4 }
        opens = gsub(/{/, "{"); closes = gsub(/}/, "}")
        depth += opens - closes
        if (opens > 0) seen = 1
        if (seen && depth <= 0) dropping = 0
        next
      }
      { print }
    ' "$TMP" > "$TMP.stripped" || die "legacy /payment/ block did not close within 40 lines — nothing written"
    mv "$TMP.stripped" "$TMP"

    # Exactly one must remain, and it must be the managed one.
    count=$(grep -c 'location /payment/' "$TMP" || true)
    [ "$count" = "1" ] || die "expected exactly 1 /payment/ location after the move, found $count"
    log "one /payment/ location remains, inside the managed block"
  fi
fi

if [ -n "${DRY_RUN:-}" ]; then
  log "DRY_RUN — managed block as it would be written:"
  sed -n '/>>> clutch-deploy managed block/,/<<< clutch-deploy managed block/p' "$TMP"
  exit 0
fi

# The guard runs on the candidate, BEFORE anything is written: a config can be syntactically
# perfect and have quietly lost a server block.
AFTER_NAMES=$(server_names "$TMP")
if [ "$BEFORE_NAMES" != "$AFTER_NAMES" ]; then
  echo "--- before ---"; echo "$BEFORE_NAMES"
  echo "--- after ----"; echo "$AFTER_NAMES"
  die "the patched config changes which vhosts exist — nothing written"
fi
log "server_name set unchanged ($(echo "$BEFORE_NAMES" | wc -l) names)"

cp "$CONF" "$CONF.clutch-block.bak"
# cat, NOT mv: docker bind-mounts a single file by inode, and mv would give the path a new one
# while the container kept serving the old content forever.
cat "$TMP" > "$CONF"

if [ -n "${SKIP_NGINX:-}" ]; then
  log "SKIP_NGINX — written, not validated or reloaded"
  exit 0
fi

if docker exec "$CONTAINER" nginx -t; then
  log "config valid"
else
  log "config INVALID — restoring backup"
  cat "$CONF.clutch-block.bak" > "$CONF"
  die "nginx -t rejected the config with the managed block in place"
fi

docker exec "$CONTAINER" nginx -s reload
log "reloaded"
