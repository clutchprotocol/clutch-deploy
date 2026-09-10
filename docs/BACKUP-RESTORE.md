# Backing up and restoring the treasury databases

Readiness item **D1**. Two Postgres databases hold the off-chain half of the peg:

| Database | What is lost with it |
|----------|----------------------|
| `treasury` | Mint intents and their four-eyes approvals, the reserve and reconciliation history, the payout/redemption ledger |
| `orchestrator` | Which permanent Tron deposit address belongs to which user, and every credited deposit keyed by its Tron transaction id |

The chain records that a `Mint` and a `Burn` happened. It does not record which USDT payment a
mint answered, whose address received it, or which redemption intent a burn was tagged for. Lose
these two databases and the CLT is still on chain, the USDT is still at custody, and nothing left
can say who is owed what.

The Docker volumes are named and survive container recreation, which is exactly what made this
easy to miss: the data looks safe right up until the host is gone.

## What runs

`.github/workflows/backup-treasury-db.yml` — daily at 03:17 UTC, and on manual dispatch. It SSHes
to the stage host and runs `scripts/backup-treasury-db.sh`, which:

1. `pg_dump -Fc` each database out of its container.
2. Pipes straight into `openssl enc -aes-256-cbc -pbkdf2 -iter 600000`. The plaintext dump never
   touches disk.
3. Writes to `backups/` on the host, mode 600, in a directory mode 700 (gitignored).
4. Copies both off host with `rclone`, if `BACKUP_REMOTE` is set.
5. Prunes to the most recent `BACKUP_RETAIN` (default 14) of each.

`pipefail` is set, so a failing `pg_dump` fails the run rather than leaving a valid encryption of a
truncated dump — which would look exactly like a good backup. Anything under 1 KB is treated as a
failure and deleted, for the same reason.

## Host configuration

In the host's `.env`:

| Variable | Required | Notes |
|----------|----------|-------|
| `BACKUP_PASSPHRASE` | **yes** | `openssl rand -base64 48`. The script refuses to run without it, because a plaintext ledger dump is worse than none. |
| `BACKUP_REMOTE` | for D1 | An rclone destination, e.g. `b2:clutch-treasury-backups`. Unset means same-disk dumps, which do **not** satisfy D1 and which the script warns about on every run. |
| `BACKUP_RETAIN` | no | Default 14. |

**Store `BACKUP_PASSPHRASE` somewhere that is not this host.** A passphrase sitting next to the
dump it protects is decoration. If the host is gone and the passphrase went with it, so did the
backups.

Setting up `rclone` on the host is a one-time `rclone config` against whatever object store you
prefer. rclone rather than a provider CLI so the destination stays a decision rather than a
dependency.

## The rehearsal, which is what actually closes D1

A dump nobody has restored is a hypothesis. Run this, then record the date in
`clutch-treasury/docs/mainnet-readiness.md` under D1.

```bash
# On the host, in the deploy path.
bash scripts/backup-treasury-db.sh
bash scripts/restore-treasury-db.sh backups/treasury-<stamp>.dump.enc
```

`restore-treasury-db.sh` deliberately **cannot** overwrite a live database. It creates
`treasury_restore_<stamp>` and loads into that, so the rehearsal runs against a live stage without
a window where the real ledger is half-loaded. It then prints row counts, because a restore that
loads cleanly and is empty is the failure this rehearsal exists to catch.

Three steps close the item, and only the third is real verification:

1. Compare the printed row counts against the live database.
2. Point a `treasury-service` instance at the restored database and run reconciliation. **Green
   against the restored ledger is the verification.** A loadable dump is not.
3. Drop the restore copy.

## Promoting a restore to live

Not automated, on purpose. A service holding a connection to a database being replaced is how a
restore becomes an outage *and* a corrupt ledger. Stop `treasury-service`,
`payment-orchestrator` and their workers first, then rename, then start them and reconcile before
allowing a mint.

Minting halts on its own if reconciliation finds reserve below liability, which is the safety net
under a bad restore rather than a substitute for checking.

## What this does not cover

- **The chain itself.** Node data is in per-node Docker volumes; three validators each hold a
  copy, which is a different durability story from a single-writer ledger. Not addressed here.
- **`.env`.** It holds `DEPOSIT_MNEMONIC` today, so backing it up means copying the mnemonic
  around, which is the problem readiness item D2 is about rather than a thing to solve with more
  copies. It stops being a question once the KMS work in A1 and A2 lands.
