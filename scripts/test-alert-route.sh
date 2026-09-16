#!/usr/bin/env bash
# Prove the alert route delivers, by sending one synthetic alert through it.
#
# Readiness items D3 and D4 close on a tested route, not a configured one. An alert route nobody
# has seen deliver is in exactly the state the metrics were in before the rules existed: present,
# plausible, and unverified. Every failure in this path is silent from the outside — a bot that has
# never been messaged first, a chat id off by a digit, a token revoked, a message Telegram rejects
# for an unescaped character. None of them show up as an error anywhere you would look.
#
# This posts to Alertmanager's own API, so it exercises the real routing tree, the real receiver
# and the real credentials. It does NOT exercise Prometheus's rule evaluation — the alert is
# injected past that — which is why the report below says what remains unproven.
#
# Nothing in the stack is touched. The alert carries an endsAt a few minutes out, so it resolves
# itself and leaves no state behind.

set -euo pipefail

cd "$(dirname "$0")/.."

# curl from a container that already has it rather than pulling one: the explorer backend's own
# healthcheck is a curl, so it is guaranteed present, and it sits on the same network.
CURL_IN="${CURL_CONTAINER:-clutch-stage-clutch-explorer-backend-1}"
if ! docker inspect "$CURL_IN" >/dev/null 2>&1; then
  echo "ABORT: $CURL_IN is not running — nothing here has curl on the clutch network."
  exit 1
fi

STARTS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ENDS="$(date -u -d '+4 minutes' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v+4M +%Y-%m-%dT%H:%M:%SZ)"
STAMP="$(date -u +%H:%M:%SZ)"

echo "=== sending a synthetic alert through the real route ==="
echo "    starts $STARTS, resolves itself at $ENDS"

# severity=critical on purpose: it takes the critical branch of the routing tree, which is the one
# that matters and the one a warning-only test would leave unproven.
PAYLOAD=$(cat <<JSON
[{
  "labels": {
    "alertname": "AlertRouteTest",
    "severity": "critical",
    "job": "manual"
  },
  "annotations": {
    "summary": "Test alert sent at $STAMP — the route works.",
    "description": "Sent by scripts/test-alert-route.sh. Nothing is wrong. If you are reading this on your phone, readiness items D3 and D4 have their delivery half. It resolves itself in four minutes and you should get a RESOLVED message too."
  },
  "startsAt": "$STARTS",
  "endsAt": "$ENDS"
}]
JSON
)

HTTP=$(docker exec -i "$CURL_IN" curl -s -o /dev/null -w '%{http_code}' \
  -X POST -H 'Content-Type: application/json' --data-binary @- \
  http://alertmanager:9093/api/v2/alerts <<<"$PAYLOAD")

if [ "$HTTP" != "200" ]; then
  echo "ABORT: Alertmanager refused the alert (HTTP $HTTP). It is not reachable or not accepting."
  exit 1
fi
echo "    accepted by Alertmanager"

echo ""
echo "=== is it in Alertmanager's own list? ==="
docker exec -i "$CURL_IN" curl -s http://alertmanager:9093/api/v2/alerts 2>/dev/null \
  | tr ',' '\n' | grep -E 'alertname|"state"' | sed 's/^/    /' | head -20 || echo "    (could not read it back)"

echo ""
echo "=== what this did and did not prove ==="
echo "  PROVED, if a message arrived: Alertmanager's routing, the receiver, the credentials, and"
echo "    that Telegram accepts the message format. That is the part with silent failure modes."
echo "  NOT proved: that Prometheus delivers to Alertmanager when a RULE fires. The alert was"
echo "    injected past rule evaluation. Confirm separately with PROBE=metrics, which lists the"
echo "    alertmanagers Prometheus has discovered, or by stopping a service for four minutes."
echo ""
echo "If nothing arrived, in order of likelihood: the bot has never received a message FROM you"
echo "(Telegram then refuses to let it message you, and nothing reports an error); the chat id is"
echo "wrong; the token is wrong or revoked. Alertmanager's own log names the last two —"
echo "PROBE=metrics prints it."
