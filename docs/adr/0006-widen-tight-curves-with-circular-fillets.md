# 0006. Widen over-tight GPX curves with circular fillets

- **Status:** Accepted
- **Date:** 2026-09-17
- **Deciders:** Ben Atkinson
- **Feature / area:** custom-route-preparation
- **Builds on:** ADR-0002
- **Supersedes / Superseded by:** none

## What problem were we trying to solve?

Uploading the Malaga course fixed by ADR-0002 to TrainingPeaks was **rejected**:

> The curve radius of points near ~60135.39 meters into the route (lat: 36.735,
> lon: -4.108, elevation: 3.500) is too tight. The curve should be widened to
> ensure no points create a curve radius less than 6 meters.

This is a different failure from ADR-0002. That one was TPV mis-rendering an
accepted route; this one stops the route being accepted at all, so it blocks the
ride earlier.

The named coordinate is point 1528, a ~96 degree junction turn described by two
points 4.5 m and 5.1 m apart. The circle through it and its neighbours has a
radius of 4.69 m. In the file *before* ADR-0002's offset the same corner measured
7.41 m, so the offset pushed it under the limit: shifting sideways moves the
inside of a bend towards its own centre of curvature. Four more corners were at
or near the threshold, two of them at 6.14 m and 6.35 m, which would have failed
the next upload attempt.

Constraints:
- The course has to stay a faithful copy of the race: same distance, same
  elevation profile, same roads.
- It has to compose with the sideways offset, not undo it.
- Other riders should be able to apply it, container or no container.

## What did we try?

### Attempt 1 — blame the offset and reduce it ❌ rejected

The offset made this corner worse, so a smaller one is tempting. But the corner
was already at 7.41 m before any offset, and a smaller offset reopens the
overlap bug ADR-0002 exists to fix. The two constraints pull in opposite
directions, so one offset value can't satisfy both.

### Attempt 2 — smooth the whole course ❌ rejected

A Laplacian or Chaikin pass over every point raises the tightest radii. It also
moves the entire course, blunts every real corner, and changes the distance —
against the "faithful copy" constraint. It fixes a five-point problem by
rewriting 2108 points.

### Attempt 3 — push the tight vertex outwards ❌ rejected

Moving just the flagged point away from the turn's centre raises its
circumradius. But for a triple the circumradius is minimised when the apex
height equals half the neighbour spacing, so it can only be raised so far before
the neighbouring points become the tightest ones instead. It moves the problem
along rather than solving it.

### Attempt 4 — circular fillet at each tight corner ✅ chosen

Standard road-design geometry. Take the straight feeding the corner and the one
leaving it, intersect them for the apex, and lay an arc of radius R tangent to
both, tangent length R·tan(Δ/2) for a deflection Δ. Sample it every 10 degrees:
every consecutive triple then sits on a circle of exactly R, which is precisely
the quantity TrainingPeaks measures. On Malaga, R = 9 m:

| Distance into route | Radius before | After |
|---|---|---|
| 45 035 m | 3.25 m | ≥ 8.25 m |
| 45 037 m | 7.71 m | ≥ 8.25 m |
| 57 320 m | 6.35 m | ≥ 8.25 m |
| 57 322 m | 6.14 m | ≥ 8.25 m |
| 60 077 m | 4.69 m | ≥ 8.25 m |

Length changed by −21 m (−0.023%), no point moved more than 3.44 m, the leg
separation from ADR-0002 was untouched (still no stretch within 12 m of
another), and the one self-crossing at km 74.3 was already there.

## What did we land on, and why?

`tools/gpx-widen-curves.py`:
- **Checks** the circumradius at every point, the same measure TrainingPeaks
  applies, and reports each offender by distance into the route so its output
  lines up with the upload error message.
- **Fixes** by replacing each corner — grown outwards to cover the whole bend,
  not just the flagged point — with a tangent arc, then sweeping again until
  nothing is tight, because widening one corner can leave its new ends curving.
- **Backs off** to a smaller radius, and to wider straights to hang the arc
  between, rather than leaving a corner untouched.
- **Interpolates elevation** across a replaced corner, since unlike the offset
  tool this one adds and removes points.
- **Names what it can't fix.** A hairpin between close legs has no room for an
  arc of any useful radius; the script says so and points at
  `gpx-separate-legs.py --offset`, which opens the hairpin by separating the
  legs further.
- **Standard library only**, like its sibling.

The two tools have a required order — **separate legs, then widen curves** —
because offsetting tightens corners. `docs/custom-route-tight-curves.md` says so,
and carries an AI prompt describing the same algorithm for people who'd rather
not run the script.

It won because it changes only the five corners that fail the check, by a few
metres each, and it targets the exact quantity TrainingPeaks measures instead of
approximating it. We'd revisit it if TrainingPeaks changes the 6 m threshold, or
if its own smoothing re-tightens the widened corners on upload.

## What does this cost us?

- **Unproven against the uploader:** the widened file clears the check as we
  compute it, but has not been through TrainingPeaks' own validator yet.
  Confirm on the next upload.
- **Distances don't match exactly.** TrainingPeaks reported the failure at
  60 135 m where we measure that corner at 60 077 m — probably a 3D distance
  against our 2D one. The coordinates match, so the corner is identified by
  position, not distance.
- **Corners get cut.** An arc sits inside the original corner, by up to 3.44 m
  on Malaga. On a real road that is within the carriageway; on a hairpin taken
  wide it would shorten the course slightly.
- **Points are added and removed**, so timestamps and extensions inside a
  replaced corner are lost. Race course files don't normally carry them.
- **Hairpins need the other tool first**, and a course whose legs can't be
  separated (same-direction laps, per ADR-0002) may have a hairpin that neither
  tool can fix.
