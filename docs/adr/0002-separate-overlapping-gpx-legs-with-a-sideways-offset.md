# 0002. Separate overlapping GPX route legs with a uniform sideways offset

- **Status:** Accepted
- **Date:** 2026-09-17
- **Deciders:** Ben Atkinson
- **Feature / area:** custom-route-overlap
- **Builds on:** none — first ADR for custom-route-overlap
- **Supersedes / Superseded by:** none

## What problem were we trying to solve?

During a ride on a custom route built from the IRONMAN 70.3 Malaga bike course,
TPV intermittently drew a second road at head height that hid the rider (#4).
We first suspected the container's Mesa/DXVK stack, since the same session had
i915 GPU hangs (#5). But TrainingPeaks documents the failure itself: legs of a
custom route that overlap render badly, and its GPX guide says the two
directions should be kept about 10 m apart. Release notes and reviews show the
same bug on Windows.

Analysis of the uploaded file backed this up. The course is one 89.85 km
out-and-back, with ~42 km retraced in the opposite direction at 1.5–9 m
spacing, and 95% of it within 10 m of another part of itself. Race organisers'
GPX files put both directions on the centreline, so other riders' race-prep
courses will have the same problem.

Constraints:
- We can't change TPV.
- The fix has to keep the course a faithful copy of the race: same distance and
  same elevation profile.
- It has to be something other riders can apply, including people who don't use
  this container.

## What did we try?

### Attempt 1 — treat it as a driver/translation-layer bug ❌ rejected

It matched the i915 hangs in time, but a GPU fault can't explain a road
appearing only where the route doubles back. Nothing in the Mesa 25.1–26.1
release notes describes misplaced geometry on this chip. #4 was closed as a TPV
route bug.

### Attempt 2 — shift only the return leg ❌ rejected up front

Moving just the second half is intuitive for a simple out-and-back. But it needs
the turnaround and the leg boundaries found reliably. It leaves a step where the
shifted and unshifted parts meet, and it doesn't generalise to courses whose
legs interleave (loops with spurs, several out-and-backs).

### Attempt 3 — edit by hand in a GPX editor ❌ rejected

It's workable for a few hundred metres, but not for ~42 km of doubled course,
and it's hard to do without changing the distance or losing elevation data.

### Attempt 4 — uniform sideways offset ✅ chosen

Move every point the same distance D perpendicular to a smoothed direction of
travel (±25 m window), to the right (or left, by country). Legs in opposite
directions move apart by ~2D, like the two carriageways of a road, and each leg
keeps its shape. On Malaga:
- D = 6 m was the smallest whole metre giving ≥ 12 m everywhere (min 12.1 m,
  median 17 m).
- Length changed by +14 m (+0.016%).
- Elevations are byte-identical, and the file only differs in `lat`/`lon`,
  `<bounds>` and the track name.
- It added no self-crossings. The one at km 74.3 was already in the original.

## What did we land on, and why?

`tools/gpx-separate-legs.py`:
- **Checks** for overlaps: resamples every 5 m and ignores neighbours within
  300 m along the course.
- **Fixes** with the smallest uniform offset that clears a 12 m threshold
  (TrainingPeaks' ~10 m plus a margin).
- **Preserves the file:** only coordinate attributes are rewritten.
- **Reports** length change and local self-crossings, so a folded hairpin is
  visible.
- **Standard library only**, so any rider can run it.

`docs/custom-route-overlap.md` explains the bug and includes an AI prompt that
specifies the same algorithm, for people who'd rather not run the script.

It won because it's the smallest, most mechanical change that fixes every
opposite-direction overlap at once, with near-zero distance change and no
course-specific judgement. We'd revisit it if TPV's road-snapping pulls offset
legs back together on a real ride, or if same-direction repeats (laps) turn out
to trigger the bug too. A sideways offset can't separate those.

## What does this cost us?

- **Unproven in game:** the fix hasn't been ridden in TPV yet. TPV smooths and
  snaps uploaded routes, and might partly undo a 6 m shift. Re-upload and ride
  the Malaga course to confirm.
- **Loop ends drift apart:** the start and finish of a loop course end up about
  2D apart (12 m on Malaga). That's harmless for riding.
- **Tight inside hairpins:** offsetting towards the inside of a very tight
  hairpin can fold the line. The script reports self-crossings, but doesn't
  prevent them.
- **Laps in the same direction** aren't handled. The doc points to manual
  editing.
