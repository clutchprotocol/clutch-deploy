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
| `TreasuryServiceDown` | Not answering scrapes for three minutes. | `containers` probe. Deposits already credited are safe; new ones are not being detected while it is down. |
| `TreasuryMintingHalted` | The breaker is latched, by a mismatch or by a person. | If not accompanied by a mismatch alert, someone halted it deliberately. Find out who before resuming. |
| `TreasurySweepingStalled` | More than five unswept addresses for two hours. | Almost always a dry TRX fee account. The `treasury` probe prints its balance. Deposits are still credited and the reserve total is still correct; only consolidation has stopped. Not urgent. |
| `TreasuryChainOutboxStuck` | A transaction the treasury meant to submit is not landing. | Check node reachability, then the outbox rows. An over-cap intent routes to `needs_manual` rather than retrying, which is correct. |
| `OrchestratorPollingStalled` | Deposit addresses unpolled for over an hour. Someone paying now might not be detected. | Check TronGrid reachability. **Also check the address count** — past roughly 6,000 addresses this alert is a false positive against a healthy rotation, and the fix is capacity, not the threshold. See readiness item E2. |
| `OrchestratorAddressesNeverPolled` | An address handed to a user has never been checked. | A deposit to it cannot be detected at all. Treat as urgent even though it is labelled warning. |

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
