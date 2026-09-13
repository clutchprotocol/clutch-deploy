# Clutch-owned nginx routes

Readiness item G1. `scripts/ensure-nginx-clutch-block.sh` injects these files into the mounted
config on the stage host on every deploy, between markers, one managed block per vhost.

**One subdirectory per vhost, named for the vhost.** The directory name is the anchor the script
looks for — `server_name <that name>;` — so a typo is a failed deploy rather than a route in the
wrong server block:

```
clutch.d/app-stage.clutchprotocol.io/payment.conf
clutch.d/api-stage.clutchprotocol.io/...
```

A `.conf` sitting directly in this directory is refused: it has no vhost, so there is nowhere to
put it.

They contain **`location` blocks only** — no `server` blocks. The vhosts they land in are defined
in a file belonging to the `v2ray` compose project, which also serves several vhosts that are
nothing to do with Clutch. Adding a `server` block here would reach outside what this repo should
own, and the sync script refuses any change to the set of `server_name`s for that reason.

Every managed block is deleted and rebuilt on each deploy, so a file — or a whole vhost directory —
deleted here disappears from the host rather than accumulating as a route nobody can find in a
diff.

## Adding a vhost

Read what is on the host first. These routes were written by hand over time, and the repo has
never been the source of truth for them:

```
gh workflow run inspect-stage.yml -f probe=nginx -f vhost=<name>
```

Then move the `location` blocks across verbatim, deploy, and check the route still answers what it
answered before — not merely that nginx reloaded.
