#!/usr/bin/env bash
#
# Self-check for scripts/set-image.sh, plus a guard on the real compose files.
#
# set-image.sh is the only thing that moves an image tag on stage or mainnet, and a deploy ships
# whatever it wrote. The ways it can go wrong without anyone noticing: a tag written into the other
# environment's files (a stage pin moving mainnet), or half of a set written (one image moved, the
# next one refused). The guard at the end covers the way that does not involve the script at all:
# a compose file going back to `latest`, or an overlay quietly overriding a pinned image.
#
#   bash scripts/test-set-image.sh
#
# PIN_ROOT and SKIP_REGISTRY_CHECK exist for this. Two checks call ghcr.io; the rest is local.

set -euo pipefail

cd "$(dirname "$0")/.."
SCRIPT="$PWD/scripts/set-image.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
ok()   { pass=$((pass + 1)); echo "  ok: $*"; }
fail() { echo "  FAIL: $*" >&2; [ -f "$WORK/out" ] && sed 's/^/    | /' "$WORK/out" >&2; exit 1; }

# The four pinned files in miniature. Each image sits where the real files put it: clutch-node
# three times in the stage base, the demo app in both environments, a treasury image in each
# environment's treasury file.
fixture() {
  rm -rf "$WORK/r" "$WORK/before"
  mkdir -p "$WORK/r"
  cat > "$WORK/r/docker-compose.yml" <<'YML'
services:
  node1:
    image: ghcr.io/clutchprotocol/clutch-node:sha-aaaaaaa
  node2:
    image: ghcr.io/clutchprotocol/clutch-node:sha-aaaaaaa
  node3:
    image: ghcr.io/clutchprotocol/clutch-node:sha-aaaaaaa  # a comment stays
  clutch-hub-api:
    image: ghcr.io/clutchprotocol/clutch-hub-api:sha-bbbbbbb
  clutch-hub-demo-app:
    image: ghcr.io/clutchprotocol/clutch-hub-demo-app:sha-ccccccc
  grafana:
    image: grafana/grafana:13.2.2
YML
  cat > "$WORK/r/docker-compose.treasury.yml" <<'YML'
services:
  treasury-service:
    image: ghcr.io/clutchprotocol/clutch-treasury:sha-ddddddd
YML
  cat > "$WORK/r/docker-compose.mainnet.yml" <<'YML'
services:
  mainnet-node1:
    image: ghcr.io/clutchprotocol/clutch-node:sha-eeeeeee
  mainnet-demo-app:
    image: ghcr.io/clutchprotocol/clutch-hub-demo-app:sha-fffffff
YML
  cat > "$WORK/r/docker-compose.mainnet.treasury.yml" <<'YML'
services:
  treasury-service:
    image: ghcr.io/clutchprotocol/clutch-treasury:sha-1111111
YML
  cp -r "$WORK/r" "$WORK/before"
}

pin()       { PIN_ROOT="$WORK/r" SKIP_REGISTRY_CHECK=1 bash "$SCRIPT" "$@" > "$WORK/out" 2>&1; }
unchanged() { diff -r "$WORK/before" "$WORK/r" > /dev/null; }
same()      { cmp -s "$WORK/before/$1" "$WORK/r/$1"; }
has()       { grep -q -- "$1" "$WORK/r/$2"; }

echo "print"
fixture
pin stage clutch-hub-api || fail "print failed"
[ "$(cat "$WORK/out")" = "sha-bbbbbbb" ] || fail "print gave '$(cat "$WORK/out")'"
ok "prints the pinned tag"
pin mainnet clutch-node || fail "mainnet print failed"
[ "$(cat "$WORK/out")" = "sha-eeeeeee" ] || fail "mainnet print gave '$(cat "$WORK/out")'"
ok "prints the environment's own tag, not the other environment's"
unchanged || fail "print changed a file"
ok "print writes nothing"

echo "set"
fixture
pin stage clutch-node=sha-1234567 || fail "set failed"
[ "$(grep -c 'clutch-node:sha-1234567' "$WORK/r/docker-compose.yml")" = 3 ] || fail "not every clutch-node line moved"
ok "moves every line of the image"
has 'clutch-node:sha-1234567  # a comment stays' docker-compose.yml || fail "the trailing comment was lost"
ok "keeps a trailing comment"
has 'clutch-hub-api:sha-bbbbbbb' docker-compose.yml && has 'grafana/grafana:13.2.2' docker-compose.yml \
  || fail "another image moved"
ok "no other image moves"
same docker-compose.mainnet.yml && same docker-compose.mainnet.treasury.yml || fail "a stage pin changed a mainnet file"
ok "a stage pin leaves mainnet alone"

fixture
pin mainnet clutch-hub-demo-app=sha-7654321 || fail "mainnet set failed"
has 'clutch-hub-demo-app:sha-7654321' docker-compose.mainnet.yml || fail "the mainnet demo did not move"
same docker-compose.yml && same docker-compose.treasury.yml || fail "a mainnet pin changed a stage file"
ok "a mainnet pin leaves stage alone"

fixture
pin stage clutch-hub-api=sha-2222222 clutch-treasury=sha-3333333 || fail "set of two failed"
has 'clutch-hub-api:sha-2222222' docker-compose.yml && has 'clutch-treasury:sha-3333333' docker-compose.treasury.yml \
  || fail "not both images moved"
same docker-compose.mainnet.treasury.yml || fail "the stage treasury pin reached the mainnet treasury file"
ok "sets several images at once, each in its own file"

fixture
pin stage clutch-node=sha-1234567 || fail "first set failed"
cp -r "$WORK/r" "$WORK/once"
pin stage clutch-node=sha-1234567 || fail "second set failed"
diff -r "$WORK/once" "$WORK/r" > /dev/null || fail "setting the same tag twice changed a file"
ok "setting the tag it already has changes nothing"

echo "refusals: nothing may change"
refused() {
  local what="$1"; shift
  fixture
  if pin "$@"; then fail "accepted $what"; fi
  unchanged || fail "refused $what but still changed a file"
  ok "refuses $what"
}
refused "an unknown image"                        stage clutch-bogus=sha-1234567
refused "latest"                                  stage clutch-node=latest
refused "a sha tag shorter than 7"                stage clutch-node=sha-12345
refused "a sha tag longer than 7"                 stage clutch-node=sha-12345678
refused "upper-case hex"                          stage clutch-node=sha-ABCDEF1
refused "shell characters in a tag"               stage 'clutch-node=sha-123456;'
refused "an empty tag"                            stage clutch-node=
refused "an image this environment does not pin"  mainnet clutch-hub-api=sha-1234567
refused "a bad pair after a good one"             stage clutch-node=sha-1234567 clutch-bogus=sha-1234567
refused "a pair without ="                        stage clutch-node=sha-1234567 clutch-hub-api
refused "an unknown environment"                  prod clutch-node=sha-1234567
refused "no image at all"                         stage

fixture
sed -i '0,/clutch-node:sha-aaaaaaa/s//clutch-node:sha-9999999/' "$WORK/r/docker-compose.yml"
if pin stage clutch-node; then fail "print accepted lines that disagree"; fi
ok "print refuses an image whose lines disagree"

fixture
if CI='' PUSH=1 PIN_ROOT="$WORK/r" SKIP_REGISTRY_CHECK=1 bash "$SCRIPT" stage clutch-node=sha-1234567 > "$WORK/out" 2>&1; then
  fail "PUSH=1 ran outside CI"
fi
unchanged || fail "PUSH=1 outside CI changed a file"
ok "PUSH=1 refuses to run outside CI"

echo "registry: calls ghcr.io"
fixture
# sha-c3e301f is the node image the mainnet validators run, so it will not be deleted while they do.
if PIN_ROOT="$WORK/r" bash "$SCRIPT" stage clutch-node=sha-0000000 > "$WORK/out" 2>&1; then
  fail "accepted a tag the registry does not have"
fi
unchanged || fail "refused a missing tag but still changed a file"
ok "refuses a tag the registry does not have"
PIN_ROOT="$WORK/r" bash "$SCRIPT" stage clutch-node=sha-c3e301f > "$WORK/out" 2>&1 || fail "refused a tag that exists"
has 'clutch-node:sha-c3e301f' docker-compose.yml || fail "an existing tag was accepted but not written"
ok "accepts a tag the registry has"

echo "the real compose files"
rm -f "$WORK/out"
FILES=$(ls docker-compose*.yml | grep -v '\.dev\.yml$')
while read -r f img; do
  ref="${img##*/}"
  case "$ref" in *:*) ;; *) fail "$f: '$img' has no tag, so every deploy pulls its latest" ;; esac
  [ "${ref##*:}" != "latest" ] || fail "$f: '$img' uses latest"
done < <(for f in $FILES; do
           grep -E '^[[:space:]]*image:' "$f" \
             | sed -E -e 's/^[[:space:]]*image:[[:space:]]*//' -e 's/[[:space:]]+#.*//' -e "s/[\"']//g" \
             | sed "s|^|$f |"
         done)
ok "no compose file uses latest or an untagged image"

# shellcheck disable=SC2086  # FILES is a list of plain file names.
bad=$(grep -HE 'image:[[:space:]]*ghcr\.io/clutchprotocol/' $FILES \
        | grep -vE 'clutchprotocol/[a-z-]+:sha-[0-9a-f]{7}([[:space:]]|$)' || true)
[ -z "$bad" ] || fail "Clutch images not pinned to a sha-<7> tag: $bad"
ok "every Clutch image is pinned to a sha tag"

for f in docker-compose.stage.cloudflare-flex.yml docker-compose.stage.treasury.yml; do
  if grep -qE 'image:[[:space:]]*ghcr\.io/clutchprotocol/' "$f"; then
    fail "$f sets a Clutch image, which silently overrides the pin in the base file"
  fi
done
ok "the stage overlays set no Clutch image"

for img in clutch-node clutch-hub-api clutch-hub-demo-app clutch-explorer-backend \
           clutch-explorer-frontend clutch-treasury clutch-orchestrator clutch-tron-signer; do
  PIN_ROOT="$PWD" bash "$SCRIPT" stage "$img" > "$WORK/out" 2>&1 || fail "stage has no single pin for $img"
done
ok "stage pins all 8 images, each to one tag"
for img in clutch-node clutch-hub-api clutch-hub-demo-app clutch-treasury clutch-orchestrator clutch-tron-signer; do
  PIN_ROOT="$PWD" bash "$SCRIPT" mainnet "$img" > "$WORK/out" 2>&1 || fail "mainnet has no single pin for $img"
done
ok "mainnet pins its chain, app and treasury images, each to one tag"

echo ""
echo "$pass checks passed"
