#!/usr/bin/env bash
# Self-check for resync-validator.sh, the script that wipes a stage validator's chain data. CI runs it
# (test-treasury-scripts.yml) with a fake `docker` and a fake `sleep` in a temp directory: no host, no
# network, nothing is deleted. What it proves is the part that must not fail: every guard that should stop
# the wipe stops it BEFORE anything is stopped, copied or removed, and a real wipe goes stop, copy, remove,
# start, without touching the other two validators.
set -euo pipefail
cd "$(dirname "$0")/.."

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/scripts" "$T/bin"
cp scripts/resync-validator.sh "$T/scripts/"

printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/sleep"

# The host and CI can set a folder's mode; a Windows drive cannot, and `mkdir -m 700` then fails. Only
# there does this shim run (it drops the -m), so a dev machine can still run the whole test.
if mkdir -m 700 "$T/modeprobe" 2>/dev/null; then
  rmdir "$T/modeprobe"
else
  REAL_MKDIR=$(command -v mkdir)
  printf '#!/usr/bin/env bash\nargs=(); skip=0\nfor a in "$@"; do\n  if [ "$skip" = 1 ]; then skip=0; continue; fi\n  if [ "$a" = "-m" ]; then skip=1; continue; fi\n  args+=("$a")\ndone\nexec %s "${args[@]}"\n' "$REAL_MKDIR" > "$T/bin/mkdir"
  chmod +x "$T/bin/mkdir"
fi

# The fake docker answers what the script asks, from FAKE_* values, and writes every call to $FAKE_CALLS.
#   FAKE_HEAD_<n>        "<height> <hash>" of node n before the run (unset: the node does not answer)
#   FAKE_AFTER_HEAD_<n>  the same once `compose up` has started node n
#   FAKE_REF_HASH        the hash a healthy node gives for the block at the target's height
#   FAKE_DOWN_<n>        set: the container of node n is not running
#   FAKE_VOLUME          the volume mounted at /app/data (default: the right one)
#   FAKE_TOUCH           set to a node number: that node "restarts" when `compose up` runs
#   FAKE_LOG             what `docker logs` prints
cat > "$T/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "$FAKE_CALLS"
last="${*: -1}"
case "$1" in
  compose)
    verb=""; svc=""
    for a in "$@"; do
      case "$a" in
        ps|stop|rm|up) [ -n "$verb" ] || verb="$a" ;;
        node1|node2|node3) svc="$a" ;;
      esac
    done
    n=${svc#node}
    case "$verb" in
      ps)
        eval "down=\${FAKE_DOWN_$n:-}"
        [ -n "$down" ] || echo "cid-$svc"
        ;;
      up)
        : > "$T/up_$n"
        [ -z "${FAKE_TOUCH:-}" ] || : > "$T/touched_$FAKE_TOUCH"
        ;;
    esac
    ;;
  inspect)
    fmt="$3"
    case "$fmt" in
      *Mounts*) printf '%s' "${FAKE_VOLUME:-clutch-stage_node${last#cid-node}-data}" ;;
      *Config.Image*) echo "ghcr.io/clutchprotocol/clutch-node:sha-test started T0" ;;
      *StartedAt*) if [ -e "$T/touched_${last#cid-node}" ]; then echo T1; else echo T0; fi ;;
    esac
    ;;
  volume)
    [ "$2" = inspect ] && exit "${FAKE_VOLUME_RC:-0}"
    ;;
  logs)
    printf '%s\n' "${FAKE_LOG:-}"
    ;;
  run)
    case "$*" in
      *curlimages*)
        n=$(printf '%s' "$last" | sed -n 's/.*node\([123]\):.*/\1/p')
        if [ -e "$T/up_$n" ]; then eval "h=\${FAKE_AFTER_HEAD_$n:-}"; else eval "h=\${FAKE_HEAD_$n:-}"; fi
        if [ -n "$h" ]; then
          set -- $h
          printf 'latest_block_index %s\nlatest_block{block_hash="%s"} %s\n' "$1" "$2" "$1"
        fi
        ;;
      *node-rpc.py*)
        if [ -n "${FAKE_REF_HASH:-}" ]; then
          printf '{"jsonrpc":"2.0","id":1,"result":{"index":1,"previous_hash":"p","hash":"%s","transactions":[{"hash":"tx"}]}}\n' "$FAKE_REF_HASH"
        fi
        ;;
      *"--entrypoint du"*) printf '1234\t/d\n' ;;
      *"--entrypoint tar"*)
        host=""
        args=("$@")
        for i in "${!args[@]}"; do
          case "${args[$i]}" in
            -v) case "${args[$((i + 1))]}" in *:/b) host="${args[$((i + 1))]%:/b}" ;; esac ;;
          esac
        done
        echo "an archive" | gzip > "$host/data.tgz"
        ;;
    esac
    ;;
esac
exit 0
EOF
chmod +x "$T/bin/docker" "$T/bin/sleep"

passed=0
failed=0
out=""
code=0

check() {  # check <name> <condition...>: the condition is a command; its exit status is the verdict
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

fresh() {  # fresh: a host where node1 is on a fork, node2 and node3 agree, nothing has been called
  rm -rf "$T/backups" "$T/calls" "$T"/up_* "$T"/touched_*
  : > "$T/calls"
  local v
  for v in $(compgen -v | grep '^FAKE_' || true); do unset "$v"; done
  export FAKE_HEAD_1="144576 forkhash" FAKE_HEAD_2="163160 realhash" FAKE_HEAD_3="163160 realhash"
  export FAKE_REF_HASH="realhash-at-144576" FAKE_AFTER_HEAD_1="900 abc"
}

run() {  # run <node>
  code=0
  out=$(env PATH="$T/bin:$PATH" T="$T" REPO_DIR="$T" NODE="$1" FAKE_CALLS="$T/calls" \
          AGREE_WAIT_SECS=0 START_WAIT_SECS=0 bash "$T/scripts/resync-validator.sh" 2>&1) || code=$?
}

said() { printf '%s' "$out" | grep -qF -- "$1"; }
called() { grep -qE -- "$1" "$T/calls"; }
# Nothing was stopped, copied, removed or started.
untouched() {
  ! called ' (stop|rm|up) ' && ! called 'volume rm' && ! called '--entrypoint tar' \
    && [ -z "$(find "$T/backups" -mindepth 1 -maxdepth 1 2>/dev/null)" ]
}
line_of() { grep -nE -- "$1" "$T/calls" | head -1 | cut -d: -f1; }
refused() { [ "$code" -ne 0 ] && said "$1" && untouched; }

# 1. A fork, everything in order: stop, copy, remove the container, remove the volume, start.
fresh
run 1
check "a forked node is wiped and restarted" eval '[ "$code" -eq 0 ] && said "fork confirmed" && said "resync started"'
check "the order is stop, copy, remove, remove the volume, start" eval \
  '[ "$(line_of " stop node1")" -lt "$(line_of "--entrypoint tar")" ] && [ "$(line_of "--entrypoint tar")" -lt "$(line_of " rm -sf node1")" ] && [ "$(line_of " rm -sf node1")" -lt "$(line_of "volume rm clutch-stage_node1-data")" ] && [ "$(line_of "volume rm clutch-stage_node1-data")" -lt "$(line_of " up -d --no-deps node1")" ]'
check "the old data is kept, with a note" eval \
  'f=$(find "$T/backups" -name data.tgz | head -1); [ -n "$f" ] && gzip -t "$f" && [ -s "$(dirname "$f")/README" ]'
check "node2 and node3 are never stopped, removed or started" eval \
  '! called " (stop|rm -sf|up -d --no-deps) node[23]$"'

# 2. The other two do not agree: there would be nothing to sync from.
fresh
export FAKE_HEAD_3="163160 otherhash"
run 1
check "validators that disagree stop it" refused "do not agree"

# 3. The other two are not both running.
fresh
export FAKE_DOWN_3=1
run 1
check "a validator that is down stops it" refused "is not running"

# 4. A healthy node has nothing to fix.
fresh
export FAKE_HEAD_1="163160 realhash"
run 1
check "a node at the same head is left alone" eval '[ "$code" -eq 0 ] && said "nothing to do" && untouched'

# 5. A node that is only behind holds the real chain.
fresh
export FAKE_REF_HASH="forkhash"
run 1
check "a node that is only behind is not wiped" refused "only behind, not forked"

# 6. A node that is ahead.
fresh
export FAKE_HEAD_1="170000 forkhash"
run 1
check "a node that is ahead is not wiped" refused "AHEAD"

# 7. A node whose head cannot be read.
fresh
unset FAKE_HEAD_1
run 1
check "a node that does not answer is not wiped" refused "cannot read the head"

# 8. The reference block cannot be read.
fresh
unset FAKE_REF_HASH
run 1
check "no reference block, no wipe" refused "could not read block"

# 9. The volume is not the one this script expects.
fresh
export FAKE_VOLUME="some_other_volume"
run 1
check "a volume with another name is not removed" refused "not clutch-stage_node1-data"

# 10. Node 3 and anything that is not a stage validator.
fresh
run 3
check "node 3 is refused" eval '[ "$code" -eq 2 ] && said "Hub API" && untouched'
fresh
run 4
check "node 4 is refused" eval '[ "$code" -eq 2 ] && said "NODE must be 1 or 2" && untouched'

# 11. The wiped node says it refuses blocks.
fresh
export FAKE_LOG="Failed to import block with index 5: Invalid block: The previous hash should be abc, but it was def"
run 1
check "a wiped node that refuses blocks fails the run" eval '[ "$code" -ne 0 ] && said "refuses blocks it syncs" && said "stopped part-way"'

# 12. The sync does not start.
fresh
export FAKE_AFTER_HEAD_1="0 genesis"
run 1
check "a node that does not start syncing fails the run" eval '[ "$code" -ne 0 ] && said "did not start syncing"'

# 13. One of the other two restarts during the run.
fresh
export FAKE_TOUCH=2
run 1
check "a restart of another validator fails the run" eval '[ "$code" -ne 0 ] && said "was restarted during this run"'

echo ""
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
