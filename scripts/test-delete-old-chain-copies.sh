#!/usr/bin/env bash
# Self-check for delete-old-chain-copies.sh, the script that deletes the copies of old mainnet chains
# kept in backups/. CI runs it (test-treasury-scripts.yml) with a fake `docker` and a temp directory:
# no host, no network, nothing real is deleted. What it proves is the part that must never fail: it
# deletes only the folders the reset script makes, never the treasury database dumps that live in the
# same backups/ folder, never a link or a folder that holds anything else, and never while a validator
# is down. Check mode changes nothing at all.
set -euo pipefail
cd "$(dirname "$0")/.."

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/scripts" "$T/bin"
cp scripts/delete-old-chain-copies.sh "$T/scripts/"

# The fake docker. The script asks one thing: is container clutch-main-mainnet-node<n>-1 running?
# FAKE_DOWN lists the nodes that are stopped ("2", "1 3"); FAKE_MISSING lists the nodes with no container.
cat > "$T/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "$FAKE_CALLS"
case "$1" in
  inspect)
    name="${*: -1}"
    for n in ${FAKE_MISSING:-}; do case "$name" in *"node${n}-1") exit 1 ;; esac; done
    for n in ${FAKE_DOWN:-};    do case "$name" in *"node${n}-1") echo false; exit 0 ;; esac; done
    echo true
    ;;
esac
exit 0
EOF
chmod +x "$T/bin/docker"

OLD1=mainnet-chain-20261005T124021Z
OLD2=mainnet-chain-20261006T101144Z

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

# A copy as reset-mainnet-chain.sh makes it: three archives and a note, in a folder of mode 700.
make_copy() {  # make_copy <name>
  mkdir -m 700 "$T/backups/$1"
  local n
  for n in 1 2 3; do echo "an archive of node $n" | gzip > "$T/backups/$1/node$n.tgz"; done
  printf '%s\n' "The old mainnet chain (chain_id 1000), copied on 2026-10-05T12:40:21Z just before it was wiped." \
    "No CLT had been minted on it." > "$T/backups/$1/README"
}

fresh() {  # fresh: two good copies, and things beside them that must always survive
  rm -rf "$T/backups" "$T/elsewhere" "$T/calls"
  mkdir -p "$T/backups/mainnet" "$T/elsewhere"
  : > "$T/calls"
  make_copy "$OLD1"
  make_copy "$OLD2"
  echo "a database dump" > "$T/backups/treasury-20260911T000000Z.dump.enc"
  echo "a database dump" > "$T/backups/mainnet/treasury-20261005T000000Z.dump.enc"
  echo "not part of any copy" > "$T/elsewhere/keep.txt"
  unset FAKE_DOWN FAKE_MISSING
}

run() {  # run <mode>
  code=0
  out=$(env -i PATH="$T/bin:$PATH" MODE="$1" FAKE_CALLS="$T/calls" \
          ${FAKE_DOWN+FAKE_DOWN="$FAKE_DOWN"} ${FAKE_MISSING+FAKE_MISSING="$FAKE_MISSING"} \
          bash "$T/scripts/delete-old-chain-copies.sh" 2>&1) || code=$?
}

said() { printf '%s' "$out" | grep -qF -- "$1"; }
there() { [ -e "$T/backups/$1" ] || [ -L "$T/backups/$1" ]; }
gone() { ! there "$1"; }
# What must be there after ANY run: the database dumps, and the file a link could point at.
survivors() {
  [ -s "$T/backups/treasury-20260911T000000Z.dump.enc" ] \
    && [ -s "$T/backups/mainnet/treasury-20261005T000000Z.dump.enc" ] \
    && [ -s "$T/elsewhere/keep.txt" ]
}
# Everything under backups/ and elsewhere/: name, type, size, link target.
snapshot() { find "$T/backups" "$T/elsewhere" -printf '%p %y %s %l\n' | sort; }
# docker was asked only whether the nodes run: no stop, rm, down, volume or prune.
only_inspects() { ! grep -qv '^docker inspect ' "$T/calls"; }

# 1. check mode: lists both copies, with their notes, and changes nothing.
fresh
before=$(snapshot)
run check
check "check mode lists both copies" eval '[ "$code" -eq 0 ] && said "FOUND $OLD1" && said "FOUND $OLD2"'
check "check mode prints the note of each copy" eval 'said "The old mainnet chain (chain_id 1000)"'
check "check mode says it deleted nothing" eval 'said "check only: 2 copies would be deleted" && said "Nothing was changed."'
check "check mode changes nothing" eval '[ "$(snapshot)" = "$before" ] && survivors'
check "check mode does not need docker" eval '[ ! -s "$T/calls" ]'

# 1b. check mode answers while the chain is down: it is read-only.
fresh; export FAKE_DOWN="1 2 3"
run check
check "check mode works while the validators are down" eval '[ "$code" -eq 0 ] && said "FOUND $OLD1" && there "$OLD1" && there "$OLD2"'

# 2. delete mode, validators running: both copies go, everything else stays.
fresh
run delete
check "delete mode deletes both copies" eval '[ "$code" -eq 0 ] && said "deleted 2 copies" && gone "$OLD1" && gone "$OLD2"'
check "delete mode leaves the database dumps and anything outside backups/ alone" survivors
check "the backups folder itself stays" eval '[ -d "$T/backups" ] && [ -d "$T/backups/mainnet" ]'
check "delete mode asked docker about all three validators, and nothing else" eval \
  'grep -q "mainnet-node1-1" "$T/calls" && grep -q "mainnet-node2-1" "$T/calls" && grep -q "mainnet-node3-1" "$T/calls" && only_inspects'
check "delete mode says how much it freed" eval 'said "free on the disk now:"'

# 2b. a second run has nothing left to do.
run delete
check "a second delete finds nothing and succeeds" eval '[ "$code" -eq 0 ] && said "deleted 0 copies" && survivors'

# 3. a validator that is not running stops it before anything is deleted.
for down in 1 2 3; do
  fresh; export FAKE_DOWN="$down"
  before=$(snapshot)
  run delete
  check "validator $down stopped: delete refuses and deletes nothing" eval \
    '[ "$code" -eq 1 ] && said "mainnet-node${down}-1 is not running" && [ "$(snapshot)" = "$before" ]'
done
fresh; export FAKE_MISSING=2
before=$(snapshot)
run delete
check "a validator with no container stops it" eval '[ "$code" -eq 1 ] && said "mainnet-node2-1 is not running" && [ "$(snapshot)" = "$before" ]'

# 4. only folders with the exact name the reset script makes.
fresh
for n in mainnet-chain-latest "$OLD1.bak" mainnet-chain-2026 "x$OLD1" mainnet-chain-20261005t124021z mainnet-chain-; do
  mkdir -m 700 "$T/backups/$n"
  echo "mine" > "$T/backups/$n/node1.tgz"
done
run delete
check "a folder with another name is skipped, with the reason" eval \
  '[ "$code" -eq 0 ] && said "SKIP  mainnet-chain-latest: the name is not one the reset script makes." && said "SKIP  $OLD1.bak:"'
check "every folder with another name is still there, with its file" eval \
  'there mainnet-chain-latest/node1.tgz && there "$OLD1.bak/node1.tgz" && there mainnet-chain-2026/node1.tgz && there "x$OLD1/node1.tgz" && there mainnet-chain-20261005t124021z/node1.tgz && there mainnet-chain-/node1.tgz'
check "the two good copies are deleted next to them" eval 'gone "$OLD1" && gone "$OLD2" && survivors'

# 5. a link, a plain file, and a folder that holds anything else: skipped, and what they point at is safe.
fresh
ln -s "$T/elsewhere" "$T/backups/mainnet-chain-20261001T000000Z"
echo "a file" > "$T/backups/mainnet-chain-20261002T000000Z"
ln -s "$T/nowhere" "$T/backups/mainnet-chain-20261003T000000Z"
run delete
check "a link to a folder is skipped, and its target is not touched" eval \
  '[ "$code" -eq 0 ] && said "SKIP  mainnet-chain-20261001T000000Z: it is not a plain directory." && [ -L "$T/backups/mainnet-chain-20261001T000000Z" ] && survivors'
check "a plain file with the right name is skipped" eval \
  'said "SKIP  mainnet-chain-20261002T000000Z: it is not a plain directory." && [ -s "$T/backups/mainnet-chain-20261002T000000Z" ]'
check "a link to nothing is skipped" eval 'said "SKIP  mainnet-chain-20261003T000000Z:" && [ -L "$T/backups/mainnet-chain-20261003T000000Z" ]'
check "and the good copies are deleted next to them" eval 'gone "$OLD1" && gone "$OLD2"'

fresh
mkdir -m 700 "$T/backups/mainnet-chain-20261004T000000Z"
echo "an archive" | gzip > "$T/backups/mainnet-chain-20261004T000000Z/node1.tgz"
echo "my notes" > "$T/backups/mainnet-chain-20261004T000000Z/notes.txt"
make_copy mainnet-chain-20261005T000000Z
mkdir "$T/backups/mainnet-chain-20261005T000000Z/sub"
echo "inner" > "$T/backups/mainnet-chain-20261005T000000Z/sub/node1.tgz"
make_copy mainnet-chain-20261006T000000Z
rm "$T/backups/mainnet-chain-20261006T000000Z/README"
mkdir -p "$T/backups/mainnet-chain-20261006T000000Z/README"
echo "inner" > "$T/backups/mainnet-chain-20261006T000000Z/README/x"
make_copy mainnet-chain-20261007T000000Z
rm "$T/backups/mainnet-chain-20261007T000000Z/node2.tgz"
ln -s "$T/elsewhere/keep.txt" "$T/backups/mainnet-chain-20261007T000000Z/node2.tgz"
run delete
check "a copy with an extra file is skipped, and the file is kept" eval \
  '[ "$code" -eq 0 ] && said "SKIP  mainnet-chain-20261004T000000Z: it holds something the reset script does not write (notes.txt)" && there mainnet-chain-20261004T000000Z/notes.txt && there mainnet-chain-20261004T000000Z/node1.tgz'
check "a copy with a subfolder is skipped" eval \
  'said "SKIP  mainnet-chain-20261005T000000Z: it holds something" && there mainnet-chain-20261005T000000Z/sub/node1.tgz && there mainnet-chain-20261005T000000Z/node1.tgz'
check "a copy whose README is a folder is skipped" eval \
  'said "SKIP  mainnet-chain-20261006T000000Z: it holds something" && there mainnet-chain-20261006T000000Z/README/x'
check "a copy with a link named like an archive is skipped, and the link target is kept" eval \
  'said "SKIP  mainnet-chain-20261007T000000Z: it holds something" && [ -L "$T/backups/mainnet-chain-20261007T000000Z/node2.tgz" ] && survivors'
check "the two good copies are deleted next to all of them" eval 'gone "$OLD1" && gone "$OLD2"'
check "the summary counts the skipped ones" eval 'said "deleted 2 copies" && said "4 skipped"'

# 6. a copy the reset script did not finish (it stopped in the middle) is still its own: deleted.
fresh
mkdir -m 700 "$T/backups/mainnet-chain-20261008T000000Z"
echo "an archive" | gzip > "$T/backups/mainnet-chain-20261008T000000Z/node1.tgz"
mkdir -m 700 "$T/backups/mainnet-chain-20261009T000000Z"
run delete
check "a half-made copy, and an empty one, are deleted too" eval \
  '[ "$code" -eq 0 ] && said "deleted 4 copies" && gone mainnet-chain-20261008T000000Z && gone mainnet-chain-20261009T000000Z && survivors'

# 7. no backups folder, and an empty one.
fresh; rm -rf "$T/backups"
run delete
check "no backups folder: nothing to do, and it succeeds" eval '[ "$code" -eq 0 ] && said "nothing to do" && [ ! -e "$T/backups" ]'
fresh; rm -rf "$T/backups"; mkdir "$T/backups"
run delete
check "an empty backups folder: finds nothing and succeeds" eval '[ "$code" -eq 0 ] && said "deleted 0 copies"'
run check
check "an empty backups folder in check mode: finds nothing and succeeds" eval '[ "$code" -eq 0 ] && said "0 copies would be deleted"'

# 8. the mode is one of two words.
fresh
before=$(snapshot)
run oops
check "a mode that is neither check nor delete stops it" eval '[ "$code" -eq 1 ] && said "MODE must be check or delete" && [ "$(snapshot)" = "$before" ]'
code=0
out=$(env -i PATH="$T/bin:$PATH" FAKE_CALLS="$T/calls" bash "$T/scripts/delete-old-chain-copies.sh" 2>&1) || code=$?
check "no mode at all stops it" eval '[ "$code" -ne 0 ] && [ "$(snapshot)" = "$before" ]'
run ""
check "an empty mode stops it" eval '[ "$code" -ne 0 ] && [ "$(snapshot)" = "$before" ]'

echo ""
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
