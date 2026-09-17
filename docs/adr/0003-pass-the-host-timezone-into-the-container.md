# 0003. Pass the host timezone into the container and refresh the Wine prefix when it changes

- **Status:** Accepted
- **Date:** 2026-09-17
- **Deciders:** Ben Atkinson
- **Feature / area:** container-timezone
- **Builds on:** none — first ADR for container-timezone
- **Supersedes / Superseded by:** none

## What problem were we trying to solve?

TPV's HUD clock showed UTC instead of local time: an hour behind on a
`Europe/London` host during BST (#2). The container never received the host's
zone (`TZ` unset, `/etc/localtime` → `Etc/UTC`), and Wine derives the Windows
time zone from the Linux one. The fix had to follow the host automatically,
handle DST, still allow an explicit `TZ=` override, and work for existing users
whose Wine prefix was already created under UTC.

## What did we try?

### Option 1: pass `TZ` only ❌ considered, not enough on its own

`TZ` alone relies on the image's zoneinfo and a zone name `timedatectl` can
report. Some hosts don't have `timedatectl`, so there has to be a fallback.

### Option 2: bind-mount `/etc/localtime` only ❌ considered, not enough on its own

This gives the right offset, including DST, from the host's own zone file, but
no zone *name* for anything that reads `TZ`, and no simple override.

### Attempt: fix the environment and leave the prefix alone ❌ failed in practice

Even with the container's clock correct, a prefix created under UTC kept an
empty `TimeZoneKeyName`. Wine only rewrites it when the prefix is updated, so
existing installs would still show UTC.

## What did we land on, and why?

- **`run-tpv.sh`:** passes `TZ` (an explicit `TZ` override, else `timedatectl`'s
  zone) **and** bind-mounts `/etc/localtime` read-only. Together they cover
  zone-name and zone-file consumers.
- **`scripts/entrypoint.sh`:** `sync_timezone` keeps a marker file in the
  prefix (`TZ` plus a checksum of `/etc/localtime`). When the marker changes, it
  runs `wineboot -u` once and waits for `wineserver`. Existing UTC-era prefixes
  pick up the zone on the next start, without a `wineboot` on every launch.

## What does this cost us?

- **Slower start after a zone change:** the first start after a zone change (or
  on an old prefix) runs a `wineboot -u` prefix update.
- **One more host file mounted** into the container: `/etc/localtime`, read-only.
- **Not yet verified here:** that the HUD shows local time including the
  BST/GMT switch, and that `TZ=...` overrides the detected zone.
