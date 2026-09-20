# 0008. Order the image build around the Wine prefix, and drop packages nothing uses

- **Status:** Accepted
- **Date:** 2026-09-20
- **Deciders:** Ben Atkinson
- **Feature / area:** container-build
- **Builds on:** none — first ADR for container-build
- **Supersedes / Superseded by:** none

## What problem were we trying to solve?

`Containerfile.full` is expensive: a full build is **438 s** and the image is
**6.69 GB**. Most of that is inherent (compiling qdomyos-zwift, Wine, Mesa,
DXVK, VKD3D and a template WINEPREFIX), but the *everyday* cost was not.

The single most expensive layer is `RUN /opt/scripts/build-prefix.sh`, which
runs `wineboot`, installs DXVK and VKD3D, then downloads the proprietary TPV
installer and drives Inno Setup under Xvfb with a 900 s timeout. Two unrelated
things sat **above** it and invalidated it:

| Step | Before | After |
|---|---|---|
| `COPY --from=qzbuild` (QZ binary) | 12 | 18 |
| `COPY scripts/` (all scripts) | 14 | 19 |
| `RUN build-prefix.sh` | **18** | **15** |

So editing any script — `entrypoint.sh`, `xdg-open-host.sh`, `verify.sh` — or
bumping `QZ_COMMIT` re-ran the Wine prefix build and re-downloaded the
installer. Measured on a one-line edit to `scripts/entrypoint.sh`, the log
showed it really happening:

```
==> wineboot (initialising /opt/tpv/wine-template)
==> DXVK
==> TPV launcher (Inno Setup; /VERYSILENT - WiX flags are ignored)
==> TPV launcher installed into the image: TPVirtual-Launcher.exe
```

## What did we try?

### Attempt 1: build the container in CI to catch this ❌ rejected earlier

Covered in ADR-0007: too slow, and it covers almost none of the diffs. Not
revisited here.

### Attempt 2: drop i386 multiarch ⏸ deferred, not rejected

The largest single saving available: **77 MB of downloads** (and considerably
more installed) for `mesa-vulkan-drivers:i386`, `libgl1-mesa-dri:i386` and
`libvulkan1:i386`. The Containerfile says i386 is enabled because the TPV
installer is PE32, which is a *build-time* need. If the launcher and the game
are both 64-bit it is dead weight at runtime.

Not taken here, because proving it needs a build **and an actual ride**. If any
32-bit code runs, the ride breaks and only riding finds out. It belongs in its
own change that can be tested that way.

### Attempt 3: `debian:trixie` → `trixie-slim` ⏸ deferred

A measured 43 MB (124 MB → 81 MB), but slim drops packages this image may rely
on indirectly. Same reasoning: separable, and worth testing on its own.

### Attempt 4: reorder around the prefix, and remove unused packages ✅ chosen

## What did we land on, and why?

**Reordering.** Only `build-prefix.sh` and `xvfb-lib.sh` are copied before the
prefix build. The QZ binary and the remaining scripts are copied after it,
where they are cheap to rebuild. Nothing about the resulting image changes;
only the order of the layers does.

**Packages removed** from the runtime stage, after checking every script for
the binaries they invoke:

| Package | Why it can go |
|---|---|
| `gnupg` | 7.1 MB, **26 packages**. Verified unnecessary: trixie's apt verifies the `signed-by` WineHQ key through Sequoia, and `apt-get update` resolves `winehq-stable` with neither `gnupg` nor `gpgv` installed |
| `vulkan-tools` | 1.8 MB, 9 packages. Referenced nowhere in the repo |
| `cabextract` | Referenced nowhere |
| `tar` | Already Essential in the base image; listing it installed nothing |

**Packages deliberately kept**, because grepping found real uses that a size
pass would otherwise have removed:

- **`curl`** — not just build-time. `scripts/entrypoint.sh` re-downloads the TPV
  installer at **runtime** when the launcher is missing from the volume.
- **`zstd`** — `tar --zstd` extracts the VKD3D-Proton release at build time.
- **`procps`** — no script calls `ps`, but it is 1 MB and Wine's process
  handling is not worth the risk.

**One apt index.** The three `apt-get update` runs became one: the WineHQ and
Mesa repositories are added before the update, so the lists are fetched once
and dropped once.

**Measured results:**

| | Before | After | Change |
|---|---|---|---|
| Image size | 6.69 GB | 6.63 GB | −60 MB |
| Full build | 438 s | 385 s | −53 s (−12%) |
| **Rebuild after a script edit** | **67 s** | **3 s** | **−95%** |
| Cached layers on that rebuild | 19 | 26 | |
| Prefix build re-ran? | **yes** | no (`Using cache`) | |

Both full builds ran with only 3 and 5 cached layers, so that comparison is
fair rather than an artefact of a warm cache.

## What does this cost us?

- **The apt layer is coarser.** One `RUN` now installs the base packages, Mesa
  and Wine, so changing any of them rebuilds all three. They change rarely, and
  the single index fetch is worth more than the granularity.
- **The QZ bump case is argued, not measured.** The step ordering proves the
  binary now lands after the prefix, but bumping `QZ_COMMIT` to time it would
  mean a full recompile on both trees. The reordering is structural, so the
  measured script-edit case exercises the same mechanism.
- **The two big size levers are still on the table**, and this ADR does not
  take them: i386 (77 MB of downloads) and `trixie-slim` (43 MB). Both need a
  real ride to validate, so they stay separable.
- **`procps` is kept on suspicion, not evidence.** If a later pass wants the
  1 MB, check whether Wine or `wineserver` shells out to `ps` first.
