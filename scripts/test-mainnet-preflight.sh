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

# No value from either file is ever printed, even when the check that fails compares it, and
# neither is the content of a stray line, nor the part of one before its first "=" (a pasted secret
# with an "=" in it: the last stray line below has a mixed-case "name" and a blank value).
cp "$T/mainnet.env.base" "$T/mainnet.env"; cp "$T/stage.env.base" "$T/stage.env"
sed -i -e 's/^DEPOSIT_MNEMONIC=.*/DEPOSIT_MNEMONIC=stage mnemonic words/' -e 's/^SIGNER_TOKEN=.*/SIGNER_TOKEN=stage-signer/' "$T/mainnet.env"
echo "strayfragment+secret" >> "$T/mainnet.env"
echo "Abc123def= " >> "$T/mainnet.env"
chmod 600 "$T/mainnet.env" "$T/stage.env"
code=0; out=$(preflight "$T/mainnet.env" "$T/stage.env" 2>&1) || code=$?
leak=""
for secret in "stage mnemonic words" "stage-signer" "main-i" "main-pg1" "jwt-mainnet-x" "client-secret-value" "mainnet mnemonic" "main-backup-pass" "strayfragment+secret" "Abc123def"; do
  printf '%s' "$out" | grep -qF -- "$secret" && leak="$leak [$secret]"
done
if [ "$code" -eq 1 ] && [ -z "$leak" ]; then
  passed=$((passed + 1)); echo "ok    no value from either file is printed"
else
  failed=$((failed + 1)); echo "FAIL  no value from either file is printed: exit $code, printed:$leak"
fi

# A stage secret copied by hand from .env can differ in its raw text and still be the same secret to
# compose and to tron-signer: compose trims a value, cuts a " #" comment and uses the LAST of a
# duplicate name, and tron-signer reads any run of whitespace in the mnemonic as one space. So the
# preflight must read both files the way they will be read. (The replacement of the first case ends
# with a space, on purpose.)
check "a stage xpub with a trailing space fails" 1 "DEPOSIT_ACCOUNT_XPUB has leading or trailing whitespace" 's/^DEPOSIT_ACCOUNT_XPUB=.*/DEPOSIT_ACCOUNT_XPUB=xpub6Cstage /'
check "a single-quoted stage mnemonic fails" 1 "DEPOSIT_MNEMONIC starts with a quote" "s/^DEPOSIT_MNEMONIC=.*/DEPOSIT_MNEMONIC='stage mnemonic words'/"
check "a mnemonic with a double space fails" 1 "DEPOSIT_MNEMONIC is the same in both files" 's/^DEPOSIT_MNEMONIC=.*/DEPOSIT_MNEMONIC=stage  mnemonic words/'
check "a stray line fails" 1 "is not blank, a # comment, or NAME=value" '$a straypart+of+a+secret'
check "a name set twice fails" 1 "SIGNER_TOKEN is set more than once" '$a SIGNER_TOKEN=a-second-value'
# The stage side is read the way compose reads it: the quotes come off and the trailing space goes.
check "a quoted stage value with a space is still the same secret" 1 "DEPOSIT_MNEMONIC is the same in both files" \
  's/^DEPOSIT_MNEMONIC=.*/DEPOSIT_MNEMONIC=stage mnemonic words/' \
  's/^DEPOSIT_MNEMONIC=.*/DEPOSIT_MNEMONIC="stage mnemonic words" /'

# A mainnet file the group can read.
cp "$T/mainnet.env.base" "$T/mainnet.env"; cp "$T/stage.env.base" "$T/stage.env"
chmod 640 "$T/mainnet.env"; chmod 600 "$T/stage.env"
code=0; out=$(preflight "$T/mainnet.env" "$T/stage.env" 2>&1) || code=$?
if [ "$code" -eq 1 ] && printf '%s' "$out" | grep -qF "readable by other users or its group"; then
  passed=$((passed + 1)); echo "ok    a mainnet file the group can read fails"
else
  failed=$((failed + 1)); echo "FAIL  a mainnet file the group can read fails: exit $code"; printf '%s\n' "$out" | sed 's/^/        /'
fi

# Settings that must not be the stage ones, and the GasFree network.
check "the stage float address fails" 1 "PAYOUT_FLOAT_ADDRESS is the same in both files" '' '$a PAYOUT_FLOAT_ADDRESS=TMainFloat'
check "a GasFree network that is not mainnet fails" 1 "GASFREE_NETWORK is set and is not mainnet" '$a GASFREE_NETWORK=nile'
check "the stage backup remote fails" 1 "BACKUP_REMOTE is the same in both files" '$a BACKUP_REMOTE=r2:bucket' '$a BACKUP_REMOTE=r2:bucket'

# The template the operator copies passes the same line rule.
code=0; out=$(pf_lint .env.mainnet.example 2>&1) || code=$?
if [ "$code" -eq 0 ] && printf '%s' "$out" | grep -qF "each name once"; then
  passed=$((passed + 1)); echo "ok    the example file is well-formed"
else
  failed=$((failed + 1)); echo "FAIL  the example file is well-formed: exit $code"; printf '%s\n' "$out" | sed 's/^/        /'
fi

# One case for each of the other rules, with SIGNER_TOKEN standing for any setting (main-signer is the
# mainnet fixture's value, stage-signer the stage one). Cases 32 to 36 each break one rule of the
# mainnet file. The sed script of case 32 holds a backslash and an r, which GNU sed turns into a
# carriage return; those of cases 34 and 35 hold a dollar sign and a backtick, which stay literal
# inside single quotes.
check "a value with a carriage return fails" 1 "SIGNER_TOKEN has a carriage return" 's/^SIGNER_TOKEN=.*/&\r/'
check "a value with a space-hash comment fails" 1 "SIGNER_TOKEN contains a space-hash comment, a dollar sign or a backtick" 's/^SIGNER_TOKEN=.*/SIGNER_TOKEN=main-signer #old/'
check "a value with a dollar sign fails" 1 "SIGNER_TOKEN contains a space-hash comment, a dollar sign or a backtick" 's/^SIGNER_TOKEN=.*/SIGNER_TOKEN=main$signer/'
check "a value with a backtick fails" 1 "SIGNER_TOKEN contains a space-hash comment, a dollar sign or a backtick" 's/^SIGNER_TOKEN=.*/SIGNER_TOKEN=main`signer/'
check "a value with leading whitespace fails" 1 "SIGNER_TOKEN has leading or trailing whitespace" 's/^SIGNER_TOKEN=.*/SIGNER_TOKEN= main-signer/'
# Cases 37 to 39 are about the stage file, which compose reads by its own rules: it takes the LAST of
# a duplicated name, cuts a " #" comment and trims the value. The replacement of case 39 ends with a
# space, on purpose.
check "the last of a duplicated stage line is the one that counts" 1 "SIGNER_TOKEN is the same in both files" '' '$a SIGNER_TOKEN=main-signer'
check "a stage value with a comment is still the same secret" 1 "SIGNER_TOKEN is the same in both files" \
  's/^SIGNER_TOKEN=.*/SIGNER_TOKEN=stage-signer/' \
  's/^SIGNER_TOKEN=.*/SIGNER_TOKEN=stage-signer # the old one/'
check "a stage JWT secret with a trailing space still matches" 0 "JWT_SECRET matches MAINNET_JWT_SECRET" '' 's/^MAINNET_JWT_SECRET=.*/MAINNET_JWT_SECRET=jwt-mainnet-x /'
# Cases 40 to 43 close the last reading gaps. A "name" with lower-case letters is a pasted secret that
# has an "=" in it: the line is refused as not NAME=value, and the text before the "=" is not printed
# (the leak case above holds the needle). On the stage side a quoted value ends at its closing quote,
# so a comment after it goes too; the mnemonic is trimmed after its spaces are collapsed; and a trailing
# double quote is part of a mainnet value, as compose keeps it. The stage sed of case 42 puts a space
# inside both quotes, on purpose.
check "a mixed-case stray line is refused and not printed" 1 "is not blank, a # comment, or NAME=value" '$a Abc123def= '
check "a quoted stage value followed by a comment is still the same secret" 1 "SIGNER_TOKEN is the same in both files" \
  's/^SIGNER_TOKEN=.*/SIGNER_TOKEN=stage-signer/' \
  's/^SIGNER_TOKEN=.*/SIGNER_TOKEN="stage-signer" # old/'
check "a quoted stage mnemonic with spaces inside the quotes is still the same secret" 1 "DEPOSIT_MNEMONIC is the same in both files" \
  's/^DEPOSIT_MNEMONIC=.*/DEPOSIT_MNEMONIC=stage mnemonic words/' \
  's/^DEPOSIT_MNEMONIC=.*/DEPOSIT_MNEMONIC=" stage mnemonic words "/'
check "a trailing double quote is part of the value" 0 "no secret is shared with the stage file" \
  's/^SIGNER_TOKEN=.*/SIGNER_TOKEN=abc"/' \
  's/^SIGNER_TOKEN=.*/SIGNER_TOKEN=abc/'

echo ""
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
