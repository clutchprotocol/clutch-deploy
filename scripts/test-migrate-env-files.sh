#!/usr/bin/env bash
#
# Self-check for migrate-env-files.sh, the one-time split of the host's .env into .env.testnet and
# .env.mainnet. CI runs it (test-treasury-scripts.yml). It needs `docker compose`, which the script
# uses to render each project before and after; no daemon, no containers.

set -uo pipefail
cd "$(dirname "$0")/.."
REPO=$(pwd)
docker compose version >/dev/null 2>&1 || { echo "docker compose is not installed"; exit 1; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
pass=0
fail=0
ok()  { pass=$((pass + 1)); echo "  ok   $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/       | /'; }

# The values, all fake. What each network should end with:
cat > "$T/want.testnet" <<'EOF'
SEQ_API_KEY=seq-key-1
SEQ_ADMIN_PASSWORD=seq-admin-1
GRAFANA_ADMIN_PASSWORD=grafana-1
JWT_SECRET=jwt-testnet-1
ALLOWED_ORIGINS=https://app-stage.example
EXPLORER_POSTGRES_PASSWORD=explorer-1
TREASURY_POSTGRES_PASSWORD=tpg-testnet
ORCHESTRATOR_POSTGRES_PASSWORD=opg-testnet
MINT_AUTHORITY_SECRET=1111111111111111111111111111111111111111111111111111111111111111
TREASURY_INITIATOR_TOKEN=init-testnet
TREASURY_APPROVER_TOKEN=appr-testnet
TREASURY_READONLY_TOKEN=ro-testnet
SIGNER_TOKEN=signer-testnet
DEPOSIT_MNEMONIC=testnet words go here
CUSTODY_TRON_ADDRESS=TTestnetCustody
DEPOSIT_ACCOUNT_XPUB=xpub-testnet
EOF
# .env.mainnet as it is before the split: the example's settings plus the treasury's.
{
  sed -e 's/#.*//' -e '/^[[:space:]]*$/d' .env.mainnet.example
  cat <<'EOF'
CUSTODY_TRON_ADDRESS=TMainnetCustody
MINT_AUTHORITY_SECRET=2222222222222222222222222222222222222222222222222222222222222222
DEPOSIT_MNEMONIC=mainnet words go here
DEPOSIT_ACCOUNT_XPUB=xpub-mainnet
SIGNER_TOKEN=signer-mainnet
TREASURY_INITIATOR_TOKEN=init-mainnet
TREASURY_APPROVER_TOKEN=appr-mainnet
TREASURY_READONLY_TOKEN=ro-mainnet
TREASURY_POSTGRES_PASSWORD=tpg-mainnet
ORCHESTRATOR_POSTGRES_PASSWORD=opg-mainnet
JWT_SECRET=jwt-mainnet-1
PAYOUT_FLOAT_ADDRESS=TMainnetFloat
PILOT_ALLOWED_ADDRESSES=*
BACKUP_PASSPHRASE=pass-mainnet
EOF
} | grep -v '^CUSTODY_TRON_ADDRESS=$' > "$T/old.mainnet"
MAINNET_KEYS='MAINNET_NODE1_AUTHOR_SECRET=aaaa1
MAINNET_NODE2_AUTHOR_SECRET=aaaa2
MAINNET_NODE3_AUTHOR_SECRET=aaaa3
MAINNET_EXPLORER_POSTGRES_PASSWORD=mexp-1'
# The old shared .env: the testnet's settings plus the mainnet chain's.
{ cat "$T/want.testnet"; printf '%s\n' "$MAINNET_KEYS" "MAINNET_JWT_SECRET=jwt-mainnet-1"; } > "$T/old.env"
# What .env.mainnet should hold after the split.
{ cat "$T/old.mainnet"; printf '%s\n' "$MAINNET_KEYS" "SEQ_API_KEY=seq-key-1"; } > "$T/want.mainnet"

# fresh: a copy of the repo with the two old files.
fresh() {
  W="$T/w"
  rm -rf "$W"
  mkdir -p "$W"
  (cd "$REPO" && git ls-files -z | xargs -0 cp --parents -t "$W" 2>/dev/null)
  cp scripts/migrate-env-files.sh "$W/scripts/"
  cp "$T/old.env" "$W/.env"
  cp "$T/old.mainnet" "$W/.env.mainnet"
  chmod 600 "$W/.env" "$W/.env.mainnet"
}
run() { (cd "$W" && bash scripts/migrate-env-files.sh 2>&1); }
val() { sed -n "s/^$2=//p" "$W/$1" | tail -1; }
unchanged() { cmp -s "$W/.env" "$T/old.env" && cmp -s "$W/.env.mainnet" "$1" && [ ! -e "$W/.env.testnet" ]; }

echo "== the split =="
fresh
out=$(run); code=$?
[ "$code" -eq 0 ] && ok "it succeeds when nothing would change" || bad "it succeeds when nothing would change" "$out"
[ ! -e "$W/.env" ] && ok ".env is gone" || bad ".env is gone"
[ -f "$W/.env.testnet" ] && [ "$(stat -c %a "$W/.env.testnet")" = 600 ] && ok ".env.testnet is written, mode 600" || bad ".env.testnet is written, mode 600"
[ "$(stat -c %a "$W/.env.mainnet")" = 600 ] && ok ".env.mainnet keeps mode 600" || bad ".env.mainnet keeps mode 600"
grep -q '^MAINNET_' "$W/.env.testnet" && bad ".env.testnet has no MAINNET_ key" || ok ".env.testnet has no MAINNET_ key"
cmp -s "$W/.env.testnet" "$T/want.testnet" && ok ".env.testnet is the testnet's settings, unchanged" || bad ".env.testnet is the testnet's settings, unchanged" "$(diff "$T/want.testnet" "$W/.env.testnet")"
for k in MAINNET_NODE1_AUTHOR_SECRET MAINNET_NODE2_AUTHOR_SECRET MAINNET_NODE3_AUTHOR_SECRET MAINNET_EXPLORER_POSTGRES_PASSWORD SEQ_API_KEY; do
  [ "$(val .env.mainnet "$k")" = "$(sed -n "s/^$k=//p" "$T/want.mainnet" | tail -1)" ] && ok "$k is in .env.mainnet" || bad "$k is in .env.mainnet"
done
[ "$(grep -c '^JWT_SECRET=' "$W/.env.mainnet")" = 1 ] && [ "$(val .env.mainnet JWT_SECRET)" = jwt-mainnet-1 ] && ok "JWT_SECRET is there once, unchanged" || bad "JWT_SECRET is there once, unchanged"
grep -q '^MAINNET_JWT_SECRET=' "$W/.env.mainnet" && bad "MAINNET_JWT_SECRET is not carried over" || ok "MAINNET_JWT_SECRET is not carried over"
bk=$(ls -d "$W"/backups/env-split-* 2>/dev/null | head -1)
[ -n "$bk" ] && [ "$(stat -c %a "$bk")" = 700 ] && cmp -s "$bk/.env" "$T/old.env" && cmp -s "$bk/.env.mainnet" "$T/old.mainnet" \
  && ok "both old files are in backups/env-split-*, mode 700" || bad "both old files are in backups/env-split-*, mode 700"
leak=""
for v in aaaa1 aaaa2 aaaa3 mexp-1 jwt-mainnet-1 jwt-testnet-1 seq-key-1 "testnet words" "mainnet words"; do
  printf '%s' "$out" | grep -qF "$v" && leak="$leak $v"
done
[ -z "$leak" ] && ok "no value is printed" || bad "no value is printed:$leak"
out=$(run); code=$?
[ "$code" -eq 0 ] && printf '%s' "$out" | grep -q 'already split' && ok "a second run changes nothing" || bad "a second run changes nothing" "$out"

echo "== refusals: nothing is written =="
fresh
sed -i 's/^MAINNET_JWT_SECRET=.*/MAINNET_JWT_SECRET=jwt-other/' "$W/.env"; cp "$W/.env" "$T/old.env.x"
out=$(run); code=$?
[ "$code" -ne 0 ] && printf '%s' "$out" | grep -q 'JWT_SECRET is set in both files with different values' && cmp -s "$W/.env" "$T/old.env.x" && cmp -s "$W/.env.mainnet" "$T/old.mainnet" && [ ! -e "$W/.env.testnet" ] \
  && ok "the hub's and the orchestrator's JWT secrets differ" || bad "the hub's and the orchestrator's JWT secrets differ" "$out"

fresh
echo "MAINNET_SOMETHING_NEW=x" >> "$W/.env"; cp "$W/.env" "$T/old.env.x"
out=$(run); code=$?
[ "$code" -ne 0 ] && printf '%s' "$out" | grep -q 'unexpected mainnet setting(s) in .env, not moved automatically: MAINNET_SOMETHING_NEW' && cmp -s "$W/.env" "$T/old.env.x" && [ ! -e "$W/.env.testnet" ] \
  && ok "an unknown MAINNET_ name" || bad "an unknown MAINNET_ name" "$out"

fresh
sed -i 's/^MAINNET_NODE2_AUTHOR_SECRET=.*/MAINNET_NODE2_AUTHOR_SECRET="aaaa2 #x"/' "$W/.env"; cp "$W/.env" "$T/old.env.x"
out=$(run); code=$?
[ "$code" -ne 0 ] && printf '%s' "$out" | grep -q 'MAINNET_NODE2_AUTHOR_SECRET in .env is not a plain value' && cmp -s "$W/.env" "$T/old.env.x" && [ ! -e "$W/.env.testnet" ] \
  && ok "a value that cannot be a plain line is not moved" || bad "a value that cannot be a plain line is not moved" "$out"

echo "== a quoted value moves as the value compose read =="

fresh
sed -i 's/^MAINNET_NODE2_AUTHOR_SECRET=.*/MAINNET_NODE2_AUTHOR_SECRET="aaaa2"/' "$W/.env"
out=$(run); code=$?
[ "$code" -eq 0 ] && [ "$(val .env.mainnet MAINNET_NODE2_AUTHOR_SECRET)" = aaaa2 ] \
  && ok "it is written without the quotes" || bad "it is written without the quotes" "$out"

echo "== refusals: a project would render differently =="
fresh
sed -i 's|^MAINNET_ALLOWED_ORIGINS=.*|MAINNET_ALLOWED_ORIGINS=https://other.example|' "$W/.env.mainnet"; cp "$W/.env.mainnet" "$T/old.mainnet.x"
out=$(run); code=$?
[ "$code" -ne 0 ] && printf '%s' "$out" | grep -q 'clutch-main/mainnet-hub-api: DIFFERENT: APP_ALLOWED_ORIGINS' && unchanged "$T/old.mainnet.x" \
  && ok "the mainnet hub would read another CORS list" || bad "the mainnet hub would read another CORS list" "$out"
printf '%s' "$out" | grep -qF 'other.example' && bad "the differing value is not printed" || ok "the differing value is not printed"

fresh
sed -i '/^MAINNET_JWT_SECRET=/d' "$W/.env"; sed -i 's/^JWT_SECRET=jwt-mainnet-1$/JWT_SECRET=jwt-mainnet-2/' "$W/.env.mainnet"
out=$(run); code=$?
[ "$code" -eq 0 ] && printf '%s' "$out" | grep -q 'clutch-main: did not render before the split, not compared' \
  && ok "a mainnet hub that had no secret before is not compared" || bad "a mainnet hub that had no secret before is not compared" "$out"

fresh
touch "$W/.env.testnet"
out=$(run); code=$?
[ "$code" -ne 0 ] && printf '%s' "$out" | grep -q 'both .env and .env.testnet exist' && cmp -s "$W/.env" "$T/old.env" && [ ! -s "$W/.env.testnet" ] \
  && ok "both .env and .env.testnet exist" || bad "both .env and .env.testnet exist" "$out"

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
