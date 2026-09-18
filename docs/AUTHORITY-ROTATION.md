# Rotating the validator authority set

Readiness item **C3**. How to replace, add or remove an Aura authority without splitting the
network.

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

Two couplings, neither obvious from the config file:

**1. The slot-to-author mapping depends on order *and* length.**
`author_at_slot` is `authorities[slot % authorities.len()]`. A node with a stale list expects a
block from a departed authority and rejects one from a new authority, so it will reject blocks the
rest of the network accepts. **The set must change on every node together. Rotation is a
coordinated restart, not a rolling one.**

**That node does not stop, and this is the part that bites.** Rejecting is only half of what it
does. For every slot its own list wrongly says it owns, it authors its own block and appends that
instead. So it keeps perfect pace with the network at the **same height on a different chain**.
Rehearsed on 2026-09-18: node1 and node2 both ran 12 → 16 while holding different blocks at 14 and
16, node2 logging

```
Failed to add block to blockchain: "Block author verification failed:
expected author 0x6fc11ba4..., but found 0x9b6e8aff..."
```

for each one it threw away. Nothing about the height shows this. **A half-finished rotation looks
exactly like a healthy network to any check that compares heights** — which is what every check
here did until that rehearsal.

**2. The set size sets the block cadence.**
`step_duration = 60 / authorities.len()` seconds. Three authorities own 20-second slots; five own
12; six own 10. So adding or removing an authority is a consensus-timing change, not a roster edit.
Decide the size deliberately.

There is also a hard ceiling of **60**. Past it the step duration truncates to zero and every slot
calculation divides by zero. An empty set divides by zero at construction. Both are refused at
startup with a message naming the reason (`clutch-node` `ff53d5c`), along with a duplicate
authority, which otherwise silently takes two slots per round.

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
   - `chain` — all three heights advancing, **and its "do they hold the SAME block" section
     reporting OK**. Advancing, agreeing heights are not enough on their own: that is exactly what
     a forked node produces. The section compares head hashes at a height all three have reached.
   - `containers` — no node restarting in a loop.

## Adding or removing an authority

Everything above, plus:

- **The block cadence changes.** Work out `60 / new_len` and confirm it is what you want. Going
  from three to four authorities moves slots from 20 seconds to 15.
- **Do not do this at the same time as a key replacement.** One variable at a time; if the network
  stalls you want to know which change did it.
- Check the new size against the 60 ceiling. The node now refuses to start past it rather than
  panicking later, but a refusal at boot is still an outage if you deploy it to every node at once.

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
3. A node with **no data at all** can still sync the whole history. This one is not obvious and is
   the reason the rehearsal is worth running: existing blocks were authored by the key that was
   just rotated out, and a fresh node validates that history against the *current* list. It passes
   — but had it not, rotation would work for every running node and silently break every new one,
   which you would discover on the day you add a server. That is the same day you rotate.
4. A node given a **different order** forks rather than lagging, as described above. That is the
   failure this whole procedure guards against, and the rehearsal is where you get to see it once
   with nothing at stake.

The first run of it is what corrected this document: assertion 4 was originally written as "must
fall behind" and failed, because the node kept pace at an identical height on its own chain.

## What this does not cover

- **The mint authority.** That *is* genesis-committed, so rotating it is a new genesis, not a
  restart. It is also the key readiness items A1 and A3 are about; do not rotate it by editing a
  TOML file.
- **Adding an authority on a host that does not exist yet.** That is readiness item C2 — the
  mainnet set has to run under operators that do not share a failure domain, which is a
  provisioning question rather than a config one.
