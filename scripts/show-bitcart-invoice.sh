#!/usr/bin/env bash
#
# Print the fields the Bitcart adapter actually reads from an invoice, given the invoice JSON on
# stdin. Called by .github/workflows/inspect-stage.yml.
#
# A separate file because the same formatting inlined in the workflow was column-0 Python inside a
# YAML literal block, which terminates the block scalar and made the whole workflow unparseable —
# the third time today that inlining a script into YAML has bitten.
#
# Prints only adapter-relevant fields so the Actions log stays safe to share: no token, no
# customer data.
set -uo pipefail

python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print("  (unparseable response)"); raise SystemExit
if not isinstance(d, dict):
    print("  (unexpected response shape)"); raise SystemExit
print("  status          ", d.get("status"))
# repr on purpose: Bitcart sends the STRING "none" for "no exception", and a bare print makes
# that indistinguishable from a real absence. Mistaking one for the other once parked every
# deposit in manual review.
print("  exception_status", repr(d.get("exception_status")))
print("  price           ", d.get("price"), d.get("currency"))
print("  paid_currency   ", d.get("paid_currency"))
print("  tx_hashes       ", d.get("tx_hashes"))
pays = d.get("payments") or []
for p in pays:
    print("  payment: amount=", p.get("amount"),
          "address=", p.get("payment_address"),
          "confirmations=", p.get("confirmations"))
if not pays:
    print("  payments: NONE — bitcart has not seen a payment for this invoice")
'
