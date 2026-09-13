#!/usr/bin/env bash
#
# Give the clutch vhosts' nginx config an owner.
#
# Readiness item G1. The file serving stage belongs to the `v2ray` compose project and is
# hand-maintained on the host; `config/nginx/*.conf` in this repo is mounted nowhere, so every
# clutch route lived in a file no repository owned.
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
# actually mounted.
#
# ONE BLOCK PER VHOST
#
# The clutch routes are spread across several server blocks in that file -- the demo app, the Hub
# API, the explorer and the three nodes. One managed block cannot cover them: a block lands inside
# exactly one server block, and a `location` is only reachable from the server it sits in.
#
# So the repo directory is one subdirectory per vhost, named for the vhost:
#
#     config/nginx/clutch.d/app-stage.clutchprotocol.io/payment.conf
#     config/nginx/clutch.d/api-stage.clutchprotocol.io/hub-api.conf
#
# and each gets its own block, anchored at that vhost's `server_name`:
#
#     # >>> clutch-deploy managed block (api-stage.clutchprotocol.io) >>>
#     ...concatenated config/nginx/clutch.d/api-stage.clutchprotocol.io/*.conf...
#     # <<< clutch-deploy managed block <<<
#
# Every managed block is deleted and rebuilt on each run rather than edited in place. That is one
# code path instead of a replace path and an insert path, and it means a file -- or a whole vhost
# -- removed from the repo disappears from the host rather than lingering as a route nobody can
# find in a diff. Nothing is written until the entire candidate file is built and has passed the
# guards, so a vhost is never momentarily without its routes on disk.
#
# Everything outside the markers is v2ray's and is never touched.
#
# Idempotent, and safe to run on every deploy.
#
# Usage: bash scripts/ensure-nginx-clutch-block.sh [container]
#
# Env:
#   DRY_RUN=1        build the patched config, print the blocks, touch nothing
#   CONF_OVERRIDE=p  patch p instead of reading the path off the container mount (for tests)
#   SKIP_NGINX=1     skip docker/nginx entirely (for tests against a plain file)

set -euo pipefail

CONTAINER="${1:-nginx-stage}"
REPO_DIR="${REPO_DIR:-config/nginx/clutch.d}"

# Matched as a prefix when deleting, so it catches every vhost's block AND the single-block marker
# used before this script grew a per-vhost form -- "(config/nginx/clutch.d)" rather than a hostname.
# That older block is on the host today; deleting by prefix migrates it with no special case.
MARK_PREFIX="# >>> clutch-deploy managed block"
END_MARK="        # <<< clutch-deploy managed block <<<"

log() { echo "nginx-block: $*"; }
die() { echo "nginx-block: FAILED: $*" >&2; exit 1; }

# Every server_name in the file, sorted. Compared before and after: this config serves vhosts that
# are not ours -- 14 names as of 2026-09-13 -- and the deploy's own health gate only reaches a
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
# Which vhosts does the repo own?
#
# nullglob so an empty directory yields an empty array rather than a literal glob. Set BEFORE the
# expansion and restored after: left on, it also turns an unmatched glob elsewhere into nothing,
# which once made `ls -1 $REPO_DIR/*.conf | wc -l` list the working directory and report 14 route
# files when there were none.
# ---------------------------------------------------------------------------
shopt -s nullglob
vhost_dirs=("$REPO_DIR"/*/)
stray=("$REPO_DIR"/*.conf)
shopt -u nullglob

# A .conf sitting directly in clutch.d has no vhost, so there is nowhere to put it. Before the
# per-vhost layout that was the only shape, so this is exactly the file someone writes from memory.
# Refusing beats loading it into whichever vhost happens to sort first, and beats ignoring it.
if [ ${#stray[@]} -gt 0 ]; then
  die "${stray[*]} sits directly in $REPO_DIR — route files belong in a <vhost>/ subdirectory"
fi
[ ${#vhost_dirs[@]} -gt 0 ] || die "$REPO_DIR has no <vhost>/ subdirectory — nothing to own"

BLOCK=$(mktemp); TMP=$(mktemp)
trap 'rm -f "$BLOCK" "$TMP"' EXIT

# ---------------------------------------------------------------------------
# Strip every managed block, then insert each vhost's afresh.
#
# Also drops the dead `include /etc/nginx/clutch.d/*.conf;` line from the first, broken attempt at
# this, and the comments that introduced it. It pointed at a path that does not exist inside the
# container and loaded nothing. Dropping the line alone left four orphan comments on the host
# describing a directive that no longer existed -- config nothing accounts for, which is the exact
# drift this item exists to end. Matched on their own text, which is unique to those lines.
# ---------------------------------------------------------------------------
awk -v prefix="$MARK_PREFIX" '
  index($0, prefix) { inblock = 1; next }
  index($0, "# <<< clutch-deploy managed block") { inblock = 0; next }
  !inblock { print }
' "$CONF" > "$TMP" || die "could not strip the existing managed blocks"

grep -v -e 'include[[:space:]]\+/etc/nginx/clutch\.d/\*\.conf;' \
        -e 'Added by clutch-deploy (scripts/ensure-nginx-clutch-include\.sh)\.' \
        -e 'Clutch routes live in files this repo owns, synced on each deploy\.' \
        -e 'A glob include matching nothing is valid nginx, so this line is safe' \
        -e 'even when the directory is empty\.' \
        "$TMP" > "$TMP.clean" && mv "$TMP.clean" "$TMP"

for dir in "${vhost_dirs[@]}"; do
  vhost=$(basename "$dir")
  # Dots are regex wildcards. Unescaped, api-stage.clutchprotocol.io also matches a hostname with
  # any character in those positions -- unlikely to bite, free to rule out.
  vhost_re=${vhost//./\\.}

  shopt -s nullglob
  files=("$dir"*.conf)
  shopt -u nullglob
  [ ${#files[@]} -gt 0 ] || die "$dir has no .conf files — delete the directory rather than leaving an empty block"

  # A route file that closes its server block early turns whatever follows into part of a different
  # one. That can still be valid nginx, so `nginx -t` would not catch it, and the server_name guard
  # would not either -- every name is still in the file, attached to the wrong server.
  #
  # Depth as it goes, not a total: `}` then `server {` balances on the count and is exactly the
  # shape that does the damage. Per character rather than per line for the same reason -- both can
  # sit on one line.
  #
  # Crude enough to object to a `location ~ x{2}` one day. The message says which file.
  for f in "${files[@]}"; do
    awk '
      { for (i = 1; i <= length($0); i++) {
          ch = substr($0, i, 1)
          if (ch == "{") d++
          else if (ch == "}") { d--; if (d < 0) exit 2 }
      } }
      END { if (d != 0) exit 3 }
    ' "$f" || die "$f closes or leaves open a block it did not open or close — route files hold whole location blocks and nothing else"
  done

  # The anchor must exist exactly once. Two server blocks sharing a name (an HTTP one that
  # redirects and a TLS one that serves, say) would take the block into whichever came first, and
  # a route in the redirect block is a route that never runs.
  anchors=$(grep -cE "^[[:space:]]*server_name[[:space:]]+${vhost_re};" "$TMP" || true)
  if [ "$anchors" = "0" ]; then
    # Distinguish "not there" from "there, but in a shape this script must not touch": nginx allows
    # a whole server block on one line, and inserting after that line puts the routes outside the
    # server they were meant for -- valid config, silently wrong.
    if grep -qE "server_name[^;]*${vhost_re}" "$TMP"; then
      die "$vhost's server_name is not on a line of its own (one-line server block, or several names on one line) — this script will not guess where its block belongs"
    fi
    die "no '$vhost' server block in $CONF — refusing to guess where the block belongs"
  fi
  [ "$anchors" = "1" ] || die "$vhost has $anchors server blocks in $CONF — refusing to pick one"

  {
    printf '        # >>> clutch-deploy managed block (%s) >>>\n' "$vhost"
    echo "        # Generated on each deploy from $REPO_DIR/$vhost/. Edits here are overwritten."
    for f in "${files[@]}"; do
      echo "        # --- $(basename "$f") ---"
      sed 's/^/        /' "$f"
    done
    echo "$END_MARK"
  } > "$BLOCK"

  awk -v anchor="^[[:space:]]*server_name[[:space:]]+${vhost_re};" -v blockfile="$BLOCK" '
    $0 ~ anchor && !ins {
      # No blank line between the anchor and the block. The strip removes the marked lines and
      # nothing else, so a separator printed here survives it and the next run prints another --
      # the file grows a blank line per deploy and the script stops being idempotent.
      print
      while ((getline line < blockfile) > 0) print line
      close(blockfile)
      ins = 1
      next
    }
    { print }
    END { if (!ins) exit 3 }
  ' "$TMP" > "$TMP.ins" || die "awk could not find the $vhost anchor — config untouched"
  mv "$TMP.ins" "$TMP"
  log "$vhost: block built from ${#files[@]} route file(s)"
done

# One block per vhost directory, no more and no less. Cheap, and it is the assertion that catches a
# strip that missed something or an insert that ran twice.
blocks=$(grep -cF "$MARK_PREFIX" "$TMP" || true)
[ "$blocks" = "${#vhost_dirs[@]}" ] \
  || die "expected ${#vhost_dirs[@]} managed block(s), found $blocks"

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
#
# Done on the stage host on 2026-09-13, so this now finds nothing. It stays because a host restored
# from an older copy of the config would need it again, and because it costs one grep.
# ---------------------------------------------------------------------------
if grep -rq 'location /payment/' "$REPO_DIR"; then
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
  log "DRY_RUN — managed blocks as they would be written:"
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
