#!/usr/bin/env bash
#
# Ensure the nginx serving stage routes /payment/ to the payment orchestrator.
#
# Why this is a file and not inline in deploy-stage.yml: as an inline block it failed twice with
# exit 1, no message, and no ERR trap firing — the shell took neither branch of a plain `if`,
# which a working bash cannot do. The suspect is the multi-line single-quoted awk program going
# through YAML, then the ssh-action, then the remote shell. Here it is one `bash script.sh`, it
# is shellcheck-able, and it can be run against a copy of the real config before it ever touches
# the host.
#
# Context: the container named `nginx-stage` on that VPS belongs to the `v2ray` compose project
# and mounts a hand-maintained config that is NOT in this repo, serving the clutch vhosts next to
# v2ray's own. Editing config/nginx/*.conf here has no effect there. See clutch-deploy/CLAUDE.md.
#
# Idempotent: safe to run on every deploy, and it re-adds the route if the v2ray side ever
# replaces the file.
#
# Usage: bash scripts/ensure-nginx-payment-route.sh [container]
#   container defaults to nginx-stage.
#
# Env:
#   DRY_RUN=1        patch a copy and print it, touch nothing
#   CONF_OVERRIDE=p  patch p instead of reading the path off the container mount (for tests)

set -euo pipefail

CONTAINER="${1:-nginx-stage}"
VHOST="${VHOST:-app-stage.clutchprotocol.io}"
# Overridable so the script can be exercised against a throwaway nginx locally: `nginx -t`
# resolves a static proxy_pass host at CONFIG LOAD, so a test container off the clutch network
# cannot validate the real service name.
UPSTREAM="${UPSTREAM:-payment-orchestrator:8091}"

log() { echo "nginx-route: $*"; }
die() { echo "nginx-route: FAILED: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Locate the config the container is ACTUALLY serving.
# ---------------------------------------------------------------------------
if [ -n "${CONF_OVERRIDE:-}" ]; then
  CONF="$CONF_OVERRIDE"
  log "using CONF_OVERRIDE=$CONF"
else
  docker inspect "$CONTAINER" >/dev/null 2>&1 || die "no container named $CONTAINER"
  # Read it off the mount table rather than hardcoding: if the v2ray side moves the file this
  # follows it, instead of silently patching a path nobody reads.
  CONF=$(docker inspect "$CONTAINER" \
    --format '{{range .Mounts}}{{if eq .Destination "/etc/nginx/nginx.conf"}}{{.Source}}{{end}}{{end}}')
  [ -n "$CONF" ] || die "$CONTAINER has no bind mount at /etc/nginx/nginx.conf"
  log "container=$CONTAINER conf=$CONF"
fi

[ -f "$CONF" ] || die "$CONF does not exist"
[ -r "$CONF" ] || die "$CONF is not readable"

if grep -q 'location /payment/' "$CONF"; then
  log "/payment/ already routed — nothing to do"
  exit 0
fi

grep -q "server_name[[:space:]]\+${VHOST};" "$CONF" \
  || die "no '$VHOST' server block in $CONF — refusing to guess where the route belongs"

# ---------------------------------------------------------------------------
# Build the patched config.
#
# Anchored on server_name, not a line number: this file is hand-edited on the host and line
# numbers drift. nginx matches prefix locations longest-first, so position inside the server
# block does not affect routing.
#
# proxy_pass names the service directly instead of adding an upstream block: the host file has no
# clutch_payment_orchestrator upstream, and one insertion point is one thing that can go wrong
# instead of two. Same startup-time DNS resolution either way, which is why the deploy reloads
# nginx after recreating containers.
# ---------------------------------------------------------------------------
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

awk -v vhost="$VHOST" -v upstream="$UPSTREAM" '
  $0 ~ "^[[:space:]]*server_name[[:space:]]+" vhost ";" && !ins {
    print
    print ""
    print "        # Added by clutch-deploy (scripts/ensure-nginx-payment-route.sh)."
    print "        # Browser route to the payment orchestrator, which is deliberately not"
    print "        # published on a host port."
    print "        location /payment/ {"
    print "            rewrite ^/payment(/api/.*)$ $1 break;"
    print "            proxy_pass http://" upstream ";"
    print "            proxy_http_version 1.1;"
    print "            proxy_set_header Host $host;"
    print "            proxy_set_header X-Real-IP $remote_addr;"
    print "            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;"
    print "            proxy_set_header X-Forwarded-Proto https;"
    print "        }"
    ins = 1
    next
  }
  { print }
  END { if (!ins) exit 3 }
' "$CONF" > "$TMP" || die "awk could not find the $vhost anchor — config untouched"

if [ -n "${DRY_RUN:-}" ]; then
  log "DRY_RUN — patched result:"
  grep -n -A 12 'location /payment/' "$TMP"
  exit 0
fi

cp "$CONF" "$CONF.clutch.bak"

# cat, NOT mv. Docker bind-mounts a single file by INODE; mv gives the path a new inode and the
# container keeps serving the old content forever while every check on the host shows the new
# content. Truncate-and-write keeps the inode the container is holding.
cat "$TMP" > "$CONF"
log "added /payment/ -> $UPSTREAM in the $VHOST vhost"

if docker exec "$CONTAINER" nginx -t; then
  log "config valid"
else
  log "patched config is INVALID — restoring backup"
  cat "$CONF.clutch.bak" > "$CONF"
  # Most likely cause is an unresolvable upstream, not bad syntax: a static proxy_pass host is
  # resolved when the config LOADS, so this fails if the orchestrator is not running yet. Run
  # this after the orchestrator health gate, not before.
  die "nginx -t rejected the patched config (is $UPSTREAM up and on this nginx's network?)"
fi

# A patched file does nothing until nginx re-reads it.
docker exec "$CONTAINER" nginx -s reload
log "reloaded"
