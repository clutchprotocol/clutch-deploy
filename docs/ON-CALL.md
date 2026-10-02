# On call

Readiness item **G3**. The treasury has a manual halt, a daily cap and four-eyes approval. That
machinery is worth very little if one person knows it exists, so this is the document that makes a
second operator possible: what can break, what it means, and what to do — including what *not* to
do, because two of the wrong moves here are worse than doing nothing.

You do not need to understand the whole stack to be useful on call. You need this page, the
`inspect-stage.yml` probes, and the discipline to stop rather than guess.

## The two rules that matter more than anything else here

**1. Never clear the minting breaker to make an alert go away.** The breaker latches when
reconciliation finds reserve below liability. That is the one condition meaning the chain believes
more CLT exists than the treasury can back. It is *correct*, and `resume-minting.sh` refuses to
resume while the mismatch stands, because a breaker cleared in a loop stops meaning anything. Find
the missing reserve first.

**2. Never retry a payout whose outcome is unknown.** A TRC-20 transfer has no memo to deduplicate
against, so retrying one that *may* have broadcast risks paying twice for a burn that happened once.
The code already refuses to: only a reply proving nothing was broadcast returns a redemption to the
queue. If you find one stuck as `claimed`, that is the design working. Resolve it by reading the
chain, never by re-running anything.

Both of these trade a stuck operation for an unrecoverable one. A stuck redemption is fixable by a
human; a double payment is not.

## First moves, whatever the alert

```
Actions → Inspect stage (read-only) → probe: treasury
```

That one probe answers most questions: service settings, reserve numbers, what is parked for a
human, and the TRX fee account's balance. Then `metrics` for what Prometheus holds and whether its
rules are loaded, `chain` for node heights, `containers` for what is actually running.

Read heights from the `chain` probe and nothing else. Grepping node logs returns the block numbers a
node is *serving* to a syncing peer, which once looked like a node falling from 117,573 to 17,463
while it was feeding another. The JSON-RPC ports speak WebSocket only, so curling them returns
nothing at all.

## Alert by alert

| Alert | What it means | What to do |
|---|---|---|
| `TreasuryReconciliationMismatch` | Reserve does not cover liability. Minting is already halted. | **Do not clear the breaker.** Run the `treasury` probe and compare custody, unswept addresses and the payout float against CLT liability. A sweep that has not run makes reserve *look* low while the money is still there. |
| `TreasuryReconciliationStale` | No successful run in two hours. The worker retries failures on a short cadence, so this means repeated failure, not waiting. | Check the node is reachable — reconciliation needs `get_chain_info`. Minting stays blocked meanwhile, which is intended. |
| `TreasuryP1Alert` / `OrchestratorP1Alert` | The service decided a human is needed. The ambiguous-payout path lands here. | Look at the `alerts` table rows via the `treasury` probe. Rule 2 above applies. |
| `TreasuryServiceDown` | A stage service, or a mainnet service that has been up in the last 7 days, has not answered scrapes for three minutes. | `containers` probe. For a mainnet service, use probe `mainnet-treasury`. Deposits already credited are safe; new ones are not being detected while it is down. |
| `TreasuryMintingHalted` | The breaker is latched, by a mismatch, by a person, or by the GasFree tripwire (`halt_reason` starts `GasFree tripwire:`). Payouts wait while it is latched. | If not accompanied by a mismatch alert, someone halted it deliberately, or the GasFree tripwire did (see "The GasFree rail" below). Find out who before resuming. |
| `TreasurySweepingStalled` | More than five unswept addresses for two hours. | Almost always a dry TRX fee account. The `treasury` probe prints its balance. Deposits are still credited and the reserve total is still correct; only consolidation has stopped. Not urgent. |
| `TreasuryGasFreeSweepStalled` | A deposit at a GasFree account has waited over an hour to be swept. Sweeps run every minute. | Read the P1 alerts first: a relay refusal, the tripwire, a maxFee above the hold, or the services' settings disagreeing — see "The GasFree rail" below. The deposit is still counted; nothing is lost while it waits. |
| `TreasuryRedemptionUnpaid` | A redemption's CLT is burned and its USDT has not been paid for over two hours. The age counts from the redemption request, not from the burn, so a user who waited long before burning can make it fire early. | Read the P1 alerts and the `treasury` probe. On the GasFree rail a dry float fills from deposits as they are swept. On the TRX rail only the custody wallet holder can refill it, by hand ("Things only two people can do"). **Never** return a GasFree payout to `payout_pending` before the time its page names: the permit may still run. |
| `TreasuryChainOutboxStuck` | A transaction the treasury meant to submit is not landing. | Check node reachability, then the outbox rows. An over-cap intent routes to `needs_manual` rather than retrying, which is correct. |
| `OrchestratorPollingStalled` | Deposit addresses unpolled for over an hour. Someone paying now might not be detected. | Check TronGrid reachability. **Also check the address count** — past roughly 6,000 addresses this alert is a false positive against a healthy rotation, and the fix is capacity, not the threshold. See readiness item E2. |
| `OrchestratorAddressesNeverPolled` | An address handed to a user has never been checked. | A deposit to it cannot be detected at all. Treat as urgent even though it is labelled warning. |

## The GasFree rail

Off unless `.env` sets `GASFREE_NETWORK` (clutch-treasury's `docs/superpowers/specs/2026-09-24-gasfree-transfer-rail-design.md`). Its pages, and what to do:

| The page starts with | What it means | What to do |
|---|---|---|
| `the GasFree beacon … now runs 0x…, not the reviewed 0x…` (or `controller`) | GasFree changed the code that holds users' money. GasFree sweeps, **all minting and all redemption payouts** have stopped (payouts honour the same breaker), and new users get no GasFree address. | Run `PROBE=gasfree`: it prints the live and the expected implementations. Do not resume minting until someone has read the new code. Then set `GASFREE_EXPECTED_IMPLEMENTATION` (or `GASFREE_EXPECTED_CONTROLLER_IMPLEMENTATION`) in `.env` to the live value, deploy, and run `resume-minting.yml`, which also resumes payouts. |
| `the relay refused the sweep of GasFree account …` | The relay would not take the permit, most often because the live fee is above the maximum. The deposit stays at the account, still counted. | `PROBE=gasfree` compares the live fees with the maxima. Raising a maximum covers only deposits minted after the change; nothing is signed for deposits that held less. Change a maximum only in `.env` (all three services read it), and deploy — the deploy runs `check-cap-invariants.sh` first. |
| `a sweep of GasFree account … may now cost up to …, but its deposits held back …` | A maximum was raised after these deposits were minted, so nothing is signed for them. | They wait, still counted. Lower the maximum again when the live fee allows. |
| `the signer set maxFee … above the … held back` | The signer and the treasury read different maxima. The permit is already signed. | This should be impossible with one `.env`: compare the running containers' environments. |
| `the signer answers sweeps with GasFree statuses, but this treasury has GasFree off` / `the signer pays redemptions by GasFree permit, but this treasury has GasFree off` | The services' settings disagree. | Give all three the same settings; `check-cap-invariants.sh` names what is missing. Never return those redemptions to `payout_pending`: the float may already have paid them. |
| `redemption …: payout outcome UNKNOWN … do not return this intent to payout_pending before …` | A GasFree permit may still run until that time. | Wait until the time has passed, then follow the page. |
| `redemptions are not available yet: the GasFree float … has never made a transfer` | The float's one-time activation has not run. | Run `activate-float.yml` once. It runs a fresh reconciliation, and refuses unless the surplus, less what redemptions not yet paid are owed, covers the most the activation may cost. |

Rules that do not change:

- **Never remove the `GASFREE_*` settings while any user has a GasFree address, or while the GasFree float holds USDT**, even after setting `TRANSFER_RAIL=trx`: without them the treasury refuses deposits there, the orchestrator will not show the address, and the reserve stops counting the GasFree float, which trips the breaker.
- **While `GASFREE_NETWORK` is unset, keep `GASFREE_API_KEY` and `GASFREE_API_SECRET` commented out.** tron-signer turns GasFree on by its API key alone and then refuses to start without the network. `check-cap-invariants.sh` stops the stage deploy in that state, with the stack as it was.
- `sweep-address.yml` refuses an index that has a GasFree account. The sweeper sweeps those every minute and follows each permit to the chain.
- `fund-float.yml` moves USDT that landed by mistake at the fee account (1/0) into the plain float at 2/0. GasFree payouts do not use that float, but it stays in the reserve count, so running it is still safe.

## The mainnet treasury

A second treasury runs next to the stage one. It is for TRON mainnet.

- Compose project: `clutch-main-treasury`.
- Compose file: `docker-compose.mainnet.treasury.yml`.
- Env file: `.env.mainnet`.
- App services: `mainnet-treasury-service`, `mainnet-tron-signer` and `mainnet-payment-orchestrator`.

The app services never use the stage names. Two containers with one name, on a network that
Prometheus or nginx share, would answer to the same address. A scrape or a request could then reach
either stack.

**It is not open to users.** It publishes no port, it joins no stage network, and `/payment/` on the
mainnet site answers 503. Redemptions are off (`APP_REDEMPTIONS_ENABLED=false`).

**Never run `down -v` against `clutch-main-treasury`.** Its two databases are in its volumes.

For an alert that says `chain: mainnet`, use probe `mainnet-treasury` where this page says probe
`treasury`.

Most of the tools below are the stage tools. They have a **chain** choice (the GasFree writer has a
**network** choice). Pick `mainnet` and type the longer word that the row names. Most workflow names
end with `(stage)`: that names the host, not the treasury. With chain `mainnet`, the short word (for
example `halt`) is refused.

| To do this | Run | Notes |
|---|---|---|
| See everything | `Inspect stage (read-only)`, probe `mainnet-treasury` | It shows the containers, their ports and networks, and whether each service name has one address. It shows the settings, the breaker, reconciliation runs, alerts, mint intents, redemptions and the GasFree float. The run log is public, so it prints no address of a user. |
| Halt minting | `Halt minting (stage, sets the breaker)`, chain `mainnet`, type `halt mainnet` | It sets the breaker of the mainnet treasury only. Rules 1 and 2 at the top of this page apply as before. |
| Resume | `Resume minting (stage, clears the breaker)`, chain `mainnet`, type `resume mainnet` | It refuses while the latest reconciliation run is a mismatch. It also refuses when there is no run yet. |
| Change the mint caps | `Set mint caps (stage)`, chain `mainnet`, type `set mainnet` | It refuses unless `clutch-main-treasury-mainnet-treasury-service-1` is running. It checks the form of `.env.mainnet` first. It restarts only `mainnet-treasury-service`. If you changed other settings in `.env.mainnet`, run `Mainnet — start the treasury` so that the other services read them. It prints no output of `docker compose`, because the run log is public. Afterwards it runs `check-cap-invariants.sh` on `.env.mainnet`. |
| Write the GasFree settings and the decided limits | `Set GasFree settings (stage)`, network `mainnet`, type `gasfree mainnet` | It writes 17 values into `.env.mainnet`: the GasFree settings and the decided limits. Before you run it, put `GASFREE_API_KEY` and `GASFREE_API_SECRET` into `.env.mainnet` by hand, as plain `NAME=value` lines. It refuses if one is missing, blank or in quote marks. Until it has run, the start refuses a key without the network. That is on purpose. It restarts nothing. **Order:** run it, then `Mainnet — start the treasury`, so that all three services read the new values. Run `Set mint caps` only after that. **Running it again writes the decided limits again.** The lower mint caps of a pilot go back to the values of readiness item B4, so run `Set mint caps` again after it. |
| Activate the GasFree float | `Activate the GasFree payout float (stage)`, chain `mainnet`, type `activate mainnet` | It moves money. It needs two things. **1.** The GasFree float must hold at least the smallest transfer plus 4.00 USDT, the two fee maxima together. If it holds less, the signer answers `float_dry` and nothing is signed. USDT sent to the custody address does not fill the float. The float fills from the sweep of a real deposit, or from USDT sent to the float's GasFree address. **2.** The reserve must be at least 4.00 USDT more than the liabilities (CLT in circulation, and what unpaid redemptions are owed). The script checks this and refuses if it is not true. It runs a fresh reconciliation first. |
| Sweep one deposit address | `Sweep one deposit address (stage)` | **Stage only for now.** The workflow has no chain choice. It prints the address you type into the public run log before any check could refuse it. `scripts/sweep-address.sh` also refuses `CHAIN=mainnet`. Nothing needs it before the first real deposit. |
| Start it, or bring it up to date | `Mainnet — start the treasury`, type `START MAINNET TREASURY` | It checks the env files, the limits, the mainnet chain and the compose file first. It starts nothing until all checks pass. The first check, `preflight`, prints `OK` or `FAIL` for each point. A `FAIL` line names a setting or a line number, never a value. Fix what it names on the host, then run the workflow again. It never runs `down`. It pulls only the three app images. If a service is not healthy, it prints the command `docker logs --tail 50 <container>`. Run that command on the host: the script prints no service log, because the run log is public. A later run can restart both databases, if a stage deploy has pulled a newer `postgres:16-alpine` in the meantime. |

**The GasFree rail section above.** It talks about `.env`, a deploy and `resume-minting.yml`. For
the mainnet treasury, read `.env.mainnet`, `Mainnet — start the treasury` and `Resume minting` with
chain `mainnet`.

**One queue for the env files.** These four workflows share one concurrency group,
`env-file-writers`: `Set mint caps`, `Set GasFree settings`, `Provision treasury secrets` and
`Mainnet — start the treasury`. They wait for each other, so two of them never write `.env.mainnet`
at the same time. GitHub keeps only one waiting run per group. If you start a third run, the waiting
run is cancelled. Start the next run after the one before it has finished.

**The nightly backup.** `Backup treasury databases (stage)` also dumps the mainnet databases into
`backups/mainnet`, once they exist. If they exist but are stopped, the run fails. It prints
`mainnet treasury: ... exists but is not running: NOT backed up`. So if you stop the whole mainnet
treasury on purpose, the nightly backup fails every night. The run leaves no partial file. See
`BACKUP-RESTORE.md`.

**Alerts.** The mainnet treasury uses the same alert rules as stage. Its alerts are raised from the
jobs `mainnet-treasury-service` and `mainnet-payment-orchestrator`, and the Telegram text says
`chain: mainnet`. `TreasuryServiceDown` does not page for a mainnet treasury that has never run. It
pages when a mainnet service stops, if that service has been up in the last 7 days. Three things
follow from that 7-day memory:

1. A treasury that you stop on purpose sends a critical alert every hour, until you start it or
   silence the alert. Alertmanager's port is not published, so run `amtool silence add` inside the
   Alertmanager container.
2. If it stays down for more than 7 days, Telegram sends `RESOLVED: TreasuryServiceDown` while it is
   still down.
3. A stage deploy with `reset_chain=true` deletes Prometheus's data. A mainnet treasury that is down
   at that moment stops paging.

**Grafana.** Before the first start, the first panel ("State") of the dashboard "Clutch-Node" shows
two red `Down` tiles, for `mainnet-treasury-service` and `mainnet-payment-orchestrator`. That is
expected. After the first start, the "Treasury" row of that dashboard has no `chain` filter yet, so
its panels mix both treasuries. A panel that uses `sum` adds the two. The other panels show one value
or one line for each treasury. Read stage with probe `treasury`, and mainnet with probe
`mainnet-treasury`.

## Things only two people can do

The four-eyes mint is deliberately two separate dispatches so one run cannot be both roles:
`mint-intent-create.yml` then `mint-intent-approve.yml`. If you are on call alone and a mint needs
approving, it waits. That is the control working, not an obstacle to route around.

Topping up the payout float from custody is a human operation with no code path, by design — nothing
in the stack can spend from custody. It needs the custody wallet holder.

## What is safe to do alone

- Every `inspect-stage.yml` probe. All read-only.
- **Halt minting (stage)**. Reversible, and the right first move when you suspect rather than know.
  Resuming is what is gated, not halting.
- `deploy-stage.yml` without `reset_chain`. Normal redeploy. **Never tick `reset_chain`** — it wipes
  the chain, both treasury databases and Grafana, and it exists only for a consensus-parameter
  change.
- `backup-treasury-db.yml`. Idempotent.
- `fund-float.yml`, `sweep-address.yml`. Bounded by design; the sweep endpoint takes an address
  index and cannot name a destination.

## What to do when you do not know

Stop and escalate. Every irreversible operation in this system already refuses to proceed when it
cannot prove what happened, and that is the standard to hold yourself to as well. Specifically:

- A stuck redemption costs a delay. A double payment costs the money.
- A halted treasury costs new deposits being credited late. A cleared breaker over a real mismatch
  costs the peg.
- An undiagnosed alert costs you an evening. A guessed fix costs a reconciliation you can no longer
  trust.

Write down what you saw, in the workflow log that invoked whatever you ran. The alerts table has no
resolved flag and nothing prunes it, so the log is the only account of *why* something was done.

## Before your first shift

Do these once, on a quiet day, so the first time is not during an incident:

1. Run every probe and read the output. Knowing what healthy looks like is most of the job.
2. Halt minting and resume it: **Halt minting (stage)** then **Resume minting (stage)**.
   Rehearsing the control you are least likely to use is the point of rehearsing at all. Halting
   is cheap and reversible — deposits keep being credited, only new issuance stops.
3. Read `BACKUP-RESTORE.md` and `ALERTING.md`. If the alert route has not been tested by forcing a
   failure, test it — that is readiness item D3 and it is the reason you would ever hear about any
   of the above.
