# Alertmanager routing. Readiness items D3 and D4.
#
# Fifteen alerting rules existed before this file and none of them reached a human. A condition
# nobody is looking at is not monitored, it is recorded — and the whole argument for D3 is that a
# reconciliation mismatch had been writing rows, logging errors and moving a gauge for weeks while
# nothing evaluated any of it. Adding rules moved that problem one step along; this file is the
# step that ends it.
#
# THIS IS A TEMPLATE. deploy-stage.sh renders it to alertmanager.yml, substituting the Telegram
# chat id from the host's `.env`; the bot token is read separately with `bot_token_file`. The
# rendered file is gitignored.
#
# Two values rather than one because Telegram needs both, and only the token can come from a file —
# `chat_id` has to be in the config itself, which is why this is a template rather than a committed
# config with one secret file beside it. Neither belongs in a public repository: the token lets
# anyone post as the bot, and the chat id identifies the operator's own chat.
#
# The routing below — which alert goes where, how often it repeats, what is grouped with what —
# stays reviewable in git, which is the whole reason for the split.
#
# Unconfigured, the deploy renders placeholders, Alertmanager starts normally and delivery fails
# visibly in its own logs. That is deliberate: a monitoring container that crash-loops because
# nobody has picked a destination yet would make the alerting stack able to look like an outage,
# and it hangs off nothing else in the compose file precisely so it cannot.

global:
  # How long a firing alert may go unrefreshed before it is treated as resolved. Longer than
  # Prometheus's evaluation interval by a wide margin, so a slow evaluation cycle cannot produce a
  # spurious "resolved" followed by a re-fire.
  resolve_timeout: 10m

route:
  # Everything lands here. One receiver on purpose: a routing tree with branches nobody has tested
  # is a way to send a critical alert somewhere nobody reads. Split it when there is a second
  # destination that someone has actually confirmed receives.
  receiver: default

  # Group by alertname and severity rather than per-instance, so three nodes going down together
  # arrive as one notification naming three instances rather than three notifications.
  group_by: ['alertname', 'severity']

  # 30s to collect the first batch — long enough that alerts firing in the same evaluation cycle
  # arrive together, short enough that a critical is not sitting in a buffer.
  group_wait: 30s

  # A new alert joining an existing group waits this long rather than sending immediately.
  group_interval: 5m

  # How often an unresolved alert is re-sent. Four hours is a compromise: short enough that a
  # critical condition does not fall out of mind after one notification, long enough that a
  # condition lasting a week does not train the recipient to filter the sender.
  repeat_interval: 4h

  routes:
    # Criticals repeat hourly instead. TreasuryReconciliationMismatch, TreasuryServiceDown,
    # ChainHeightNotAdvancing and TreasuryWatcherCursorStranded all mean money or the chain under
    # it has stopped behaving, and none of them is self-healing.
    - matchers:
        - severity = "critical"
      receiver: default
      repeat_interval: 1h

receivers:
  - name: default
    telegram_configs:
      - bot_token_file: /etc/alertmanager/telegram-token
        chat_id: __TELEGRAM_CHAT_ID__
        # Resolved notifications are sent too. Knowing a condition cleared is worth as much as
        # knowing it started — without it, every alert has to be chased by hand to find out
        # whether it is still true.
        send_resolved: true
        # Plain text, deliberately. Under HTML or Markdown parse modes Telegram REJECTS a message
        # containing an unescaped `<`, `>` or `_`, and several of these descriptions contain them
        # ("more than 5 unswept addresses", `latest_block{block_hash}`, `bound <= cursor`). A
        # rejected message is an alert that does not arrive, which is the one failure this whole
        # file exists to prevent. Bold text is not worth that.
        parse_mode: ''
        message: |-
          {{ if eq .Status "firing" }}FIRING{{ else }}RESOLVED{{ end }}: {{ .CommonLabels.alertname }}{{ if .CommonLabels.severity }} [{{ .CommonLabels.severity }}]{{ end }}
          {{ range .Alerts }}
          {{ .Annotations.summary }}{{ if .Annotations.description }}
          {{ .Annotations.description }}{{ end }}{{ if .Labels.instance }}
          instance: {{ .Labels.instance }}{{ end }}
          {{ end }}

inhibit_rules:
  # A service that is not answering scrapes will drag its own derived alerts with it: staleness,
  # outbox depth, reconciliation age. Suppress those while the down alert is firing, so the
  # notification says "the service is down" rather than burying that among its consequences.
  - source_matchers:
      - alertname = "TreasuryServiceDown"
    target_matchers:
      - severity =~ "warning|critical"
      - alertname =~ "Treasury.*|Orchestrator.*"
    # Only within the same job — one service being down says nothing about the other's alerts.
    equal: ['job']

  # A halted chain makes every chain-derived alert true at once. The halt is the one to act on.
  - source_matchers:
      - alertname = "ChainHeightNotAdvancing"
    target_matchers:
      - alertname =~ "ChainNodeBehind|ChainLatestBlockHashMissing"
