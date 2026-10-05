#!/usr/bin/env bash
# Self-check for set-pilot-allowlist.sh, against fixture env files in a temp directory. CI runs it
# (test-treasury-scripts.yml) with no docker, no host and no network: the script writes one line of an
# env file and restarts nothing.
set -euo pipefail
cd "$(dirname "$0")/.."

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/scripts"
cp scripts/set-pilot-allowlist.sh "$T/scripts/"

passed=0
failed=0
out=""
code=0

A1=0x00000000000000000000000000000000000000a1
B2=0x00000000000000000000000000000000000000b2

# check <name> <condition...>: the condition is a command; its exit status is the verdict.
check() {
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

# run <list>: the script in $T, with nothing from this environment but PATH and the list.
run() {
  code=0
  out=$(env -i PATH="$PATH" PILOT_ALLOWED_ADDRESSES="$1" bash "$T/scripts/set-pilot-allowlist.sh" 2>&1) || code=$?
}

said() { printf '%s' "$out" | grep -qF -- "$1"; }
has_line() { grep -qxF -- "$1" "$T/.env.mainnet"; }
unchanged() { cmp -s "$T/.env.mainnet" "$T/before" && [ ! -e "$T/.env.mainnet.bak" ]; }

fresh() {  # fresh <lines...>: a new .env.mainnet of these lines, no newline at the end, and no backup
  rm -f "$T/.env.mainnet" "$T/.env.mainnet.bak"
  printf '%s\n' "$@" > "$T/.env.mainnet"
  truncate -s -1 "$T/.env.mainnet"
  cp "$T/.env.mainnet" "$T/before"
}

# 1. A file as the maintainer left it: other settings, no line of ours, no newline at the end. A
#    mixed-case address is written in lower case, the count is said and the address is not.
fresh UNRELATED=keep-me SIGNER_TOKEN=secret-marker-9c1d LAST_LINE=1
chmod 644 "$T/.env.mainnet"
run "0x00000000000000000000000000000000000000A1"
check "one address is written, in lower case" eval '[ "$code" -eq 0 ] && has_line "PILOT_ALLOWED_ADDRESSES=$A1"'
check "the other lines are untouched, and the last one keeps its own line" eval 'has_line UNRELATED=keep-me && has_line SIGNER_TOKEN=secret-marker-9c1d && has_line LAST_LINE=1'
check "the count is said, was absent" eval 'said "was absent, now 1 address(es)"'
check "the address is never printed" eval '! said "$A1" && ! said "00000000000000000000000000000000000000A1"'
check "the file as it was is kept in .env.mainnet.bak" cmp -s "$T/.env.mainnet.bak" "$T/before"
check "the file and its backup are mode 600" eval '[ "$(stat -c %a "$T/.env.mainnet" "$T/.env.mainnet.bak" | tr "\n" " ")" = "600 600 " ]'
check "it says that nothing was restarted" said "Nothing was restarted"

# 2. A second run on its own result changes nothing.
cp "$T/.env.mainnet" "$T/after-first"
run "$A1"
check "a second run changes nothing" eval '[ "$code" -eq 0 ] && cmp -s "$T/.env.mainnet" "$T/after-first"'
check "a second run says it was already set" said "was set, now 1 address(es)"

# 3. Two addresses, and a list the file already has twice: both copies are replaced.
fresh UNRELATED=keep-me PILOT_ALLOWED_ADDRESSES=0xold1 PILOT_ALLOWED_ADDRESSES=0xold2
run "$A1,$B2"
check "two addresses are written in order and counted" eval '[ "$code" -eq 0 ] && said "now 2 address(es)" && [ "$(grep -cx "PILOT_ALLOWED_ADDRESSES=$A1,$B2" "$T/.env.mainnet")" -eq 2 ]'
check "no old value is left" eval '! grep -q "0xold" "$T/.env.mainnet"'

# 4. A blank line of ours is filled.
fresh UNRELATED=keep-me PILOT_ALLOWED_ADDRESSES=
run "$A1"
check "a blank setting is filled, and said to have been blank" eval '[ "$code" -eq 0 ] && said "was blank" && has_line "PILOT_ALLOWED_ADDRESSES=$A1"'

# 5. A star is everyone, written as a star, with a warning.
fresh UNRELATED=keep-me
run '*'
check "a star is written as a star" eval '[ "$code" -eq 0 ] && has_line "PILOT_ALLOWED_ADDRESSES=*"'
check "a star says everyone, and warns" eval 'said "now everyone" && said "WARNING: * means EVERY account"'

# 6. Refused, and the file untouched, with no backup: empty, too short, no 0x, a space, a trailing
#    comma, a comma first, a non-hex character, too long.
for bad in "" 0x00a1 "${A1#0x}" "$A1, $B2" "$A1," ",$A1" "0x0000000000000000000000000000000000000zzz" "${A1}00" "everyone"; do
  fresh UNRELATED=keep-me
  run "$bad"
  check "refused, nothing written: '${bad:0:12}'" eval '[ "$code" -eq 1 ] && unchanged'
done
fresh UNRELATED=keep-me
run ""
check "an empty list says how to set the secret" said "gh secret set PILOT_ALLOWED_ADDRESSES"
fresh UNRELATED=keep-me
run "0x00a1"
check "a malformed list says what is accepted" said "neither * nor a comma-separated list of 0x addresses"

# 7. No file.
rm -f "$T/.env.mainnet" "$T/.env.mainnet.bak"
run "$A1"
check "no .env.mainnet: refused" eval '[ "$code" -eq 1 ] && said "no .env.mainnet here" && [ ! -e "$T/.env.mainnet" ]'

echo ""
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
