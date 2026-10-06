#!/usr/bin/env bash
# Self-check for prune-host-images.sh. CI runs it (test-treasury-scripts.yml) with a fake `docker`:
# no host, nothing is removed. What it proves: check mode removes nothing, an image a container uses
# is never listed, an image newer than the limit is never listed, prune mode calls
# `docker image prune -a` with the same age limit, and a bad mode or a limit under 24 hours stops it
# before anything is removed.
set -euo pipefail
cd "$(dirname "$0")/.."

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/scripts" "$T/bin"
cp scripts/prune-host-images.sh "$T/scripts/"

# The fake docker. FAKE_CONTAINERS: container ids, one per line. FAKE_USED: the image ids those
# containers use. FAKE_IMAGES: id|name|created|size lines. Every call is written to $FAKE_CALLS.
cat > "$T/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "$FAKE_CALLS"
case "$1 $2" in
  "system df") echo "TYPE TOTAL ACTIVE SIZE RECLAIMABLE" ;;
  "ps -aq") printf '%s' "${FAKE_CONTAINERS:-}" ;;
  "image ls") printf '%s\n' "${FAKE_IMAGES:-}" ;;
  "image prune") echo "Total reclaimed space: 1GB" ;;
  *) [ "$1" = inspect ] && printf '%s\n' "${FAKE_USED:-}" ;;
esac
exit 0
EOF
chmod +x "$T/bin/docker"

when() { date -u -d "$1" '+%Y-%m-%d %H:%M:%S +0000 UTC'; }
OLD=$(when '30 days ago')
THREE=$(when '3 days ago')
NEW=$(when '1 day ago')

passed=0
failed=0
out=""
code=0

check() {  # check <name> <condition...>
  local name="$1"
  shift
  if "$@"; then
    passed=$((passed + 1))
    echo "ok    $name"
  else
    failed=$((failed + 1))
    echo "FAIL  $name"
    printf '%s\n' "$out" | sed 's/^/        /'
  fi
}

fresh() {
  : > "$T/calls"
  export FAKE_CONTAINERS=$'c1\nc2\n'
  export FAKE_USED=$'sha256:used1\nsha256:used2'
  export FAKE_IMAGES="sha256:used1|ghcr.io/clutchprotocol/clutch-node:sha-1111111|$OLD|60MB
sha256:old1|ghcr.io/clutchprotocol/clutch-node:sha-2222222|$OLD|60MB
sha256:three|ghcr.io/clutchprotocol/clutch-hub-api:sha-3333333|$THREE|40MB
sha256:new1|ghcr.io/clutchprotocol/clutch-hub-demo-app:sha-4444444|$NEW|30MB"
  unset KEEP_HOURS
}

run() {  # run <mode>
  code=0
  out=$(env PATH="$T/bin:$PATH" MODE="$1" FAKE_CALLS="$T/calls" bash "$T/scripts/prune-host-images.sh" 2>&1) || code=$?
}

said() { printf '%s' "$out" | grep -qF -- "$1"; }
pruned() { grep -qF "docker image prune" "$T/calls"; }

# 1. check: lists only the old image no container uses, and removes nothing.
fresh
run check
check "check mode succeeds and says it removed nothing" eval '[ "$code" -eq 0 ] && said "check only: nothing was removed."'
check "an old image no container uses is listed" eval 'said "clutch-node:sha-2222222"'
check "an image a container uses is never listed, however old" eval '! said "clutch-node:sha-1111111"'
check "an image newer than 7 days is not listed" eval '! said "sha-4444444" && ! said "sha-3333333"'
check "the count is the listed tags" eval 'said "1 image tag(s)."'
check "check mode never calls prune" eval '! pruned'

# 2. prune: the same age limit, passed to docker.
fresh
run prune
check "prune mode removes with the 7-day limit" eval '[ "$code" -eq 0 ] && grep -qxF "docker image prune -a -f --filter until=168h" "$T/calls"'
check "prune mode shows the disk after" eval 'said "=== disk after ==="'

# 3. a shorter limit is passed through, and widens the list.
fresh; export KEEP_HOURS=48
run prune
check "KEEP_HOURS=48 lists the 3-day-old image too" eval 'said "sha-3333333" && ! said "sha-4444444"'
check "KEEP_HOURS=48 prunes with until=48h" eval 'grep -qxF "docker image prune -a -f --filter until=48h" "$T/calls"'

# 4. no containers at all: nothing is in use, so every old image is listed.
fresh; export FAKE_CONTAINERS="" FAKE_USED=""
run check
check "with no container, every old image is listed" eval '[ "$code" -eq 0 ] && said "sha-1111111" && said "sha-2222222" && said "2 image tag(s)."'

# 5. what stops it before anything is removed.
for bad in oops ""; do
  fresh
  run "$bad"
  check "mode '$bad' stops it and removes nothing" eval '[ "$code" -ne 0 ] && ! pruned'
done
for hours in abc 12 ""; do
  fresh; export KEEP_HOURS="$hours"
  run prune
  if [ -z "$hours" ]; then
    # Empty means "not set": the default of 168 applies.
    check "an empty KEEP_HOURS means the default" eval '[ "$code" -eq 0 ] && grep -qxF "docker image prune -a -f --filter until=168h" "$T/calls"'
  else
    check "KEEP_HOURS=$hours stops it and removes nothing" eval '[ "$code" -ne 0 ] && ! pruned'
  fi
done

echo ""
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
