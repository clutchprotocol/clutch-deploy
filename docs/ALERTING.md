# Alerting

Readiness item **D3**. What the money path measures, what evaluates it, and what is still missing
between "a condition is true" and "a human knows".

## What exists

Both treasury services expose Prometheus metrics on their own ports, scraped every 30s
(`config/monitoring/prometheus/prometheus.yml`). `treasury-service` also raises its own alerts: a
reconciliation mismatch calls `ledger::alert`, which logs at error level and inserts a row into the
`alerts` table, and `metrics.rs` gauges that table by severity.

`config/monitoring/prometheus/rules/treasury.yml` turns those into alerting rules. Ten of them, in
three groups:

| Alert | Fires when | Severity |
|---|---|---|
| `TreasuryReconciliationMismatch` | reserve does not cover liability for 1m | critical |
| `TreasuryReconciliationStale` | no successful run in 2h | critical |
| `TreasuryP1Alert` | the service raised a p1 in the last 10m | critical |
| `OrchestratorPollingStalled` | deposit addresses unpolled for over an hour | critical |
| `OrchestratorP1Alert` | the orchestrator raised a p1 | critical |
| `TreasuryServiceDown` | either service stops answering scrapes for 3m | critical |
| `TreasuryMintingHalted` | the breaker has been latched 5m | warning |
| `TreasurySweepingStalled` | more than 5 unswept addresses for 2h | warning |
| `TreasuryChainOutboxStuck` | a failed outbox row persists 15m | warning |
| `OrchestratorAddressesNeverPolled` | an address handed out has never been checked | warning |

Prometheus loads them by globbing `/etc/prometheus/rules/*.yml`, and `docker-compose.yml` mounts
the directory there. **The mount matters more than it looks**: a glob matching nothing is not an
error, so without it Prometheus starts cleanly, reports no rules, and every alert above silently
does not exist. That is the same failure shape as the nginx config this repo already learned from.

Reload rules without a restart: `curl -X POST http://localhost:9090/-/reload` (the container runs
with `--web.enable-lifecycle`).

## What is missing

**A destination.** These rules fire into Prometheus's own alert list and Grafana's UI, and stop
there. Nothing pages anybody. Two ways to finish it, and the choice is about what you already
carry a pager for:

1. **Grafana contact points.** Grafana is already running and already has Prometheus as a
   datasource. Add a contact point (email, Slack, webhook, Telegram) and a notification policy in
   the UI, then point the alert rules at it. Least new infrastructure; the configuration lives in
   Grafana's database rather than in this repo, which is the trade.
2. **Alertmanager.** A fourth monitoring container, an `alerting.alertmanagers` block in
   `prometheus.yml`, and a routing config in this repo. More moving parts, but the routing is
   reviewable in git and survives a Grafana volume being lost.

Either way, **test it by forcing a failure**, which is what closes D3. An alert route nobody has
seen deliver is in exactly the same state the metrics were in before these rules existed. The
cheapest forcing function: stop `treasury-service` for four minutes and confirm
`TreasuryServiceDown` reaches you.

## Deliberately not alerted on

- **Absolute reserve or liability values.** `clutch_treasury_clt_liability` and
  `clutch_treasury_custody_usdt` are worth a dashboard, not a threshold: the right number changes
  with adoption, and a static bound would either be noise or nothing.
- **Payout float balance.** A redemption landing on a dry float retries, which is the design. It
  becomes worth alerting on when redemption volume makes "retries for a while" a user-visible
  outage rather than a delay.
- **Node block height.** Node metrics are scraped but `clutch-node`'s own gauges are not all
  updated yet, so a height-based alert would fire on a stale gauge rather than on a stalled chain.
  Read heights with `inspect-stage.yml`'s `chain` probe until that is fixed.
