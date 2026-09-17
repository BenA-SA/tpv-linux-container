# 0005. Install Mesa 26.1 from trixie-backports to stop i915 GPU hangs

- **Status:** Accepted
- **Date:** 2026-09-17
- **Deciders:** Ben Atkinson
- **Feature / area:** container-gpu-stack
- **Builds on:** none — first ADR for container-gpu-stack
- **Supersedes / Superseded by:** none

## What problem were we trying to solve?

TPV froze mid-ride with **i915 GPU hangs** (`GPU HANG ... in TPVirtual.exe`,
context reset, then `VK_ERROR_DEVICE_LOST` flooding DXVK) and never recovered
(#5). There were three hangs on the original image, ~7, ~60 and ~2 minutes in;
one came during pairing with the avatar standing still. So the trigger is
rendering in general, not distance ridden. Hardware: Intel Raptor Lake-P Iris
Xe; host Fedora 44, kernel 7.1.8, Mesa 26.1.6.

The image used Debian trixie's stable **Mesa 25.0.7** (ANV, early 2025).
There were no hangs in the host's kernel logs going back weeks, which points at
the container's userspace driver rather than the kernel or hardware.

## What did we try?

### Attempt 1: soak test with qdomyos-zwift's fake bike ❌ failed

We wanted an unattended, repeatable load test. QZ's fake bike only produces
power after an FTMS target-power command, but TPV only sends
request-control/simulation until the rider pedals, so they deadlocked. It was
replaced by a stand-in DIRCON trainer (Python stdlib) reporting a constant
200 W / 90 rpm. That setup also exposed TPV picking an unscoped IPv6 link-local
address from mDNS adverts, fixed with an IPv4-only A-record advert.

### Attempt 2: stay on Mesa 25.0.7 ❌ failed in practice

The baseline reproduced the hang on demand (3 hangs).

### Attempt 3: Mesa 26.1.2 from trixie-backports ✅ chosen

- **Why 26.1:** close to the host's working 26.1.6, and the 25.1–26.1 release
  notes carry many ANV hang and misrender fixes. No note names this exact hang,
  so it was an experiment.
- **Why not 26.2:** 26.2.0 has a reported i915 hang regression (fixed in
  26.2.1), so 26.2 was avoided for now.
- **Test image:** a derived image swapping only the Mesa packages.

| Image | Mesa (ANV) | Run | GPU hangs |
|---|---|---|---|
| `tpv-full:debian` | 25.0.7 | real rides + test launch | **3** (~7, ~60, ~2 min) |
| `tpv-full:mesa26` | 26.1.2 | 2026-09-15, 82 min soak | **0** |
| `tpv-full:mesa26` | 26.1.2 | 2026-09-17, 4 h 20 min+ soak, including Hub use | **0** (no `GPU HANG`, no `VK_ERROR_DEVICE_LOST`) |

## What did we land on, and why?

`Containerfile.full` installs `mesa-vulkan-drivers` and `libgl1-mesa-dri`
(amd64 and i386) from the `trixie-backports` suite, selectable with
`ARG MESA_SUITE=trixie-backports`. The base Vulkan loader and tools stay on
stable. The package diff against stable is Mesa only.

This won because it removed a hang that reproduced within minutes, and held for
more than 4 hours under continuous rendering. It needs no DXVK workarounds, and
it keeps the container's driver close to the host's.

Revisit if hangs return on 26.1.x. Next steps then: 26.2.1+, DXVK options (e.g.
`dxvk.enableGraphicsPipelineLibrary`), and an upstream Mesa report with
`/sys/class/drm/card*/error`.

## What does this cost us?

- **Moving target:** backports is a moving suite, so rebuilds pick up newer
  26.x (or later) Mesa without a code change. A regression could return (26.2.0
  had one). Pin a version with `MESA_SUITE` or a version constraint if that
  bites.
- **Tested on one machine:** only Intel Iris Xe (Raptor Lake-P) was soak-tested.
  Other GPUs get the newer Mesa untested.
- **Derived image, not a full rebuild:** the soak ran on an image built on top
  of the old one. A full `podman build` from this branch still needs a smoke test.
- **Soak tooling not in the repo:** the stand-in trainer and derived
  Containerfile aren't committed yet (`tools/soak/` on the laptop).
