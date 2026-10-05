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

**Scope the credential to the one bucket, and expect the 403 that causes.** rclone verifies a
bucket exists before uploading into it; a token scoped to a single bucket cannot list buckets
account-wide, so rclone concludes the bucket is missing and attempts `CreateBucket`, which comes
back as `403 AccessDenied` and reads exactly like a bad key.

Fix it on the remote, once:

```bash
rclone config update <remote> no_check_bucket true
```

Not with a flag in `backup-treasury-db.sh`. `no_check_bucket` is an **S3 backend** option — there
is no generic `--no-check-bucket`, and the S3-prefixed flag would be an assumption about a backend
that is deliberately the operator's choice. The script stays backend-agnostic; the remote carries
what is true about the remote.

Do not widen the token to admin to make the 403 go away — that discards the reason for scoping it.

Grant delete only if something needs it; nothing here does. The script never runs `rclone sync`
and its retention prune is a local `rm`, so a write-only credential means whoever owns the host
can add backups but not erase the ones already off it. The remote then grows unbounded, which at
roughly 45 KB a day is about 16 MB a year.

Stage uses Cloudflare R2 (`r2:clutch-treasury-backups`, account API token, Object Read & Write
scoped to that bucket). Two notes for anyone reproducing it: the endpoint rclone wants is
`https://<account-id>.r2.cloudflarestorage.com` with **no** bucket path, though the dashboard
displays it with one; and `rclone config` must run as the same user the deploy SSHes in as, since
the config lives in that user's home.

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
- **`.env` and `.env.mainnet`.** They hold `DEPOSIT_MNEMONIC` and, on mainnet, `MINT_AUTHORITY_SECRET`,
  so a backup of them is a copy of the keys. The nightly job does not take one, on purpose. On
  mainnet the maintainer keeps both secrets somewhere that is not the host (readiness A1, A2). A lost
  mint key means no CLT can be minted on that chain again. A lost mnemonic strands every deposit
  address. Losing the stage file only costs the testnet.

## Mainnet

The nightly workflow also backs up the mainnet treasury's two databases. It does this once the
mainnet treasury has been started for the first time. The script then runs with `CHAIN=mainnet`.

- The dumps are written to `backups/mainnet` on the host. The stage dumps stay in `backups`.
- They are copied to the remote named in `.env.mainnet`.
- **`.env.mainnet` has its own `BACKUP_PASSPHRASE`, `BACKUP_REMOTE` and database passwords.**
  Nothing is shared with `.env`.
- `Mainnet — start the treasury` refuses a passphrase or a remote that is equal to the stage one.
  So one leaked secret cannot open the dumps of both stacks.
- Each run prunes only its own directory: it keeps the newest `BACKUP_RETAIN` files of each
  database there. The two chains write to two directories, `backups` and `backups/mainnet`. So the
  two runs cannot delete each other's files.

Set `BACKUP_PASSPHRASE` and `BACKUP_REMOTE` in `.env.mainnet` before the first start. The nightly
backup aborts without the passphrase, and the start refuses.

Put both in by hand, as plain `NAME=value` lines. Use no quote marks, no `$`, no backtick, no space
followed by `#`, and no space at the start or the end of the value. The file mode stays 600. Keep a
copy of the passphrase somewhere that is not the host.

`BACKUP_REMOTE` is optional. Without it, the run prints a WARNING and still succeeds. The dumps then
stay on the host disk, which does not satisfy readiness item D1.

If `.env.mainnet` has no `BACKUP_REMOTE`, the workflow "Provision treasury secrets" (file
`.env.mainnet`) writes one: the remote in `.env`, plus `/mainnet`. For `r2:bucket` that is
`r2:bucket/mainnet`. It is a different destination, so the start accepts it. It is the same rclone
account, though, so a leaked rclone credential reaches both stacks' dumps. The dumps stay encrypted
with different passphrases. It never overwrites a value you set by hand, and it does not print it.

A mainnet treasury database that exists but is stopped cannot be dumped. The run prints
`mainnet treasury: clutch-main-treasury-treasury-postgres-1 exists but is not running: NOT backed up`
and fails. It dumps nothing, so it leaves no partial file. If you stop the whole mainnet treasury on
purpose, the nightly run therefore fails every night.

The restore rehearsal (`rehearse-restore.yml`) takes a chain. Choose `mainnet` and type `rehearse mainnet`.

- **Source `synthetic`** dumps the mainnet databases with a passphrase made for the run, restores them
  into throwaway databases inside the mainnet Postgres containers, counts the rows and drops them. It
  tests the scripts. It never touches the live databases.
- **Source `remote`** is the one that closes D1. It fetches the newest dump from the mainnet off-host
  remote, opens it with the real passphrase in `.env.mainnet`, restores it into a throwaway database,
  and runs one reconciliation against the copy (`treasury-service --reconcile-once`, through the
  mainnet compose file). The reconciliation reads the real mainnet chain and TronGrid. It runs no
  sweeper, no outbox and no payout workers, and writes nothing outside the copy. Both copies are
  dropped on every exit.
- The logs of these runs are public. On mainnet they print table names, row counts and file names,
  never a row, and never the name of the remote.
- A ledger with nothing in it reconciles trivially. A clean run on an empty ledger proves the path:
  the remote answers, the passphrase opens the dump, the restore loads, the reconciliation runs. It
  does not prove that data survives. Run it again after the first real deposits, and record both
  dates under D1.

`.env.mainnet` is not in these backups. It holds the mainnet `DEPOSIT_MNEMONIC`: see "What this
does not cover" above.
