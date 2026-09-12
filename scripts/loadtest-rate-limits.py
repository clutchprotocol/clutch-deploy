#!/usr/bin/env python3
"""Measure the Hub API's generateToken rate limits against a running deployment.

Readiness item E1. The limits were argued for rather than measured: 10 requests per minute per
claimed public key and 120 per minute globally, chosen well above what the SDK does and well below
what a flood needs to hurt, with nothing in between observed. This closes that.

What it checks:

  1. The per-key limit refuses the 11th request for one key inside a minute.
  2. The global limit refuses a fresh, never-seen key once the endpoint's budget is spent --
     which is the bound that matters, because `publicKey` is a caller-supplied string and a per-key
     limit alone is bypassed by varying it.
  3. The service still answers other requests while the auth endpoint is saturated. A limiter that
     protects one endpoint by taking down the process would be worse than none.

What it deliberately does NOT claim: that refusing is cheaper than verifying. That difference is
signature recovery, tens of microseconds, and it is invisible under internet latency from outside
the host. The ordering is pinned by a unit test in clutch-hub-api instead, which is the right place
for it.

Run it against a TESTNET. It spends the endpoint's global budget for the rest of the minute, so
logins fail while it runs -- that is the behaviour under test, not a side effect to hide.

Usage:
    python scripts/loadtest-rate-limits.py [--url https://api-stage.clutchprotocol.io]
"""

import argparse
import json
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

MUTATION = (
    "mutation { generateToken("
    'publicKey: "%s", timestamp: 1, '
    'signature: {r: "0x00", s: "0x00", v: 27}'
    ") { token } }"
)

PER_KEY_LIMIT = 10
GLOBAL_LIMIT = 120
WINDOW_SECS = 60

# Cloudflare sits in front of stage and answers the default Python-urllib agent with a 403, which
# looks exactly like the service being down. Anything recognisable gets through; the point is only
# that the agent is set at all.
USER_AGENT = "Mozilla/5.0 (compatible; clutch-loadtest/1.0)"


def call(url: str, public_key: str, timeout: float = 20.0) -> str:
    """Return a short label for what the endpoint said."""
    body = json.dumps({"query": MUTATION % public_key}).encode()
    req = urllib.request.Request(
        url + "/graphql",
        data=body,
        headers={"content-type": "application/json", "user-agent": USER_AGENT},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            payload = json.loads(r.read())
    except urllib.error.URLError as e:
        return f"transport-error:{e}"
    errors = payload.get("errors") or []
    if not errors:
        return "accepted"
    message = errors[0].get("message", "")
    if "Too many token requests for this public key" in message:
        return "refused-per-key"
    if "Too many token requests against this endpoint" in message:
        return "refused-global"
    if "Proof of key ownership failed" in message:
        return "reached-verification"
    return "other:" + message[:60]


def key(n: int) -> str:
    return "0x" + f"{n:040x}"


def health(url: str) -> bool:
    req = urllib.request.Request(url + "/health", headers={"user-agent": USER_AGENT})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status == 200
    except Exception:
        return False


def phase_per_key(url: str) -> None:
    print(f"=== per-key limit: {PER_KEY_LIMIT}/min, sending {PER_KEY_LIMIT + 4} ===")
    k = key(0xA11CE)
    counts: dict[str, int] = {}
    first_refusal = None
    for i in range(1, PER_KEY_LIMIT + 5):
        result = call(url, k)
        counts[result] = counts.get(result, 0) + 1
        if result.startswith("refused") and first_refusal is None:
            first_refusal = i
    print(f"    {counts}")
    if first_refusal == PER_KEY_LIMIT + 1:
        print(f"    OK   first refusal on request {first_refusal}, exactly at the limit")
    else:
        print(f"    NOTE first refusal on request {first_refusal}, expected {PER_KEY_LIMIT + 1}")


def phase_global(url: str) -> None:
    print(f"=== global limit: {GLOBAL_LIMIT}/min, varying the key every request ===")
    print("    (a per-key limit alone is bypassed by varying the key -- this is the real bound)")
    sent = GLOBAL_LIMIT + 30
    started = time.monotonic()
    with ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(lambda n: call(url, key(n)), range(sent)))
    elapsed = time.monotonic() - started

    counts: dict[str, int] = {}
    for r in results:
        counts[r] = counts.get(r, 0) + 1
    print(f"    sent {sent} in {elapsed:.1f}s using 8 workers")
    print(f"    {counts}")

    allowed = counts.get("reached-verification", 0)
    globally_refused = counts.get("refused-global", 0)
    if globally_refused > 0:
        print(f"    OK   {globally_refused} refused globally: a fresh key buys no fresh allowance")
    else:
        print("    NOTE nothing was refused globally -- either the window rolled or the cap is higher")
    print(f"    {allowed} reached signature verification before the budget was spent")


def phase_availability(url: str) -> None:
    print("=== the rest of the service while the auth endpoint is saturated ===")
    ok = health(url)
    print(f"    /health -> {'200 OK' if ok else 'UNREACHABLE'}")
    if ok:
        print("    OK   a saturated auth endpoint does not take the process down")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="https://api-stage.clutchprotocol.io")
    args = ap.parse_args()
    url = args.url.rstrip("/")

    print(f"target: {url}")
    if not health(url):
        raise SystemExit(f"{url}/health is not answering; refusing to load test a dead endpoint")

    phase_per_key(url)
    phase_global(url)
    phase_availability(url)

    print()
    print(f"=== waiting {WINDOW_SECS}s for the window to clear so logins work again ===")
    time.sleep(WINDOW_SECS)
    recovered = call(url, key(0xFA11))
    print(f"    after the window: {recovered}")
    if recovered == "reached-verification":
        print("    OK   the endpoint accepts requests again once the window rolls")


if __name__ == "__main__":
    main()
