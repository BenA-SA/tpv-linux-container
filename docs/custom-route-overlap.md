# Custom GPX routes: overlapping legs render a road at head height

This affects **TrainingPeaks Virtual itself**, on Windows as well as in this
container. It is not a Wine or graphics-driver bug, and anyone riding an
uploaded GPX route can hit it.

## Symptom

On a custom route, TPV intermittently draws a **second road at about head
height**, sometimes hiding the rider completely. It clears after riding on a
little, then comes back later (#4).

## Cause

TPV builds a separate road for each part of an uploaded route. When two parts
of the route run **within a few metres of each other**, their roads overlap and
render wrongly. The classic case is an out-and-back course, where the return leg
retraces the outbound one. The glitch comes and goes as you pass in and out of
those stretches.

- TrainingPeaks' own [GPX route guide](https://help.trainingpeaks.com/hc/en-us/articles/39687170693517-Getting-Started-with-GPX-Routes):
  *"When creating an out-and-back style route, the two directions of road
  should be kept about 10m apart rather than overlapping them on top of each
  other."*
- The [release notes](https://help.trainingpeaks.com/hc/en-us/articles/34924247758477-TrainingPeaks-Virtual-Release-Notes)
  keep fixing this area: "roads floating above the ground" (v0.4.13),
  out-and-back GPX routes (v0.4.34), "out-and-back GPX road graphics sometimes
  flickering" (v0.4.35).
- DC Rainmaker's [GPXplore review](https://www.dcrainmaker.com/2026/02/trainingpeaks-virtual-massively-gpxplore.html):
  overlap bugs *"any time the route doubles back on itself"*.

Course GPX files from race organisers almost always put both directions on the
road's centreline, so **most out-and-back race courses trigger this**. For
example, the IRONMAN 70.3 Malaga 2026 bike course (89.85 km) has about 42 km
retraced in the opposite direction, 1.5–9 m apart, with 95% of the course
closer than 10 m to another part of itself.

## Fix: shift the whole course a few metres to one side

Shift every point the same small distance sideways, to the right of the
direction of travel (or the left, in countries that ride on the left). Legs in
opposite directions then separate like the two sides of a road, while each leg
keeps its shape.

- **Distance:** barely changes, typically ± a few tens of metres on a whole
  course. Malaga: +14 m (+0.016%).
- **Elevation:** untouched. Only the `lat`/`lon` attributes change.
- **Size of the shift:** only as much as needed. Malaga needed 6 m to get every
  leg at least 12 m apart (TrainingPeaks' ~10 m plus a margin), giving a minimum
  gap of 12.1 m and a median of 17 m.

### With the script in this repo

`tools/gpx-separate-legs.py` needs only Python 3.9+ and no other packages. It
works on any machine, not just one running this container.

```bash
# report: which stretches overlap, and how closely
python3 tools/gpx-separate-legs.py course.gpx

# fix: choose the smallest whole-metre shift that clears 12 m, write a new file
python3 tools/gpx-separate-legs.py course.gpx -o course_TPV.gpx

# countries that ride on the left (UK, Ireland, Australia, Japan...)
python3 tools/gpx-separate-legs.py course.gpx -o course_TPV.gpx --side left
```

It prints the overlapping stretches (km ranges, closest gap, direction), the
shift it applied, the result re-checked, and the change in length. It also lists
**local self-crossings** (small loops such as roundabouts). Check that the fixed
file doesn't have more of these than the original, which would mean a tight
hairpin got folded. The exit code is `1` if overlaps remain.

It won't fix legs that repeat **in the same direction** (for example, several
laps of the same loop): a sideways shift moves both laps together. For those,
shift one lap by hand in a GPX editor such as [gpx.studio](https://gpx.studio),
or ride a single lap.

### With an AI assistant

Paste this into an AI assistant that can run code (ChatGPT with data analysis,
Claude, Gemini) and attach your GPX file:

````text
I'm riding a custom GPX route in TrainingPeaks Virtual. TPV mis-renders roads
where two parts of a route run within ~10 m of each other (e.g. the return leg
of an out-and-back), drawing a road at head height. Please fix my attached GPX
so no part of the course is within 12 m of another part, changing as little as
possible.

Do this with code, not by hand:

1. Parse every <trkpt>/<rtept> in order. Project to local metres
   (equirectangular around the mean latitude is fine). Compute cumulative
   distance.
2. Detect overlaps: resample the course every 5 m. For each sample, find the
   nearest other sample that is more than 300 m away *along the course* (so a
   bend or turnaround doesn't count as overlapping itself). List stretches
   where that distance is < 12 m, with km ranges, the closest gap, and whether
   the two legs travel in opposite or the same direction.
3. Fix with a uniform sideways offset. For each original point, take the
   direction of travel from the course position 25 m before to 25 m after it
   (smoothed, so hairpins don't flip it), and move the point D metres
   perpendicular to it, to the RIGHT of travel [change to LEFT if the course is
   in a country that rides on the left]. Try D = 1, 2, 3 … 15 m and use the
   smallest D for which the overlap check in step 2 finds nothing.
4. Keep everything else in the file byte-for-byte identical: elevations,
   times, extensions, names, attribute order, whitespace. Only replace the lat
   and lon attribute values (9 decimal places), and update <metadata><bounds>
   if present. Don't add, remove, resample, or reorder points.
5. Verify and report:
   - D used, and the overlap check before and after (after must be empty)
   - total length before and after; the change should be well under 0.1%
   - that the <ele> values are identical before and after
   - short-range self-crossings (segments crossing within 400 m along the
     course) before and after; the offset must not add any
   - if same-direction overlaps (repeated laps) remain, say so, because a
     sideways offset can't separate those
6. Give me the fixed file named <original name>_TPV.gpx.
````

The prompt describes the same method as the script, so you can check an AI's
output with `python3 tools/gpx-separate-legs.py <fixed file>` if you have the
repo.

## Re-uploading

TPV doesn't read GPX files from disk. Routes come from your TrainingPeaks
account:

1. In the TrainingPeaks **web app**, go to Calendar → **Routes Library**.
   Delete or rename the old version and upload the fixed file.
2. Restart TPV, or return to its route list. The route appears automatically.

## Caveats

- TrainingPeaks says uploaded routes are smoothed and snapped to known roads,
  so TPV may pull the legs closer again. Check on a ride that the glitch has
  gone.
- A few metres of sideways shift means the start and finish of a loop no longer
  meet exactly (Malaga: the ends end up ~12 m apart). That's harmless for riding.
- Offsetting to the inside of a very tight hairpin can fold the course. The
  script's self-crossing report catches this; use a smaller `--offset` or the
  other `--side` if it appears.
- Offsetting **tightens corners** on the side it shifts towards, and
  TrainingPeaks rejects an upload whose curve radius drops under 6 m. Run
  `tools/gpx-widen-curves.py` on the offset file afterwards — see
  [custom-route-tight-curves.md](custom-route-tight-curves.md).
