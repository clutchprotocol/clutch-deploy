#!/usr/bin/env bash
# Self-check for mainnet-mint-key.sh. CI runs it (test-treasury-scripts.yml) with a fake `docker` that
# writes a known key file, fixture env files in a temp directory, no host and no network. It checks
# what matters about a script that writes a secret: the key is written once and never replaced, the
# other lines survive, the file stays mode 600, and the secret is never printed.
set -euo pipefail
cd "$(dirname "$0")/.."

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/scripts" "$T/bin" "$T/tmp"
cp scripts/mainnet-mint-key.sh "$T/scripts/"
printf '#!/usr/bin/env bash\necho sha-1234567\n' > "$T/scripts/set-image.sh"

SECRET=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
ADDRESS=0x00000000000000000000000000000000000000c3
ENVF="$T/.env.mainnet"

# The fake: `pull` does nothing, `run` writes the file ceremony-check would write into the directory
# mounted with -v, and every call is counted. It prints an address line, as the real tool does.
cat > "$T/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "$1" >> "$FAKE_CALLS"
case "$1" in
  pull) exit 0 ;;
  run)
    shift
    host=""
    while [ $# -gt 0 ]; do
      case "$1" in -v) host="${2%%:*}"; shift 2 ;; *) shift ;; esac
    done
    printf '1 %s %s\n' "$FAKE_ADDRESS" "$FAKE_SECRET" > "$host/key"
    echo "node1: $FAKE_ADDRESS"
    ;;
  *) echo "fake docker: unexpected call: $*" >&2; exit 99 ;;
esac
EOF
chmod +x "$T/bin/docker"

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

run() {  # run [<secret the fake writes>]: the script in $T, with PATH, the fake's values and the file name
  code=0
  out=$(env -i PATH="$T/bin:$PATH" TMPDIR="$T/tmp" ENV_FILE="$ENVF" FAKE_CALLS="$T/calls" FAKE_ADDRESS="$ADDRESS" \
          FAKE_SECRET="${1:-$SECRET}" bash "$T/scripts/mainnet-mint-key.sh" 2>&1) || code=$?
}

said() { printf '%s' "$out" | grep -qF -- "$1"; }
has_line() { grep -qxF -- "$1" "$ENVF"; }
unchanged() { cmp -s "$ENVF" "$T/before"; }
docker_calls() { { cat "$T/calls" 2>/dev/null || true; } | grep -c . || true; }

fresh() {  # fresh <lines...>: a new .env.mainnet of these lines with no newline at the end, and no backup
  rm -f "$ENVF" "$ENVF.bak" "$T/calls"
  printf '%s\n' "$@" > "$ENVF"
  truncate -s -1 "$ENVF"
  chmod 600 "$ENVF"
  cp "$ENVF" "$T/before"
}

# 1. The file as the template left it: the placeholder, a mnemonic with spaces, no newline at the end.
fresh UNRELATED=keep-me "DEPOSIT_MNEMONIC=word one word two" MINT_AUTHORITY_SECRET=unused-this-chain-signs-with-kms LAST_LINE=1
run
check "the key and its address are written, and the script succeeds" eval '[ "$code" -eq 0 ] && has_line "MINT_AUTHORITY_SECRET=$SECRET" && has_line "MINT_AUTHORITY_ADDRESS=$ADDRESS"'
check "the placeholder is gone, and the key is there once" eval '! has_line MINT_AUTHORITY_SECRET=unused-this-chain-signs-with-kms && [ "$(grep -c "^MINT_AUTHORITY_SECRET=" "$ENVF")" -eq 1 ]'
check "the other lines are untouched, and the last one keeps its own line" eval 'has_line UNRELATED=keep-me && has_line "DEPOSIT_MNEMONIC=word one word two" && has_line LAST_LINE=1'
check "the file is still mode 600" eval '[ "$(stat -c %a "$ENVF")" = 600 ]'
check "the file as it was is kept in .env.mainnet.bak, mode 600" eval 'cmp -s "$ENVF.bak" "$T/before" && [ "$(stat -c %a "$ENVF.bak")" = 600 ]'
check "the address is printed" eval 'said "mint address: $ADDRESS"'
check "the secret is never printed" eval '! said "$SECRET"'
check "the key file the tool wrote is removed" eval '[ -z "$(find "$T/tmp" -mindepth 1)" ]'

# 2. Run again: the key is left alone, the address is printed again and the tool is not called.
cp "$ENVF" "$T/before"
calls_before=$(docker_calls)
run "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
check "a second run changes nothing and succeeds" eval '[ "$code" -eq 0 ] && unchanged && said "already exists"'
check "a second run prints the address, and no secret" eval 'said "mint address: $ADDRESS" && ! said "$SECRET" && ! said ffffffffffffffff'
check "a second run does not call docker" eval '[ "$(docker_calls)" -eq "$calls_before" ]'

# 3. No line at all: the two lines are appended.
fresh UNRELATED=keep-me
run
check "with no line at all the key is appended" eval '[ "$code" -eq 0 ] && has_line "MINT_AUTHORITY_SECRET=$SECRET" && has_line UNRELATED=keep-me'

# 4. An empty line counts as no key, and an old address line is replaced with the new one.
fresh UNRELATED=keep-me MINT_AUTHORITY_SECRET= MINT_AUTHORITY_ADDRESS=0x00000000000000000000000000000000000000aa
run
check "an empty key line and a stale address line are replaced" eval '[ "$code" -eq 0 ] && has_line "MINT_AUTHORITY_SECRET=$SECRET" && has_line "MINT_AUTHORITY_ADDRESS=$ADDRESS" && ! grep -q 000000aa "$ENVF"'

# 5. A key with no address: refused, and the file is untouched.
fresh UNRELATED=keep-me "MINT_AUTHORITY_SECRET=$SECRET"
run
check "a key without its address is refused" eval '[ "$code" -eq 1 ] && said "its address was" && unchanged'

# 6. A value that is not a key: refused, and the file is untouched.
fresh UNRELATED=keep-me MINT_AUTHORITY_SECRET=abc
run
check "a value that is not a key is refused" eval '[ "$code" -eq 1 ] && said "neither a 64-character hex key" && unchanged && [ ! -e "$ENVF.bak" ]'

# 7. The tool gives back something that is not a key: refused, nothing written, no backup.
fresh UNRELATED=keep-me MINT_AUTHORITY_SECRET=unused-this-chain-signs-with-kms
run "abcd"
check "a short key from the tool is refused, nothing written" eval '[ "$code" -eq 1 ] && said "did not produce" && unchanged && [ ! -e "$ENVF.bak" ]'

# 8. No file.
rm -f "$ENVF"
run
check "no .env.mainnet is refused" eval '[ "$code" -eq 1 ] && said "no $ENVF here"'

echo ""
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
