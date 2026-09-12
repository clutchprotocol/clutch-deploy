# Clutch-owned nginx routes

Readiness item G1. Files here are synced onto the stage host by
`scripts/ensure-nginx-clutch-include.sh` on every deploy and pulled in by a single `include` line
inside the clutch vhost.

They contain **`location` blocks only** — no `server` blocks. The vhost they land in is defined in
a file belonging to the `v2ray` compose project, which also serves several vhosts that are nothing
to do with Clutch. Adding a `server` block here would reach outside what this repo should own, and
the sync script refuses any change to the set of `server_name`s for that reason.

A file deleted here is deleted on the host on the next deploy, so a route always matches what is
in this directory rather than accumulating whatever was ever added.
