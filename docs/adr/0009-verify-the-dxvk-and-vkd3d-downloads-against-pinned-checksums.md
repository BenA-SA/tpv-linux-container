# 0009. Verify the DXVK and VKD3D-Proton downloads against pinned checksums

- **Status:** Accepted
- **Date:** 2026-09-20
- **Deciders:** Ben Atkinson
- **Feature / area:** container-build
- **Builds on:** ADR-0008
- **Supersedes / Superseded by:** none

## What problem were we trying to solve?

`Containerfile.full` pulled the two graphics translation layers straight off
GitHub and piped them into `tar` without looking at them:

```
RUN curl -fsSL ".../dxvk-${DXVK_VERSION}.tar.gz"          | tar -xz -C /opt \
 && curl -fsSL ".../vkd3d-proton-${VKD3D_VERSION}.tar.zst" | tar --zstd -x -C /opt
```

The **versions** were pinned (`DXVK_VERSION=3.1`, `VKD3D_VERSION=3.0.1`), but
the **bytes** were not. A release tag is mutable: an upstream maintainer, or
anyone who compromises those accounts, can delete and re-push a tag with
different content under the same URL. Nothing in the build would notice, and
what lands in `/opt` is a set of DLLs that Wine loads into the process that
drives the trainer.

The pipe made it worse. `curl … | tar -x` extracts as it downloads, so the
archive is already on disk by the time the transfer finishes. There is no
point at which the complete file exists and could be inspected before it is
trusted. Verification is impossible without first breaking the pipe.

This is the one unverified download left in the image. Everything else is
already covered: apt checks Debian, WineHQ and Mesa packages against their
signing keys (ADR-0008 leaned on exactly that when it dropped `gnupg`), and
the base images are content-addressed by digest.

## What did we try?

### Attempt 1: take a checksum from upstream ❌ not available

The preference was to use a digest upstream publishes, not one we compute —
ours only proves *we all got the same bytes*, it says nothing about what the
maintainer intended. Both projects were checked:

```
$ gh api repos/doitsujin/dxvk/releases/tags/v3.1 --jq '.assets[].name'
dxvk-3.1.tar.gz
$ gh api repos/HansKristian-Work/vkd3d-proton/releases/tags/v3.0.1 --jq '.assets[].name'
vkd3d-proton-3.0.1.tar.zst
```

One asset each. No `.sha256`, no `.asc`, no `.sig`, and no digest anywhere in
either release body (grepping both for `sha`/`checksum`/`sig` finds only prose
— "shaders", "signal"). Neither project publishes checksums at all, so there
was nothing to prefer over a locally computed one.

So the checksums below are ours, computed by downloading both artefacts. The
one corroboration available is that both match the size GitHub's API reports
for the asset (18 056 721 and 5 163 266 bytes), which is metadata served by a
different path from the tarball itself. This is a **tamper-evidence** control,
not a supply-chain **trust** control: it freezes today's bytes so a later swap
is caught, and it cannot tell us those bytes were honest to begin with.

### Attempt 2: `ADD --checksum=sha256:…` ⚠️ works, but rejected on size

This is what netbrain/zwift does, and the first question was whether our
toolchain even supports it — Docker gained it in BuildKit, and podman is a
different implementation. It does. Tested on the real podman 5.8.4:

```
STEP 2/3: ADD --checksum=sha256:3cf2315…c 
          https://…/vkd3d-proton-3.0.1.tar.zst /tmp/v.tar.zst
--> c1fc0ce3353b                                    # correct sum: builds
```

and with one character changed:

```
Error: building at STEP "ADD --checksum=sha256:0cf2315…": unexpected response
digest for "https://…/vkd3d-proton-3.0.1.tar.zst":
sha256:3cf2315…, want sha256:0cf2315…
```

It is the cleanest expression of the intent: declarative, no shell, and the
check cannot be bypassed by a mistake in a pipeline. It was rejected anyway,
for a reason specific to this image: **`ADD` from a URL does not extract.**
Docker and podman only auto-extract *local* archives, so `ADD` can only drop
the tarball on disk, and a later `RUN` has to unpack it. That later `RUN` is a
different layer, so its `rm` cannot reclaim what `ADD` already committed — both
tarballs stay in the image forever.

Measured, building each variant on an identical base:

| Variant | Image | Delta |
|---|---|---|
| base (`debian:trixie` + curl, zstd) | 146 MB | |
| `ADD --checksum` ×2, then `RUN tar … && rm` | **228 MB** | +82 MB |
| single `RUN` curl + verify + tar + rm | **205 MB** | +59 MB |

**23 MB of dead tarball**, which is exactly the DXVK and VKD3D archives
(18.1 MB + 5.2 MB) surviving the `rm`. ADR-0008 spent a whole pass clawing back
60 MB; handing a third of it straight back for syntax is not a trade worth
making.

### Attempt 3: download to a file, `sha256sum -c`, then extract ✅ chosen

### A note on `--strict`, which we nearly got wrong

The first version of the chosen approach used a plain `sha256sum -c -`. That is
quietly broken. If a checksum ARG is ever blank or malformed, GNU coreutils
treats the line as *improperly formatted* and **only warns** — the exit status
is still 0, and the archive is extracted unverified. Blanking `DXVK_SHA256` and
building proves it:

```
# sha256sum -c -
/tmp/vkd3d.tar.zst: OK
sha256sum: WARNING: 1 line is improperly formatted
Successfully tagged localhost/v-run-empty-ns:latest      # exit 0 — unverified

# sha256sum --strict -c -
/tmp/vkd3d.tar.zst: OK
sha256sum: WARNING: 1 line is improperly formatted
Error: … while running runtime: exit status 1            # exit 1
```

`--strict` promotes that warning to a failure. Without it the gate degrades
silently to no gate at all in precisely the case it most needs to hold — a
half-finished version bump.

## What did we land on, and why?

Each checksum sits immediately under the version it belongs to, so a bump that
forgets the digest is visible in the diff rather than buried 40 lines away:

```
# Each graphics-layer version is pinned with its release tarball's sha256, so a
# swapped or tampered tarball fails the build. Bump the two lines together.
ARG DXVK_VERSION=3.1
ARG DXVK_SHA256=30f9cc326874be344285582275446968cfa4c069db31ce56df312d6644179154
ARG VKD3D_VERSION=3.0.1
ARG VKD3D_SHA256=3cf2315522af5e43605ef6d3c41dad91387040bf97199934f3f7ab76caaa2f0c
```

and one `RUN` downloads both, verifies both, then extracts both:

```
RUN curl -fsSL -o /tmp/dxvk.tar.gz  "…/dxvk-${DXVK_VERSION}.tar.gz" \
 && curl -fsSL -o /tmp/vkd3d.tar.zst "…/vkd3d-proton-${VKD3D_VERSION}.tar.zst" \
 && printf '%s  /tmp/dxvk.tar.gz\n%s  /tmp/vkd3d.tar.zst\n' \
      "${DXVK_SHA256}" "${VKD3D_SHA256}" | sha256sum --strict -c - \
 && tar -xz -C /opt -f /tmp/dxvk.tar.gz \
 && tar --zstd -x -C /opt -f /tmp/vkd3d.tar.zst \
 && rm -f /tmp/dxvk.tar.gz /tmp/vkd3d.tar.zst
```

Both archives are checked **before either is extracted**, so a bad DXVK tarball
cannot leave a half-populated `/opt` behind. Everything happens in one layer, so
the `rm` genuinely reclaims the 23 MB. `zstd` was already kept for this step by
ADR-0008; `curl` was already kept because `entrypoint.sh` needs it at runtime.
No new packages.

The gate was proved to bite, not merely to exist. Corrupting `DXVK_SHA256` to
`deadbe…` fails the build:

```
/tmp/dxvk.tar.gz: FAILED
/tmp/vkd3d.tar.zst: OK
sha256sum: WARNING: 1 computed checksum did NOT match
Error: … while running runtime: exit status 1
```

The happy path was proved on the real thing, not just the layer: a full
`podman build --no-cache -f Containerfile.full` succeeded in **7m12s** and
produced a **6.63 GB** image — the same size ADR-0008 measured, so the `rm`
does reclaim the tarballs. Both archives land where they did before,

```
/opt/dxvk-3.1/x64/{d3d8,d3d9,d3d10core,d3d11,dxgi}.dll
/opt/vkd3d-proton-3.0.1/x64/{d3d12,d3d12core}.dll
```

and `build-prefix.sh`, which globs `/opt/dxvk-*` and `/opt/vkd3d-proton-*`,
resolves them unchanged (`system32/d3d12.dll -> /opt/vkd3d-proton-3.0.1/x64/
d3d12.dll`). Nothing downstream moves.

## What does this cost us?

- **The checksum is ours, not upstream's.** It proves the bytes have not changed
  since 2026-09-20; it does not prove they were trustworthy then. If either
  project starts publishing digests or signatures, switch to those — that is a
  real upgrade, not a restatement of this one.
- **A version bump is now a two-line edit**, and getting it half-right is a
  build failure rather than a silent pass. That is the point, but it is friction,
  and the failure surfaces only when someone rebuilds. `--strict` is what makes
  the half-done case fail rather than warn; anyone simplifying that line later
  will reintroduce the hole.
- **The download layer is slightly slower**: the archives are written to `/tmp`
  and read back instead of being extracted from the stream. It is ~23 MB of
  local I/O against a ~23 MB network transfer, and the layer caches, so it is
  noise next to the 385 s build.
- **The TPV installer is still unverified.** `entrypoint.sh` fetches
  `TPVirtual-Installer_v6.exe` at runtime from a vendor URL with no digest, and
  it is a self-updating proprietary installer whose bytes legitimately change —
  so a pinned checksum would break it rather than protect it. This ADR does not
  address that, and the image's largest unverified input remains unverified.
- **We now carry a small amount of state that rots.** Two digests that mean
  nothing to a reader and can only be regenerated by downloading the artefacts.
  That is inherent to checksum pinning; the mitigation is keeping them adjacent
  to the versions so the diff makes the pairing obvious.
