#!/usr/bin/env bash
#
# Self-check for scripts/ensure-nginx-clutch-block.sh.
#
# That script edits, in place, the one nginx config serving the stage host -- including vhosts
# belonging to another project. It has shipped three real bugs already: an include that could never
# load anything, a vhost guard anchored to the start of a line that missed one-line server blocks,
# and a `shopt -s nullglob` that leaked out of a subshell and made it report 14 route files when
# there were none. Every one of them passed `nginx -t`.
#
# So: a fixture shaped like the host's config, and assertions about the candidate file. No docker,
# no network. Run it directly:
#
#   bash scripts/test-nginx-clutch-block.sh
#
# CONF_OVERRIDE + SKIP_NGINX are what make this possible; they exist for this.

set -euo pipefail

cd "$(dirname "$0")/.."
SCRIPT=scripts/ensure-nginx-clutch-block.sh

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
ok()   { pass=$((pass + 1)); echo "  ok: $*"; }
fail() { echo "  FAIL: $*" >&2; exit 1; }

# The host's config in miniature: someone else's vhosts, one of them written entirely on one line,
# the legacy single-block marker from before this script grew a per-vhost form, the dead include
# from the attempt before that, and the hand-patched /payment/ block it replaced.
fixture() {
  cat > "$1" <<'CONF'
http {
    upstream somewhere { server 10.0.0.1:80; }

    server {
        listen 80;
        server_name de2.example.net;
        location / { proxy_pass http://private-upstream; }
    }

    server { listen 80; server_name sub.example.net; location / { return 404; } }

    server {
        listen 80;
        server_name app-stage.clutchprotocol.io;

        # >>> clutch-deploy managed block (config/nginx/clutch.d) >>>
        # Generated on each deploy from config/nginx/clutch.d. Edits here are overwritten.
        # --- payment.conf ---
        location /payment/ {
            proxy_pass http://payment-orchestrator:8091;
        }
        # <<< clutch-deploy managed block <<<

        # Added by clutch-deploy (scripts/ensure-nginx-clutch-include.sh).
        # Clutch routes live in files this repo owns, synced on each deploy.
        include /etc/nginx/clutch.d/*.conf;

        location / { proxy_pass http://clutch-hub-demo-app:80; }
    }

    server {
        listen 80;
        server_name api-stage.clutchprotocol.io;

        location / { proxy_pass http://clutch-hub-api:3000; }
    }
}
CONF
}

# A repo directory built per test, so each case states its own inputs.
repo() {
  rm -rf "$WORK/repo"
  mkdir -p "$WORK/repo"
}
route() {
  mkdir -p "$WORK/repo/$1"
  printf 'location %s {\n    proxy_pass %s;\n}\n' "$2" "$3" > "$WORK/repo/$1/$(echo "$2" | tr -c 'a-z0-9' '-').conf"
}

run() {
  CONF_OVERRIDE="$WORK/conf" REPO_DIR="$WORK/repo" SKIP_NGINX=1 bash "$SCRIPT" >"$WORK/out" 2>&1
}

echo "== one vhost, migrating the legacy single block =="
fixture "$WORK/conf"; repo
route app-stage.clutchprotocol.io /payment/ http://payment-orchestrator:8091
run || { cat "$WORK/out"; fail "script exited non-zero"; }
grep -qF '# >>> clutch-deploy managed block (app-stage.clutchprotocol.io) >>>' "$WORK/conf" \
  || fail "no per-vhost marker after the run"
grep -qF '(config/nginx/clutch.d)' "$WORK/conf" && fail "legacy marker survived"
[ "$(grep -c 'location /payment/' "$WORK/conf")" = "1" ] \
  || fail "expected exactly one /payment/ location, found $(grep -c 'location /payment/' "$WORK/conf")"
grep -q 'include /etc/nginx/clutch\.d' "$WORK/conf" && fail "dead include survived"
grep -q 'Clutch routes live in files this repo owns' "$WORK/conf" && fail "orphan comment survived"
ok "legacy block, dead include and its comments all replaced by one per-vhost block"

echo "== a second vhost lands in its own server block =="
fixture "$WORK/conf"; repo
route app-stage.clutchprotocol.io /payment/ http://payment-orchestrator:8091
route api-stage.clutchprotocol.io /graphql http://clutch-hub-api:3000
run || { cat "$WORK/out"; fail "script exited non-zero"; }
[ "$(grep -cF '# >>> clutch-deploy managed block' "$WORK/conf")" = "2" ] || fail "expected two managed blocks"
# The one assertion that matters: /graphql has to be inside api-stage's server block, not merely
# present somewhere in the file. Check by line number against the two server_name anchors.
api_line=$(grep -n 'server_name api-stage' "$WORK/conf" | cut -d: -f1)
gql_line=$(grep -n 'location /graphql' "$WORK/conf" | cut -d: -f1)
pay_line=$(grep -n 'location /payment/' "$WORK/conf" | cut -d: -f1)
app_line=$(grep -n 'server_name app-stage' "$WORK/conf" | cut -d: -f1)
[ "$gql_line" -gt "$api_line" ] || fail "/graphql landed before api-stage's server_name"
[ "$pay_line" -gt "$app_line" ] && [ "$pay_line" -lt "$api_line" ] \
  || fail "/payment/ is not inside app-stage's server block"
ok "each vhost's routes sit inside that vhost's server block"

echo "== a vhost the host does not serve is refused, and nothing is written =="
fixture "$WORK/conf"; repo
cp "$WORK/conf" "$WORK/conf.orig"
route app-stage.clutchprotocol.io /payment/ http://payment-orchestrator:8091
route nope-stage.clutchprotocol.io /x http://nowhere:1
run && fail "should have refused an unknown vhost"
grep -q 'refusing to guess where the block belongs' "$WORK/out" || { cat "$WORK/out"; fail "wrong error"; }
cmp -s "$WORK/conf" "$WORK/conf.orig" || fail "config was modified despite the refusal"
ok "unknown vhost refused, config byte-identical"

echo "== a vhost whose server block is written on one line is refused =="
fixture "$WORK/conf"
sed -i 's/^    server { listen 80; server_name sub\.example\.net.*$/    server { listen 80; server_name oneline-stage.clutchprotocol.io; location \/ { return 404; } }/' "$WORK/conf"
cp "$WORK/conf" "$WORK/conf.orig"
repo
route oneline-stage.clutchprotocol.io /x http://nowhere:1
run && fail "should have refused a one-line server block"
grep -q 'not on a line of its own' "$WORK/out" || { cat "$WORK/out"; fail "wrong error"; }
cmp -s "$WORK/conf" "$WORK/conf.orig" || fail "config was modified despite the refusal"
ok "one-line server block refused rather than mis-anchored"

echo "== a .conf with no vhost directory is refused =="
fixture "$WORK/conf"; repo
route app-stage.clutchprotocol.io /payment/ http://payment-orchestrator:8091
printf 'location /orphan/ { return 404; }\n' > "$WORK/repo/orphan.conf"
run && fail "should have refused a stray .conf"
grep -q 'belong in a <vhost>/ subdirectory' "$WORK/out" || { cat "$WORK/out"; fail "wrong error"; }
ok "stray .conf refused"

echo "== a route file that opens a server block changes the vhost set, and is refused =="
fixture "$WORK/conf"; repo
route app-stage.clutchprotocol.io /payment/ http://payment-orchestrator:8091
# The README says location blocks only. This is what happens when someone ignores it: a vhost this
# repo has no business declaring, in a file shared with another project.
printf 'server {\n    listen 80;\n    server_name sneaky.clutchprotocol.io;\n}\n' \
  > "$WORK/repo/app-stage.clutchprotocol.io/sneaky.conf"
cp "$WORK/conf" "$WORK/conf.orig"
run && fail "should have refused a config that changes the vhost set"
grep -q 'changes which vhosts exist' "$WORK/out" || { cat "$WORK/out"; fail "wrong error"; }
cmp -s "$WORK/conf" "$WORK/conf.orig" || fail "config was modified despite the refusal"
ok "vhost set guard held"

echo "== a route file that closes its server block early is refused =="
fixture "$WORK/conf"; repo
route app-stage.clutchprotocol.io /payment/ http://payment-orchestrator:8091
# Closing the server block early leaves every server_name in the file, attached to the wrong
# servers -- valid nginx, and invisible to both `nginx -t` and the vhost-set guard.
printf 'location /x { return 404; }\n}\nserver {\n    listen 80;\n' \
  > "$WORK/repo/app-stage.clutchprotocol.io/sabotage.conf"
cp "$WORK/conf" "$WORK/conf.orig"
run && fail "should have refused unbalanced braces"
grep -q 'closes or leaves open a block' "$WORK/out" || { cat "$WORK/out"; fail "wrong error"; }
cmp -s "$WORK/conf" "$WORK/conf.orig" || fail "config was modified despite the refusal"
ok "unbalanced route file refused"

echo "== idempotent =="
fixture "$WORK/conf"; repo
route app-stage.clutchprotocol.io /payment/ http://payment-orchestrator:8091
route api-stage.clutchprotocol.io /graphql http://clutch-hub-api:3000
run || { cat "$WORK/out"; fail "first run failed"; }
cp "$WORK/conf" "$WORK/conf.once"
run || { cat "$WORK/out"; fail "second run failed"; }
cmp -s "$WORK/conf" "$WORK/conf.once" || fail "second run changed the file"
ok "running twice changes nothing"

echo ""
echo "$pass checks passed"
