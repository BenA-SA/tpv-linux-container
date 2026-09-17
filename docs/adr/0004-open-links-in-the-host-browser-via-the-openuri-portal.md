# 0004. Open TPV's account-linking links in the host browser via the OpenURI portal

- **Status:** Accepted
- **Date:** 2026-09-17
- **Deciders:** Ben Atkinson
- **Feature / area:** host-browser-links
- **Builds on:** none — first ADR for host-browser-links
- **Supersedes / Superseded by:** none

## What problem were we trying to solve?

Clicking **Connect Garmin** when TPV loads did nothing: no browser and no error
(#6). The same applies to Strava, TrainingPeaks, intervals.icu and the other
account-linking buttons. TPV calls `OpenURL` with an OAuth page. Under Wine
that goes to `xdg-open`, and the container has no browser, so the request was
silently dropped.

A key finding shaped the fix: the OAuth redirect goes to
`api.indievelo.com`, **not** a localhost callback or a custom URI scheme. The
login only has to happen in *a* browser; nothing needs to reach back into the
container or Wine.

## What did we try?

### Option 1: install a browser in the image ❌ considered, rejected

It would add hundreds of MB to an already ~6.6 GB image, give a second browser
profile without the user's saved logins or password manager, and need more
display and sandbox plumbing inside the container.

### Option 2: only print the URL for the user to open by hand ❌ considered, kept as the fallback

It always works, but it's poor UX for a button users expect to just open a
page, and the URL only appears in container output.

### Option 3: forward links to the host desktop over D-Bus ✅ chosen

`org.freedesktop.portal.OpenURI` is the standard way sandboxed apps (Flatpak)
ask the desktop to open a link, and every mainstream Linux desktop provides it.
The container only needs the host session bus mounted.

## What did we land on, and why?

- **`scripts/xdg-open-host.sh`**, symlinked as `/usr/local/bin/xdg-open` in the
  image. It accepts only `http(s)` and `mailto` links and calls
  `OpenURI.OpenURI` with `gdbus` (new package `libglib2.0-bin`). If there's no
  session bus or the portal refuses, it prints the link to open by hand.
- **`run-tpv.sh`** mounts `$XDG_RUNTIME_DIR/bus` as `/run/host-session-bus`
  and sets `DBUS_SESSION_BUS_ADDRESS`. Without a session bus it warns that the
  account-linking buttons can't open a browser.

This won because the link opens in the user's own browser, with their existing
logins, at the cost of one small package and one mount. Because the OAuth
redirect lands on TPV's servers, no callback handling is needed.

## What does this cost us?

- **More host coupling:** the container now has the host **session** bus as
  well as the system bus. Anything in the container can talk to session
  services, so this is packaging, not sandboxing (see README Scope).
- **Only link types are filtered:** anything other than http(s)/mailto is
  refused, but any http(s) URL TPV asks for will open without confirmation.
- **Headless sessions** (no session bus or portal) fall back to printing the
  link.
- **Not yet verified here:** that Garmin linking completes end to end and
  persists across container restarts.
