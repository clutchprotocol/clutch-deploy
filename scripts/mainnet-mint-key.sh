#!/usr/bin/env bash
#
# Create the MAINNET mint key, on this host, once. Run from the repo root on the stage host.
#
#   bash scripts/mainnet-mint-key.sh
#
# The mint key signs every mint on chain 1000. Since 2026-10-05 it is a plain secret in .env.mainnet
# and not an Azure KMS key (readiness A1, "Mint key on the host"). The key is made HERE, inside the
# treasury image's ceremony-check, and written straight into .env.mainnet. It never appears on this
# script's output, in a workflow log or in a file that is not mode 600. Only its ADDRESS is printed,
# because that is public: it goes into config/node-mainnet/*.toml as `mint_authority`, which is part
# of the genesis and cannot be changed on a running chain.
#
# Two lines are written, and only together:
#   MINT_AUTHORITY_SECRET=<64 hex characters>    what mainnet-treasury-service signs with
#   MINT_AUTHORITY_ADDRESS=<0x address>          its public address, so a later step can check the node
#                                                configs against it before anything irreversible
#
# It never replaces a key. A key that exists is left alone and its address is printed again, because
# replacing it would strand every mint after the genesis that names the old address. The placeholder
# the old template carried (a non-hex value) or an empty line counts as no key.
#
# Back the secret up somewhere that is not this host. If it is lost, no CLT can ever be minted on
# this chain again.

set -euo pipefail
cd "$(dirname "$0")/.."

ENV_FILE="${ENV_FILE:-.env.mainnet}"
PLACEHOLDER=unused-this-chain-signs-with-kms

[ -f "$ENV_FILE" ] || { echo "ABORT: no $ENV_FILE here ($(pwd))."; exit 1; }

# Read with sed, never by sourcing the file: it holds a mnemonic with spaces in it.
secret=$(sed -n 's/^MINT_AUTHORITY_SECRET=//p' "$ENV_FILE" | head -1)
address=$(sed -n 's/^MINT_AUTHORITY_ADDRESS=//p' "$ENV_FILE" | head -1)

if printf '%s' "$secret" | grep -Eq '^[0-9a-f]{64}$'; then
  echo "The mint key already exists in $ENV_FILE. Nothing was changed."
  if printf '%s' "$address" | grep -Eq '^0x[0-9a-f]{40}$'; then
    echo "mint address: $address"
  else
    echo "ABORT: MINT_AUTHORITY_ADDRESS is missing or not an address. The key is there but its address was"
    echo "  not recorded. Do not replace the key: read the address off a running treasury-service instead."
    exit 1
  fi
  exit 0
fi
case "$secret" in
  ''|"$PLACEHOLDER") ;;
  *)
    echo "ABORT: MINT_AUTHORITY_SECRET in $ENV_FILE is neither a 64-character hex key nor empty nor the"
    echo "  old placeholder. Nothing was changed."
    exit 1 ;;
esac

image="ghcr.io/clutchprotocol/clutch-treasury:$(bash scripts/set-image.sh mainnet clutch-treasury)"
docker pull -q "$image" >/dev/null

work=$(mktemp -d)
trap 'shred -u "$work/key" 2>/dev/null || rm -f "$work/key"; rmdir "$work" 2>/dev/null || true' EXIT

# Run as the invoking user so the key file is readable here and not left owned by root. The addresses
# it prints are not used: the file has the address and the secret from one keypair, and that is read.
docker run --rm --user "$(id -u):$(id -g)" -v "$work:/out" "$image" \
  ceremony-check validator-keys 1 /out/key >/dev/null

read -r _ new_address new_secret < "$work/key"
if ! printf '%s' "$new_address" | grep -Eq '^0x[0-9a-f]{40}$' \
   || ! printf '%s' "$new_secret" | grep -Eq '^[0-9a-f]{64}$'; then
  echo "ABORT: ceremony-check did not produce an address and a 64-character key. Nothing was changed."
  exit 1
fi

# A new file, then a rename: the secret is only ever an argument of printf, a shell builtin, so it is
# not in any process list. The new file starts at mode 600 and the rename keeps it.
cp -a "$ENV_FILE" "$ENV_FILE.bak"
chmod 600 "$ENV_FILE.bak"
tmp=$(mktemp "$ENV_FILE.XXXXXX")
chmod 600 "$tmp"
{ grep -vE '^(MINT_AUTHORITY_SECRET|MINT_AUTHORITY_ADDRESS)=' "$ENV_FILE" || true; } > "$tmp"
if [ -s "$tmp" ] && [ -n "$(tail -c1 "$tmp")" ]; then echo >> "$tmp"; fi
printf 'MINT_AUTHORITY_SECRET=%s\nMINT_AUTHORITY_ADDRESS=%s\n' "$new_secret" "$new_address" >> "$tmp"
mv "$tmp" "$ENV_FILE"

echo "The mint key was created and written to $ENV_FILE (mode 600). The secret is not printed."
echo "mint address: $new_address"
echo ""
echo "Next:"
echo "  1. Put that address in config/node-mainnet/node1.toml, node2.toml and node3.toml as mint_authority,"
echo "     the same in all three."
echo "  2. Back the secret up somewhere that is not this host. On the host: grep ^MINT_AUTHORITY_SECRET $ENV_FILE"
