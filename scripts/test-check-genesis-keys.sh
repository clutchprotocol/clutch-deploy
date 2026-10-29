#!/usr/bin/env bash
# Self-check for the key rules in check-genesis.sh: a node config outside config/node (stage, mainnet)
# must hold no secret, must hold real addresses, and must not reuse an address whose key is public in
# config/node. A rule that cannot fail proves nothing, so most cases here are configs it must REFUSE,
# each broken in exactly one way and each checked for the message of that rule.
#
#   bash scripts/test-check-genesis-keys.sh
set -euo pipefail
cd "$(dirname "$0")/.."

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0

# check <label> <pass|fail> <config dir> [<text the failure must contain>]
check() {
  local label="$1" want="$2" dir="$3" must="${4:-}" rc=0
  CONFIG_DIR="$dir" bash scripts/check-genesis.sh >"$T/out" 2>&1 || rc=$?
  if [ "$want" = pass ] && [ "$rc" -eq 0 ]; then
    printf 'PASS  %s\n' "$label"
  elif [ "$want" = fail ] && [ "$rc" -ne 0 ] && grep -qF -- "$must" "$T/out"; then
    printf 'PASS  %s\n' "$label"
  else
    printf 'FAIL  %s (wanted %s, exit %s)\n' "$label" "$want" "$rc"
    sed 's/^/        /' "$T/out" | tail -12
    fails=1
  fi
}

# A valid non-dev config to break one way at a time: the mainnet one.
copy() { rm -rf "${T:?}/$1"; cp -r config/node-mainnet "$T/$1"; }
addr() { sed -n "s/^$2 = \"\(0x[0-9a-f]\{40\}\)\".*/\1/p" "$1" | head -1; }

dev_key=$(addr config/node/node1.toml author_public_key)
main_key=$(addr config/node-mainnet/node1.toml author_public_key)
[ -n "$dev_key" ] && [ -n "$main_key" ] || { echo "FAIL  could not read the two node1 addresses"; exit 1; }

check "the dev set may hold public secrets"      pass config/node
check "the mainnet config is clean"              pass config/node-mainnet

copy secret
sed -i 's/^author_secret_key = ""/author_secret_key = "00"/' "$T/secret/node1.toml"
check "a committed secret is refused"            fail "$T/secret" "author_secret_key is set"

copy dev
sed -i "s/$main_key/$dev_key/g" "$T"/dev/*.toml
check "a dev address is refused"                 fail "$T/dev" "address from the public dev set"

copy placeholder
sed -i "s/$main_key/0xREPLACE_ME/g" "$T"/placeholder/*.toml
check "a placeholder address is refused"         fail "$T/placeholder" "is not 0x + 40 hex"

copy outside
sed -i "s/^author_public_key = .*/author_public_key = \"0x$(printf '1%.0s' $(seq 40))\"/" "$T/outside/node1.toml"
check "a key outside its authorities is refused" fail "$T/outside" "is not in its authorities list"

if [ "$fails" -eq 0 ]; then
  echo "All cases behaved."
else
  echo "A key rule did not behave."
  exit 1
fi
