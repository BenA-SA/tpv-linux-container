# Custom GPX routes: TrainingPeaks rejects an upload for a tight curve radius

This is a **TrainingPeaks upload check**, not a container bug or a TPV rendering
fault. It stops the route reaching your Routes Library at all, so it blocks the
ride before TPV is involved.

## Symptom

Uploading a GPX route to TrainingPeaks fails with a message naming a distance
and a coordinate:

> The curve radius of points near ~60135.39 meters into the route (lat: 36.735,
> lon: -4.108, elevation: 3.500) is too tight. The curve should be widened to
> ensure no points create a curve radius less than 6 meters.

Fix that corner and the upload usually fails again a few metres later, at the
next tightest one.

## Cause

TrainingPeaks measures the radius of the circle through each point and its two
neighbours, and rejects anything under **6 m**. A junction or roundabout that the
source data describes with two or three points a few metres apart turns 90
degrees or more in that short distance, so the circle through them is tiny — even
though the real road is perfectly rideable.

On the IRONMAN 70.3 Malaga 2026 bike course the raw file had corners at 7.4 m
and 2.7 m, close enough to the limit that they were a problem waiting to happen.

**A sideways offset makes this worse.** Shifting a course to separate its legs
(see [custom-route-overlap.md](custom-route-overlap.md)) moves the inside of a
corner towards its own centre of curvature, tightening it. On Malaga, a 6 m
offset took one corner from 7.41 m to 4.69 m — over the line TrainingPeaks
accepts. Expect to run both fixes, **separate the legs first, then widen the
curves**, because widening is the one that has to have the last word.

## Fix: replace each tight corner with a wider arc

Swap the corner for a circular arc of a safe radius, tangent to the straights
either side, with enough points along it that every consecutive triple sits on
that circle. The route keeps its shape; only the corner itself moves, by a few
metres.

### With the script in this repo

`tools/gpx-widen-curves.py` needs only Python 3.10+ and no other packages.

```bash
# report: every corner tighter than 8 m, and where it is
python3 tools/gpx-widen-curves.py course.gpx

# fix: widen them to 9 m arcs, write a new file
python3 tools/gpx-widen-curves.py course.gpx -o course_TPV.gpx

# a bigger margin, if TrainingPeaks still complains
python3 tools/gpx-widen-curves.py course.gpx -o course_TPV.gpx --radius 12 --minimum 10
```

The defaults widen anything under 8 m into a 9 m arc, keeping clear of the 6 m
limit without rounding off corners the game renders fine. It reports the tightest
radius before and after, the distance into the route of each offending corner (so
you can match it against TrainingPeaks' message), the change in length, and exits
`1` if anything is still tight.

On Malaga, after the 6 m leg offset:

| Distance into route | Radius before | After |
|---|---|---|
| 45 035 m | 3.25 m | ≥ 8.25 m |
| 45 037 m | 7.71 m | ≥ 8.25 m |
| 57 320 m | 6.35 m | ≥ 8.25 m |
| 57 322 m | 6.14 m | ≥ 8.25 m |
| 60 077 m | 4.69 m | ≥ 8.25 m |

Length changed by −21 m (−0.023%) over 89.85 km, no point moved more than
3.44 m, and the leg separation from the earlier offset was untouched (still no
stretch within 12 m of another).

### Hairpins it can't fix

A U-turn at the end of an out-and-back is not a corner but two legs joined by a
semicircle, and its radius can only be half the gap between those legs. When the
legs are 10 m apart, no 8 m arc exists. The script says so and names the turn:

```
! no arc of 8 m or wider fits the hairpin where point 1046 turns 161 deg: its
  legs are too close together, so separate them further with
  gpx-separate-legs.py --offset before widening
```

Run `gpx-separate-legs.py` with a larger `--offset` and the hairpin opens up
enough for an arc to fit. This is the other reason to separate legs first.

### With an AI assistant

Paste this into an AI assistant that can run code, and attach your GPX file:

````text
TrainingPeaks rejects my GPX route: "The curve radius of points near ~X meters
into the route is too tight... no points create a curve radius less than 6
meters." Please widen every over-tight corner, changing as little else as
possible.

Do this with code, not by hand:

1. Parse every <trkpt>/<rtept> in order, keeping its <ele>. Project to local
   metres (equirectangular around the mean latitude is fine).
2. For each point, compute the radius of the circle through it and its two
   neighbours (circumradius = abc / 4 * area; infinite if collinear). List every
   point under 8 m with its distance into the route and its coordinates.
3. Group each tight point with its neighbours that are also curving hard (under
   40 m), so a bend described by several points is treated as one corner.
4. Replace each group with a circular fillet: take the straight segment feeding
   the corner and the one leaving it, intersect them to find the apex, and lay a
   9 m arc tangent to both, sampled every 10 degrees. Drop the original points
   inside the fillet. If the tangent points don't fit on those straights, hang
   the arc between the next segments out, then try smaller radii down to 8 m.
5. Interpolate <ele> across each replaced corner from its two ends. Leave every
   other point, and the rest of the file, exactly as it was.
6. Repeat steps 2-5 until no point is under 8 m, then verify and report:
   - tightest radius before and after (after must be over 6 m, ideally over 8 m)
   - total length before and after; the change should be well under 0.1%
   - the largest distance any point moved; it should be a few metres at most
   - any corner you could not widen, and why
7. Give me the fixed file named <original name>_TPV.gpx.
````

## Caveats

- **Run it after the leg offset**, not before. Offsetting tightens corners, so
  widening has to be the last step.
- **The corner moves.** The arc cuts inside the original corner by a few metres.
  That is what widening means, and TrainingPeaks smooths and snaps uploads to
  known roads anyway.
- **Elevation across a widened corner is interpolated** from its two ends, so a
  corner that straddles a sharp change in gradient loses a little detail over
  those few metres.
- **Points are added and removed**, unlike `gpx-separate-legs.py`, which only
  edits coordinates. Timestamps and extensions inside a replaced corner do not
  survive; course files don't normally carry them.
