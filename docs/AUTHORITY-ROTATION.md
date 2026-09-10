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
   - `chain` — all three heights advancing, and agreeing.
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

Do this on a throwaway network, not on stage, and not for the first time during an incident.

1. Bring up a local stack: `docker compose -p clutch-rot -f docker-compose.yml -f docker-compose.dev.yml up -d --build`.
2. Let it produce blocks. Note the height.
3. Rotate one authority by the procedure above and redeploy.
4. Confirm all nodes resume authoring and agree on height, and that the chain did **not** reset —
   height should continue, not restart from zero. If it restarted, something in `ChainInit` changed
   when it should not have.
5. Then rehearse the failure you are actually guarding against: change the list on **one** node
   only, and watch it reject blocks. Knowing what that looks like in the logs is the point of the
   rehearsal.

Record the date here when done.

## What this does not cover

- **The mint authority.** That *is* genesis-committed, so rotating it is a new genesis, not a
  restart. It is also the key readiness items A1 and A3 are about; do not rotate it by editing a
  TOML file.
- **Adding an authority on a host that does not exist yet.** That is readiness item C2 — the
  mainnet set has to run under operators that do not share a failure domain, which is a
  provisioning question rather than a config one.
