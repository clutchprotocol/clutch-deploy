# Rotating the validator authority set

Readiness item **C3**. How to replace, add or remove an Aura authority without splitting the
network.

## Where each network's files are

- **Local dev:** `config/node/`. The secrets are public, on purpose. Never point a network other people can reach at it.
- **Stage:** `config/node-stage/`. Addresses only. The secrets are `TESTNET_NODE{1,2,3}_AUTHOR_SECRET` in the host's `.env.testnet`, which compose passes to the nodes as `APP_AUTHOR_SECRET_KEY`.
- **Mainnet:** `config/node-mainnet/`. Addresses only. The secrets are `MAINNET_NODE{1,2,3}_AUTHOR_SECRET` in `.env.mainnet`.

The steps below say `config/node/` because that is where they were first written. For stage or mainnet, edit the same three files in that network's folder. `scripts/check-genesis.sh` fails a folder other than `config/node` that holds a secret or reuses a dev address.

### Stage: the first move off the dev keys

Until 2026-10-29 stage ran the dev keys, and someone moved CLT out of two of the authority accounts (a report, confirmed on the stage explorer). The fix needs no chain reset, because `authorities` is not in the genesis. It is a coordinated restart of the three nodes, which a stage deploy already is.

1. Run **Stage — generate validator keys (once)** and type `GENERATE`. It writes the three secrets into the host's `.env.testnet` and prints the three addresses.
2. Put the addresses into `config/node-stage/node{1,2,3}.toml`: each node's own `author_public_key`, and the same `authorities` list in all three, in order.
3. Merge. The deploy runs `up -d --force-recreate`, so all three nodes restart together with the new keys.
4. Check as in "Replacing a key" below: no `author verification failed` that keeps coming after all three are up (a few while they restart are normal), `PROBE=chain` shows the same block on all three, and `/api/v1/validators` on the stage explorer lists the new addresses.
5. Declare the retired set, as in "Declare the retired set" below: a node that is behind the rotation, or new, cannot sync past it until every node's config names the old keys. Stage node1 was behind and hit exactly this on 2026-10-29. For stage the last block of the old keys was 163,015, and `config/node-stage/node{1,2,3}.toml` now end with that table.

The old three addresses stay in the chain's history and their accounts keep what they held. Nothing needs to move.

## What is and is not committed to genesis

This is the part that decides how big the job is, and an earlier version of the readiness doc had
it wrong. `ChainInit` — the genesis-committed parameter set, hashed and compared by peers at
handshake — carries:

`chain_id`, `is_testnet`, `tx_fee`, `ride_request_referrer_fee_bps`, `ride_offer_referrer_fee_bps`,
`mint_authority`, `faucet_address`, `faucet_allocation`.

It does **not** carry `authorities`. That list is per-node config, read at startup into
`Aura::new`. So **rotating an authority needs no chain reset** and no new genesis. Changing any of
the eight above does.

## What makes it non-trivial anyway

Three couplings, neither obvious from the config file:

**1. The slot-to-author mapping depends on order *and* length.**
`author_at_slot` is `authorities[slot % authorities.len()]`. A node with a stale list expects a
block from a departed authority and rejects one from a new authority, so it will reject blocks the
rest of the network accepts. **The set must change on every node together. Rotation is a
coordinated restart, not a rolling one.**

**That node does not stop, and this is the part that bites.** It rejects, over and over, and
carries on running. Rehearsed on 2026-09-18 with one node's list merely reordered: it logged

```
Failed to add block to blockchain: "Block author verification failed:
expected author 0x6fc11ba4..., but found 0x9b6e8aff..."
```

ten times in three minutes — and stayed level with the network the whole time, on the same chain.
Every height compared by block hash was identical to the others', in both rehearsal runs. It did
not fall behind, it did not halt, and it did not fork.

So **the only signal is that log line.** No metric counts these rejections; `latest_block_index`
kept climbing normally throughout. A container running a half-finished rotation looks healthy in
the probe, in Grafana, and in the height figures, and only its own log says otherwise. Check
`docker logs` for `author verification failed` after any rotation, and do not treat healthy
heights as evidence the rotation landed.

One caveat worth keeping in mind rather than relying on: this was two runs of a three-node network
where the other two nodes agreed with each other. A mismatch that splits the set more evenly has
not been rehearsed, and convergence should not be assumed to be guaranteed by anything — it is
what was observed, not a property anyone designed.

**2. The set size sets the block cadence.**
`step_duration = 60 / authorities.len()` seconds. Three authorities own 20-second slots; five own
12; six own 10. So adding or removing an authority is a consensus-timing change, not a roster edit.
Decide the size deliberately.

There is also a hard ceiling of **60**. Past it the step duration truncates to zero and every slot
calculation divides by zero. An empty set divides by zero at construction. Both are refused at
startup with a message naming the reason (`clutch-node` `ff53d5c`), along with a duplicate
authority, which otherwise silently takes two slots per round.

**3. History is checked against the set that signed it.**
A rotation leaves old blocks signed by keys that are no longer in the list, and a node checks every block it imports, sync included. See "Declare the retired set" below.

## Declare the retired set

A node checks every block it imports against the authority set that was valid at that block's height, and it knows only the sets its config names. A node that only knows the new list refuses every old block: `Block author verification failed: expected author <new>, but found <old>`. Nodes at the head never import old blocks, so a rotation looks fine until a node is behind or new. On 2026-10-29 stage node1 was already behind when the stage keys were replaced. It logged that line about 2,800 times in 30 minutes and stayed at block 144,511.

So after every rotation, add the retired set to every node's config, at the END of the file (a TOML array of tables comes after every plain key):

```toml
[[previous_authorities]]
until_block = 163015
authorities = [
    "0x9b6e8afff8329743cac73dbef83ca3cbf9a74c20",
    "0x6fc11ba44483201f6e9c5eba6435805bb94ad080",
    "0xc4f3f661a43e099aedb8e396d9de1a831a1b4adc",
]
```

- `until_block` is the LAST block the retired set authored. On the explorer it is the block before the first one by a new key. Stage: block 163,015 was made by an old key at 14:44:40 UTC and block 163,016 by a new key at 14:45:20 UTC. Use the exact number: it decides which set checks which block.
- Keep the old order. The slot of a block picks its author by position.
- A second rotation adds a second table, oldest first. A retired set keeps its own size and slot length (`60 / len`), so adding or removing an authority is covered too.
- The same tables go in all three files. Nodes at the head never read them, so they need no reset and no coordinated restart: add them after the rotation, in a second deploy.
- They need a clutch-node image with `previous_authorities` ([clutch-node #27](https://github.com/clutchprotocol/clutch-node/pull/27)). An older image ignores the table, and the problem stays.
- The old keys stay dead. The head is checked against `authorities` alone, and the retired set only checks blocks up to `until_block`.

## Replacing a key, same set size

Cadence is unchanged, so this is the simpler case.

1. Generate the new keypair for the replacement authority. Its **address** goes in the
   `authorities` list; its **secret** goes only on the host that will author with it.
2. Edit `authorities` in **all three** of `config/node/node1.toml`, `node2.toml`, `node3.toml`.
   Keep the list **byte-identical and in the same order** across all three. Put the replacement at
   the same index as the authority it replaces, so the slot schedule is otherwise untouched.
3. Set the new node's own `author_public_key` / `author_secret_key`.
4. Commit and deploy. A push touching `config/**` triggers `deploy-stage.yml`, which does
   `up -d --force-recreate` — that restarts all nodes, which is what "coordinated" requires here.
   **Do not** restart nodes one at a time.
5. Verify with `inspect-stage.yml`:
   - **`docker logs` on each node for `author verification failed`.** This is the check that
     actually catches a half-finished rotation, and the only one that does. Heights keep climbing
     on a node whose list is wrong.
   - `chain` — all three heights advancing, and its "do they hold the SAME block" section
     reporting OK. Equal heights are not by themselves agreement, so that section compares head
     hashes; it has never caught a divergence, and it is there because the comparison is cheap and
     the assumption that equal heights mean equal chains is not one worth making on a redeemable
     token.
   - `containers` — no node restarting in a loop.
6. Declare the retired set, as in "Declare the retired set" above: find the last block the old key authored, add `[[previous_authorities]]` to all three files, and deploy again. Do it the same day. Until then a node that is behind the rotation, or new, cannot sync past it.

## Adding or removing an authority

Everything above, plus:

- **The block cadence changes.** Work out `60 / new_len` and confirm it is what you want. Going
  from three to four authorities moves slots from 20 seconds to 15.
- **Do not do this at the same time as a key replacement.** One variable at a time; if the network
  stalls you want to know which change did it.
- Check the new size against the 60 ceiling. The node now refuses to start past it rather than
  panicking later, but a refusal at boot is still an outage if you deploy it to every node at once.
- **Declare the retired set too.** It keeps its own size and slot length (`60 / len`) in `previous_authorities`, so the blocks it signed are still checked the way they were made.

## The rehearsal, which is what closes C3

**Done 2026-09-18.** It is now `.github/workflows/rehearse-authority-rotation.yml` rather than a
list to follow by hand, so it can be re-run before each real rotation instead of read. It runs on
dispatch and on any pull request touching `config/node/**`, `docker-compose.yml` or itself. A
GitHub runner is the throwaway network the rehearsal needs: it exists for one job and is destroyed
after, and it is not stage.

It asserts four things, in this order:

1. The chain **continues** across a rotation — height does not go backwards when one authority is
   replaced at the same index on all three nodes and all three restart together. If it restarted,
   something in `ChainInit` changed when it should not have.
2. All three hold the **same block** at the same height afterwards, compared by hash.
3. A node with **no data at all** can sync the whole history. The rehearsal wipes node2 and waits
   for it to reach the head. It passed twice on 2026-09-18, with ONE key replaced. **That did not
   predict stage.** On 2026-10-29 all three stage keys were replaced, and a node that was behind
   could not sync past the rotation: it checks every old block against the set that signed it, and
   a node that only knows the new list refuses them all (see "Declare the retired set"). Why the
   rehearsal passed has not been found, and it has not been run since. So assertion 3 is no
   evidence that a rotation is safe for a lagging or new node. Known gap: the rehearsal should
   declare the retired set in the wiped node's config and run against an image that supports it.
4. A node given a **different order** rejects blocks and says so in its log, as described above.
   That is the failure this whole procedure guards against, and the rehearsal is where you get to
   see it once with nothing at stake.

Assertion 4 is the reason to run this rather than read it. It was first written as "must fall
behind", which failed — the node kept pace. Then as "must fork", which also failed — the chains
were identical at every height compared by hash. Only the log line held. Two plausible failure
modes were nearly written into this document as fact before the runs contradicted them both.

## What this does not cover

- **The mint authority.** That *is* genesis-committed, so rotating it is a new genesis, not a
  restart. It is also the key readiness items A1 and A3 are about; do not rotate it by editing a
  TOML file.
- **Adding an authority on a host that does not exist yet.** That is readiness item C2 — the
  mainnet set has to run under operators that do not share a failure domain, which is a
  provisioning question rather than a config one.
