#!/usr/bin/env bash
#
# Write PILOT_ALLOWED_ADDRESSES into .env.mainnet: the accounts that may use mainnet while it is a
# pilot (readiness A2 and B4). The workflow "Set the mainnet pilot allowlist" runs it, and gives it the
# list in the environment from the repository secret PILOT_ALLOWED_ADDRESSES:
#
#   PILOT_ALLOWED_ADDRESSES=0xabc...,0xdef... bash scripts/set-pilot-allowlist.sh
#   PILOT_ALLOWED_ADDRESSES='*'               bash scripts/set-pilot-allowlist.sh   # everyone
#
# The list comes from a secret, and not from a workflow input, because the inputs of a run are shown
# in plain text and the run log is public: an address in either says which accounts are in the pilot.
# This prints a count and never an address.
#
# What it writes is exactly one line, replaced if the file has it (every copy, as set-gasfree-settings.sh
# does) and appended if not. `*` is everyone: the orchestrator then serves every account, so the
# workflow asks for a typed word of its own for that. Any other value must be a comma-separated list of
# 0x addresses, 40 hex characters each, with no spaces; it is written in lower case. An empty or
# malformed list is refused and nothing is changed: the orchestrator reads a blank list as nobody, which
# is safe, but it would lock the maintainer out, and the start refuses a malformed one anyway.
#
# It restarts nothing. "Mainnet — start the treasury" recreates the orchestrator with the new list, and
# ends by checking that the orchestrator logged the allowlist as on.

set -euo pipefail
cd "$(dirname "$0")/.."

ENV_FILE=.env.mainnet
LIST="${PILOT_ALLOWED_ADDRESSES-}"

if [ ! -f "$ENV_FILE" ]; then
  echo "ABORT: no $ENV_FILE here ($(pwd))."
  exit 1
fi

if [ -z "$LIST" ]; then
  echo "ABORT: PILOT_ALLOWED_ADDRESSES is empty. Set the repository secret, then run this again:"
  echo "  gh secret set PILOT_ALLOWED_ADDRESSES --repo clutchprotocol/clutch-deploy"
  echo "Nothing was changed."
  exit 1
fi

LIST=$(printf '%s' "$LIST" | tr '[:upper:]' '[:lower:]')
if [ "$LIST" = "*" ]; then
  count=everyone
elif printf '%s' "$LIST" | grep -Eq '^0x[0-9a-f]{40}(,0x[0-9a-f]{40})*$'; then
  count="$(( $(printf '%s' "$LIST" | tr -cd ',' | wc -c) + 1 )) address(es)"
else
  echo "ABORT: PILOT_ALLOWED_ADDRESSES is neither * nor a comma-separated list of 0x addresses"
  echo "  (40 hex characters each, no spaces, no trailing comma). Nothing was changed."
  exit 1
fi

# One backup, overwritten each run, as set-gasfree-settings.sh keeps it: every copy holds DEPOSIT_MNEMONIC.
cp -a "$ENV_FILE" "$ENV_FILE.bak"
chmod 600 "$ENV_FILE.bak"
rm -f "$ENV_FILE".bak.*

if grep -qE '^PILOT_ALLOWED_ADDRESSES=.' "$ENV_FILE"; then before=set
elif grep -qE '^PILOT_ALLOWED_ADDRESSES=' "$ENV_FILE"; then before=blank
else before=absent; fi

# A file that does not end in a newline would glue the line onto its last one.
if [ -s "$ENV_FILE" ] && [ -n "$(tail -c1 "$ENV_FILE")" ]; then
  echo >> "$ENV_FILE"
fi

if grep -qE '^PILOT_ALLOWED_ADDRESSES=' "$ENV_FILE"; then
  sed -i "s#^PILOT_ALLOWED_ADDRESSES=.*#PILOT_ALLOWED_ADDRESSES=$LIST#" "$ENV_FILE"
else
  printf 'PILOT_ALLOWED_ADDRESSES=%s\n' "$LIST" >> "$ENV_FILE"
fi
chmod 600 "$ENV_FILE"

echo "PILOT_ALLOWED_ADDRESSES in $ENV_FILE: was $before, now $count (the addresses are not printed: this log is public)"
if [ "$count" = everyone ]; then
  echo "WARNING: * means EVERY account may use mainnet through /payment/."
fi
echo "Nothing was restarted. Run \"Mainnet — start the treasury\" so that the orchestrator reads it; the start"
echo "checks that the orchestrator logged the allowlist as on. The file as it was is in $ENV_FILE.bak."
