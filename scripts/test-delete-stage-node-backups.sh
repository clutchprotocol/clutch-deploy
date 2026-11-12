#!/usr/bin/env bash
# Linux CI only: exercise deletion against temporary files, never the host.
# These checks catch broad deletion, following links, and missing safety guards.
set -euo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/scripts" "$T/bin"
cp scripts/delete-stage-node-backups.sh "$T/scripts/"
cat > "$T/bin/docker" <<'EOF'
#!/usr/bin/env bash
[ "$*" = "inspect -f {{.State.Running}} clutch-stage-node1-1" ] ||
[ "$*" = "inspect -f {{.State.Running}} clutch-stage-node2-1" ] ||
[ "$*" = "inspect -f {{.State.Running}} clutch-stage-node3-1" ] || exit 1
case "${FAKE_STATE:-true}" in missing) exit 1 ;; *) printf '%s\n' "${FAKE_STATE:-true}" ;; esac
EOF
chmod +x "$T/bin/docker"
export PATH="$T/bin:$PATH"
GOOD=stage-node1-data-20261029T165633Z
fresh() {
  rm -rf "$T/backups" "$T/outside"
  mkdir -p "$T/backups/$GOOD" "$T/backups/stage-node2-data-20261101T000000Z" "$T/outside"
  printf archive > "$T/backups/$GOOD/data.tgz"
  printf note > "$T/backups/$GOOD/README"
  printf keep > "$T/backups/treasury.dump.enc"
  printf keep > "$T/backups/stage-node2-data-20261101T000000Z/data.tgz"
  printf keep > "$T/outside/keep"
  unset FAKE_STATE
}
run() { MODE="$1" bash "$T/scripts/delete-stage-node-backups.sh"; }
kept() { [ -f "$T/backups/$GOOD/data.tgz" ]; }
survivors() {
  [ -f "$T/backups/treasury.dump.enc" ] &&
  [ -f "$T/backups/stage-node2-data-20261101T000000Z/data.tgz" ] &&
  [ -f "$T/outside/keep" ]
}
fresh
run check
kept
survivors
printf 'ok    check mode preserves files\n'
run delete
[ ! -e "$T/backups/$GOOD" ]
survivors
printf 'ok    deletes only the approved backup\n'
run delete
survivors
printf 'ok    repeated deletion is harmless\n'
for state in false missing; do
  fresh
  export FAKE_STATE="$state"
  if run delete; then exit 1; fi
  kept
  survivors
  printf 'ok    refuses validator state %s\n' "$state"
done
fresh
if run invalid; then exit 1; fi
kept
printf 'ok    rejects invalid mode\n'
fresh
rm -rf "$T/backups/$GOOD"
ln -s "$T/outside" "$T/backups/$GOOD"
[ -L "$T/backups/$GOOD" ] # A copied directory is not a valid symlink fixture.
if run delete; then exit 1; fi
[ -L "$T/backups/$GOOD" ]
survivors
printf 'ok    refuses a linked backup\n'
fresh
rm -rf "$T/backups"
ln -s "$T/outside" "$T/backups"
[ -L "$T/backups" ]
if run delete; then exit 1; fi
[ -f "$T/outside/keep" ]
printf 'ok    refuses a linked backups directory\n'
for kind in extra directory link; do
  fresh
  case "$kind" in
    extra) printf keep > "$T/backups/$GOOD/notes.txt" ;;
    directory) mkdir "$T/backups/$GOOD/sub" ;;
    link) rm "$T/backups/$GOOD/README"; ln -s "$T/outside/keep" "$T/backups/$GOOD/README" ;;
  esac
  if run delete; then exit 1; fi
  kept
  survivors
  printf 'ok    refuses unexpected content: %s\n' "$kind"
done
printf 'All stage backup cleanup checks passed.\n'
