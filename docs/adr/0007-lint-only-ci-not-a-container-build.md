# 0007. Lint on every PR, and keep the container build out of CI

- **Status:** Accepted
- **Date:** 2026-09-20
- **Deciders:** Ben Atkinson
- **Feature / area:** ci
- **Builds on:** none — first ADR for ci
- **Supersedes / Superseded by:** none

## What problem were we trying to solve?

The repo had no CI at all: no `.github/workflows`, no branch protection on
`master`, and `allow_auto_merge` disabled. `gh pr checks` reported "no checks
reported" on every branch.

That surfaced when two open PRs (#8, #14) were ready to merge. Between them they
add **1,028 lines across 11 files**, and nothing verified any of it. "Merge when
CI passes" was not a condition that could be met, because there was no CI to
pass — the only available action was an unconditional merge.

## What did we try?

### Attempt 1: build `Containerfile.full` on every PR ❌ rejected

The obvious CI for a container repo, rejected on two counts.

**It is slow.** Stage 1 compiles qdomyos-zwift from source (`make -j$(nproc)`
after installing ~15 Qt5 `-dev` packages). Stage 2 adds i386 multiarch, Wine 11
from WineHQ, Mesa from `trixie-backports`, DXVK and VKD3D-Proton, then downloads
and runs `TPVirtual-Installer_v6.exe` under Xvfb. That is tens of minutes per PR
on a GitHub-hosted runner, and layer caching across PR runs is awkward for an
image this size.

**It would not have covered either open PR**, which is the stronger objection:

| PR | What it changes | Covered by an image build? |
|---|---|---|
| #14 | `tools/gpx-widen-curves.py` (422 lines) + README + 3 docs | no — nothing container-related |
| #8 | `run-tpv.sh`, `scripts/entrypoint.sh`, `verify.sh`, docs, **1 line** of `Containerfile.full` | barely |

So it was the most expensive check available, covering almost none of the diff.
It also re-fetches and executes a proprietary third-party installer from public
CI on every run, which this repo otherwise takes care not to redistribute.

### Attempt 2: gate shellcheck at `error` severity ❌ rejected

`--severity=error` was already clean across all 14 scripts, so it would have
gone green without asserting anything. At `warning` there were four findings,
all of them false positives:

- `scripts/build-prefix.sh` ×2 — SC2211, a glob used as a command name. The
  DXVK and VKD3D setup scripts live under a version directory unknown until
  build time, and both calls already have a `|| for ...` fallback. Intentional.
- `tools/kernel-test-vm/*.sh` ×3 — SC2034, unused `i` in `for i in $(seq 1 90)`.
  A plain retry loop that never reads the counter.

### Attempt 3: lint what the repo actually contains ✅ chosen

Three parallel jobs, matched to the file types in the tree.

## What did we land on, and why?

`.github/workflows/lint.yml` runs on every PR and on pushes to `master`:

| Job | Tool | Scope |
|---|---|---|
| `shellcheck` | runner's shellcheck, `--severity=warning` | all 14 `*.sh` |
| `ruff` | `ruff==0.11.7` via pipx | `tools/` |
| `hadolint` | `hadolint:v2.15.1-alpine` | `Containerfile.*` |

It finishes in well under a minute, so it is cheap enough to gate every PR on.

To let the shell gate sit at `warning` rather than the toothless `error`, the
four false positives were fixed at source rather than by lowering the bar: two
`# shellcheck disable=SC2211` directives, and `for i` → `for _` in the three
retry loops.

hadolint ignores five rules this image breaks deliberately — DL3008 (apt
versions float with the suite; the ones that matter are ARG-pinned), DL3003
(`cd /build` in a throwaway stage), DL3015 (winehq-stable needs its recommends),
DL3066 (the image creates a named user) and DL4006 (the shell is dash). Every
other hadolint rule still fails the job.

## What does this cost us?

- **Nothing proves the image still builds.** A syntactically fine Containerfile
  that fails at `make` will pass CI. The intended follow-up is a
  `workflow_dispatch` + weekly scheduled job running the real build, so
  breakage is caught on a timer instead of gating PRs.
- **shellcheck floats** with the runner image, so a future runner bump can
  introduce new warnings on untouched code. ruff and hadolint are pinned.
- **ruff runs its default rules only** (E4, E7, E9, F). It catches syntax
  errors, undefined names and unused imports, not style. There is no
  `pyproject.toml` to widen that yet.
- **The five hadolint ignores are global**, so a genuinely unpinned new apt
  install will not be flagged either.
