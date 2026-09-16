# Alerting

Readiness items **D3** (the money path) and **D4** (the chain under it). What is measured, what
evaluates it, and what is still missing between "a condition is true" and "a human knows".

## What exists

Both treasury services expose Prometheus metrics on their own ports, scraped every 30s
(`config/monitoring/prometheus/prometheus.yml`). `treasury-service` also raises its own alerts: a
reconciliation mismatch calls `ledger::alert`, which logs at error level and inserts a row into the
`alerts` table, and `metrics.rs` gauges that table by severity.

`config/monitoring/prometheus/rules/treasury.yml` turns those into alerting rules. Eleven of them,
in three groups:

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
| `TreasuryWatcherCursorStranded` | the deposit watcher's cursor sits above the chain head | critical |
| `OrchestratorAddressesNeverPolled` | an address handed out has never been checked | warning |

`rules/chain.yml` covers the chain those eleven read from — readiness item **D4**, added after the
stage halt of 2026-09-14, which ran for most of a day and was reported by a human as "the explorer
has no data". Four rules:

| Alert | Fires when | Severity |
|---|---|---|
| `ChainHeightNotAdvancing` | no node has produced a block in 5m | critical |
| `ChainNodeDown` | a node stops answering scrapes for 3m | critical |
| `ChainNodeBehind` | validators disagree on height by more than 50 blocks for 10m | warning |
| `ChainLatestBlockHashMissing` | no node publishes `latest_block{block_hash}` for 10m | warning |

Height is a usable liveness signal only because Aura authors an **empty** block every slot when
there is nothing to include, so a quiet chain still climbs. A consensus that produced on demand
would need a different signal entirely.

`ChainNodeBehind` earns its place separately from the halt: node1 and node2 once sat ~115,000
blocks behind while answering `get_chain_info` cheerfully, and every service reading them believed
a chain frozen near genesis. A node that is behind is harder to notice than one that is down,
because down is visible and behind answers.

Prometheus loads them by globbing `/etc/prometheus/rules/*.yml`, and `docker-compose.yml` mounts
the directory there. **The mount matters more than it looks**: a glob matching nothing is not an
error, so without it Prometheus starts cleanly, reports no rules, and every alert above silently
does not exist. That is the same failure shape as the nginx config this repo already learned from.

Reload rules without a restart: `curl -X POST http://localhost:9090/-/reload` (the container runs
with `--web.enable-lifecycle`).

**Give it three minutes after a deploy before believing the probe.** Checked ~90 seconds after a
deploy on 2026-09-14, the `metrics` probe reported `state=created`, no logs and no rules — the
exact signature recorded in readiness D3 as "created and never started, so stage had no monitoring
at all". Re-run 90 seconds later it was running with all fifteen rules healthy: this host takes
around two minutes to replay the TSDB write-ahead log, and Docker reports `created` for the whole
of it. So `created` immediately after a deploy is not evidence of anything. Check again before
investigating, and read the timestamps in the container's own logs rather than the state word.

## Delivery

**Alertmanager is wired in.** Prometheus posts firing rules to `alertmanager:9093`
(`alerting.alertmanagers` in `prometheus.yml`), and `config/monitoring/alertmanager/alertmanager.yml`
routes them. Grafana contact points were the alternative; Alertmanager won because the routing is
reviewable in git and survives losing the Grafana volume.

What the routing does, and why:

- **One receiver.** A routing tree with branches nobody has tested is a way to send a critical
  alert somewhere nobody reads. Split it when a second destination has been confirmed to receive.
- **Grouped by alertname and severity**, not per-instance, so three nodes going down arrive as one
  notification naming three instances.
- **Criticals repeat hourly, everything else every four hours.** Long enough that a week-long
  condition does not train you to filter the sender, short enough that a critical does not fall out
  of mind after one message.
- **Resolved notifications are sent.** Without them every alert has to be chased by hand to find
  out whether it is still true.
- **Two inhibit rules.** A service that is not answering scrapes drags its own derived alerts with
  it — staleness, outbox depth, reconciliation age — so the notification should say "the service is
  down", not bury that among its consequences. Same for a halted chain and every chain-derived
  alert.

**The destination is Telegram, and neither value is in the repo.** `alertmanager.yml.tpl` is the
committed config; `deploy-stage.sh` renders `alertmanager.yml` from it with the chat id substituted
from `.env`, and writes the bot token to its own file for `bot_token_file`. Both outputs are
gitignored.

A template rather than one secret file beside a committed config, because Telegram needs two values
and only the token can be read from a file — `chat_id` has to sit in the config itself. Neither
belongs in a public repository: the token lets anyone post as the bot, and the chat id identifies
the operator's own chat.

Getting the two values: message `@BotFather`, `/newbot`, keep the token. Then send your new bot any
message and read `chat.id` from `https://api.telegram.org/bot<TOKEN>/getUpdates` — negative for a
group. **The bot cannot message you until you have written to it first**, which is Telegram's
design and the most common reason a correct-looking setup delivers nothing.

**`parse_mode` is empty on purpose.** Under HTML or Markdown, Telegram *rejects* a message
containing an unescaped `<`, `>` or `_` — and these descriptions contain all three ("more than 5
unswept addresses", `latest_block{block_hash}`, `bound <= cursor`). A rejected message is an alert
that does not arrive, which is the single failure this file exists to prevent. Bold text is not
worth it.

A raw Slack or Discord incoming webhook does **not** work with `webhook_configs`, which was the
first shape tried here: Alertmanager posts its own `{"receiver":…,"alerts":[…]}` document and Slack
answers `invalid_payload` because it wants `{"text":…}`. Those platforms need Alertmanager's native
`slack_configs`, not a generic URL.

Unset, the deploy renders placeholders, Alertmanager starts normally, and delivery fails visibly in
its own log. That is deliberate — a monitoring container that crash-loops
because nobody has picked a destination would let the alerting stack look like an outage. It hangs
off nothing else in the compose file for the same reason, and its port is `!reset` on stage because
Alertmanager's UI takes no authentication and can create silences.

## Delivery is proven, 2026-09-16

A synthetic alert sent with `test-alert-route.yml` arrived on Telegram, FIRING and then RESOLVED.
That covers every silent failure mode in the receiver half: bot reachability, chat id, token,
message format, file permissions.

**It took three attempts, and each failure was invisible from outside.**

1. A placeholder `chat_id: 0` crash-looped the container. Visible only in container state.
2. A generic `webhook_configs` could never have worked with Slack or Discord — Alertmanager posts
   its own JSON document and those want `{"text":…}`.
3. `chmod 600` owned by root, against an image that runs as `nobody` (65534): `permission denied`
   on every notification. Visible only in Alertmanager's own log — which the `metrics` probe had
   been printing for exactly one commit when it was needed.

Alert accepted, alert active, nothing delivered, no error anywhere anyone looks. That is the whole
argument for a workflow that sends something through the real route rather than trusting that the
configuration is right.

## What is still missing

**A real firing rule.** The test alert is posted straight to Alertmanager's API, *past* Prometheus's
rule evaluation, so it says nothing about whether Prometheus delivers when a rule actually fires.
`PROBE=metrics` now lists the alertmanagers Prometheus has discovered, which proves the wiring
exists; it does not prove a POST happens.

The forcing function is two commands on the host, and needs no workflow:

```bash
docker stop clutch-stage-treasury-service-1   # wait 4 minutes
docker start clutch-stage-treasury-service-1
```

`TreasuryServiceDown` has `for: 3m`, so four minutes clears it with margin. A `FIRING` message
followed by a `RESOLVED` one closes the delivery half of D3 and D4 completely.

Deliberately not a workflow: a tool that stops production services would be dangerous shaped, and
this is a one-time verification an operator with SSH can do in two lines.

## One threshold that encodes a capacity limit

`OrchestratorPollingStalled` fires when the oldest deposit-address poll age passes one hour. That
is not an arbitrary number: the cold rotation's worst-case latency is
`ceil(addresses / 50) * 30` seconds, so one hour is what roughly **6,000 handed-out addresses**
produce on a completely healthy system.

So this alert doubles as the capacity tripwire for readiness item E2. Past that many addresses it
becomes a false positive, and the fix is not to raise the threshold on its own — it is to raise
`MAX_ADDRESSES_PER_PASS` in `payment-orchestrator`'s poller, or shorten `poll_interval_secs`, and
move this threshold with it. The two numbers describe the same thing and have to agree.

## Deliberately not alerted on

- **Absolute reserve or liability values.** `clutch_treasury_clt_liability` and
  `clutch_treasury_custody_usdt` are worth a dashboard, not a threshold: the right number changes
  with adoption, and a static bound would either be noise or nothing.
- **Payout float balance.** A redemption landing on a dry float retries, which is the design. It
  becomes worth alerting on when redemption volume makes "retries for a while" a user-visible
  outage rather than a delay.
~~**Node block height.**~~ This said a height alert would fire on a stale gauge rather than a
  stalled chain, because `latest_block_index` was published only by `add_block_to_chain` and so
  read 0 from boot until the next block arrived. clutch-node publishes it from the stored block at
  startup now, and `ChainHeightNotAdvancing` in `rules/chain.yml` is exactly the alert this
  paragraph declined to write. The chain then halted for most of a day with nothing watching it.
