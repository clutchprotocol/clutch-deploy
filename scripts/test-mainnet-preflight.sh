#!/usr/bin/env bash
# Self-check for the mainnet preflight: each way a mainnet treasury start should be refused, by exit
# code and by the line printed, and that no secret value is ever printed. CI runs it
# (test-treasury-scripts.yml) with fixture env files in a temp directory: no docker, no host.
set -euo pipefail
cd "$(dirname "$0")/.."

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

passed=0
failed=0

# The stage file: only what the separation checks compare.
cat > "$T/stage.env.base" <<'EOF'
MAINNET_JWT_SECRET=jwt-mainnet-x
JWT_SECRET=jwt-stage-y
DEPOSIT_MNEMONIC=stage mnemonic words
DEPOSIT_ACCOUNT_XPUB=xpub6Cstage
CUSTODY_TRON_ADDRESS=TStageCustody
SIGNER_TOKEN=stage-signer
TREASURY_INITIATOR_TOKEN=stage-i
TREASURY_APPROVER_TOKEN=stage-a
TREASURY_READONLY_TOKEN=stage-r
TREASURY_POSTGRES_PASSWORD=stage-pg1
ORCHESTRATOR_POSTGRES_PASSWORD=stage-pg2
EOF

# A complete mainnet file that differs from the stage one everywhere it must.
cat > "$T/mainnet.env.base" <<'EOF'
CUSTODY_TRON_ADDRESS=TMainCustody
TRONGRID_URL=https://api.trongrid.io
USDT_CONTRACT=TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t
AZURE_TENANT_ID=tenant
AZURE_CLIENT_ID=client
AZURE_CLIENT_SECRET=client-secret-value
AZURE_VAULT_URL=https://v.vault.azure.net
AZURE_KEY_NAME=key
AZURE_KEY_VERSION=v1
DEPOSIT_MNEMONIC=mainnet mnemonic words
DEPOSIT_ACCOUNT_XPUB=xpub6Dmain
PAYOUT_FLOAT_ADDRESS=TMainFloat
SIGNER_TOKEN=main-signer
TREASURY_INITIATOR_TOKEN=main-i
TREASURY_APPROVER_TOKEN=main-a
TREASURY_READONLY_TOKEN=main-r
TREASURY_POSTGRES_PASSWORD=main-pg1
ORCHESTRATOR_POSTGRES_PASSWORD=main-pg2
JWT_SECRET=jwt-mainnet-x
BACKUP_PASSPHRASE=main-backup-pass
PER_TX_MINT_CAP_CLT=1000000000
DAILY_MINT_CAP_CLT=2000000000
MAX_REDEMPTION_CLT=200000000
MIN_REDEMPTION_CLT=25000000
PER_TX_PAYOUT_CAP_USDT=200000000
REDEMPTION_FEE_USDT=2000000
DAILY_PAYOUT_CAP_CLT=1000000000
EOF

. scripts/lib/mainnet-preflight.sh

# check <name> <expected exit code> <text the output must contain> <sed script for the mainnet file, or ''> [<sed script for the stage file>]
check() {
  local name="$1" want="$2" text="$3" msed="$4" ssed="${5:-}" out code=0
  cp "$T/mainnet.env.base" "$T/mainnet.env"
  cp "$T/stage.env.base" "$T/stage.env"
  [ -z "$msed" ] || sed -i -e "$msed" "$T/mainnet.env"
  [ -z "$ssed" ] || sed -i -e "$ssed" "$T/stage.env"
  chmod 600 "$T/mainnet.env" "$T/stage.env"
  out=$(preflight "$T/mainnet.env" "$T/stage.env" 2>&1) || code=$?
  if [ "$code" -eq "$want" ] && printf '%s' "$out" | grep -qF -- "$text"; then
    passed=$((passed + 1))
    echo "ok    $name"
  else
    failed=$((failed + 1))
    echo "FAIL  $name: exit $code (wanted $want), wanted the text: $text"
    printf '%s\n' "$out" | sed 's/^/        /'
  fi
}

check "a complete, separate mainnet file passes" 0 "every required setting is set" ''
check "a missing required setting fails" 1 "AZURE_KEY_VERSION is empty or missing" '/^AZURE_KEY_VERSION=/d'
check "an empty required setting fails" 1 "SIGNER_TOKEN is empty or missing" 's/^SIGNER_TOKEN=.*/SIGNER_TOKEN=/'
check "a missing limit fails" 1 "REDEMPTION_FEE_USDT is empty or missing" '/^REDEMPTION_FEE_USDT=/d'
check "a missing backup passphrase fails" 1 "BACKUP_PASSPHRASE is empty or missing" '/^BACKUP_PASSPHRASE=/d'
check "the Nile TronGrid fails" 1 "TRONGRID_URL is not https://api.trongrid.io" 's#^TRONGRID_URL=.*#TRONGRID_URL=https://nile.trongrid.io#'
check "the Nile USDT contract fails" 1 "USDT_CONTRACT is not the mainnet USDT contract" 's/^USDT_CONTRACT=.*/USDT_CONTRACT=TXYZopYRdj2D9XRtbG411XZZ3kM5VkAeBf/'
check "the stage mnemonic fails" 1 "DEPOSIT_MNEMONIC is the same in both files" 's/^DEPOSIT_MNEMONIC=.*/DEPOSIT_MNEMONIC=stage mnemonic words/'
check "the stage xpub fails" 1 "DEPOSIT_ACCOUNT_XPUB is the same in both files" 's/^DEPOSIT_ACCOUNT_XPUB=.*/DEPOSIT_ACCOUNT_XPUB=xpub6Cstage/'
check "the stage custody address fails" 1 "CUSTODY_TRON_ADDRESS is the same in both files" 's/^CUSTODY_TRON_ADDRESS=.*/CUSTODY_TRON_ADDRESS=TStageCustody/'
check "a stage token fails" 1 "SIGNER_TOKEN is the same in both files" 's/^SIGNER_TOKEN=.*/SIGNER_TOKEN=stage-signer/'
check "a stage database password fails" 1 "TREASURY_POSTGRES_PASSWORD is the same in both files" 's/^TREASURY_POSTGRES_PASSWORD=.*/TREASURY_POSTGRES_PASSWORD=stage-pg1/'
check "a JWT secret that is not the mainnet hub's fails" 1 "JWT_SECRET does not match MAINNET_JWT_SECRET" 's/^JWT_SECRET=.*/JWT_SECRET=something-else/'
check "the stage hub's JWT secret fails" 1 "JWT_SECRET is the same in both files" 's/^JWT_SECRET=.*/JWT_SECRET=jwt-stage-y/' 's/^MAINNET_JWT_SECRET=.*/MAINNET_JWT_SECRET=jwt-stage-y/'
check "a plaintext mint key fails" 1 "a plaintext mint key (MINT_AUTHORITY_SECRET) is in the mainnet file" \
  '$a MINT_AUTHORITY_SECRET=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
check "the non-hex placeholder is fine" 0 "no plaintext mint key" '$a MINT_AUTHORITY_SECRET=unused-this-chain-signs-with-kms'

# A mainnet file other users can read.
cp "$T/mainnet.env.base" "$T/mainnet.env"; cp "$T/stage.env.base" "$T/stage.env"
chmod 644 "$T/mainnet.env"; chmod 600 "$T/stage.env"
code=0; out=$(preflight "$T/mainnet.env" "$T/stage.env" 2>&1) || code=$?
if [ "$code" -eq 1 ] && printf '%s' "$out" | grep -qF "is readable by other users"; then
  passed=$((passed + 1)); echo "ok    a mainnet file other users can read fails"
else
  failed=$((failed + 1)); echo "FAIL  a mainnet file other users can read fails: exit $code"; printf '%s\n' "$out" | sed 's/^/        /'
fi

# Missing files.
code=0; out=$(preflight "$T/nope.env" "$T/stage.env" 2>&1) || code=$?
if [ "$code" -eq 1 ] && printf '%s' "$out" | grep -qF "nope.env does not exist"; then
  passed=$((passed + 1)); echo "ok    a missing mainnet file fails"
else
  failed=$((failed + 1)); echo "FAIL  a missing mainnet file fails: exit $code"; printf '%s\n' "$out" | sed 's/^/        /'
fi
chmod 600 "$T/mainnet.env"
code=0; out=$(preflight "$T/mainnet.env" "$T/nope-stage.env" 2>&1) || code=$?
if [ "$code" -eq 1 ] && printf '%s' "$out" | grep -qF "nope-stage.env does not exist"; then
  passed=$((passed + 1)); echo "ok    a missing stage file fails"
else
  failed=$((failed + 1)); echo "FAIL  a missing stage file fails: exit $code"; printf '%s\n' "$out" | sed 's/^/        /'
fi

# No value from either file is ever printed, even when the check that fails compares it.
cp "$T/mainnet.env.base" "$T/mainnet.env"; cp "$T/stage.env.base" "$T/stage.env"
sed -i -e 's/^DEPOSIT_MNEMONIC=.*/DEPOSIT_MNEMONIC=stage mnemonic words/' -e 's/^SIGNER_TOKEN=.*/SIGNER_TOKEN=stage-signer/' "$T/mainnet.env"
chmod 600 "$T/mainnet.env" "$T/stage.env"
code=0; out=$(preflight "$T/mainnet.env" "$T/stage.env" 2>&1) || code=$?
leak=""
for secret in "stage mnemonic words" "stage-signer" "main-i" "main-pg1" "jwt-mainnet-x" "client-secret-value" "mainnet mnemonic" "main-backup-pass"; do
  printf '%s' "$out" | grep -qF -- "$secret" && leak="$leak [$secret]"
done
if [ "$code" -eq 1 ] && [ -z "$leak" ]; then
  passed=$((passed + 1)); echo "ok    no value from either file is printed"
else
  failed=$((failed + 1)); echo "FAIL  no value from either file is printed: exit $code, printed:$leak"
fi

echo ""
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
