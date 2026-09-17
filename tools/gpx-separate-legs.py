#!/usr/bin/env python3
"""Find and fix overlapping legs in a GPX course before uploading it to TrainingPeaks Virtual.

TPV renders each leg of an out-and-back or overlapping custom route as its own
road. When two legs run within a few metres of each other, it can draw one of
them floating at about head height and hide the rider (issue #4).
TrainingPeaks' own GPX guide says the two directions should be kept about 10 m
apart.

The fix shifts every point sideways by the same small distance to one side of
the direction of travel, so opposing legs separate like carriageways.
Elevations, timestamps, extensions and everything else in the file are left
byte-for-byte alone; only ``lat``/``lon`` attributes (and ``<bounds>``) change,
and the course length changes by a few tens of metres at most.

Usage::

    tools/gpx-separate-legs.py course.gpx                  # report only
    tools/gpx-separate-legs.py course.gpx -o fixed.gpx     # fix, smallest offset that works
    tools/gpx-separate-legs.py course.gpx -o fixed.gpx --offset 6 --side left

Standard library only. Pick ``--side`` to match which side of the road the
course's country rides on (right for most of Europe, left for the UK, Ireland,
Australia, Japan...); legs travelling in opposite directions then each move to
their own side.
"""

import argparse
import math
import re
import sys
from dataclasses import dataclass

POINT_TAG = re.compile(r"<(trkpt|rtept)\b([^>]*)>")
LAT_ATTR = re.compile(r'\blat="([-+\d.eE]+)"')
LON_ATTR = re.compile(r'\blon="([-+\d.eE]+)"')
BOUNDS_TAG = re.compile(r"<bounds\b[^>]*/>")

SAMPLE_STEP_M = 5.0
MIN_ALONG_ROUTE_M = 300.0
HEADING_HALF_WINDOW_M = 25.0
KINK_WINDOW_M = 400.0
MAX_AUTO_OFFSET_M = 15


@dataclass
class Overlap:
    """A stretch of course lying within the threshold of another part of the course."""

    start_km: float
    end_km: float
    partner_start_km: float
    partner_end_km: float
    min_gap_m: float
    opposite_direction: bool


class Course:
    """A GPX course projected onto a local flat plane in metres."""

    def __init__(self, text: str):
        self.text = text
        self.latlon = [_point_latlon(m.group(2)) for m in POINT_TAG.finditer(text)]
        if len(self.latlon) < 2:
            raise SystemExit("no <trkpt>/<rtept> points found")
        self.origin = self.latlon[0]
        mean_lat = sum(lat for lat, _ in self.latlon) / len(self.latlon)
        self.m_per_deg_lon = 111_320 * math.cos(math.radians(mean_lat))
        self.m_per_deg_lat = 110_540
        self.xy = [self.to_xy(lat, lon) for lat, lon in self.latlon]
        self.cum = _cumulative(self.xy)

    @property
    def length_m(self) -> float:
        return self.cum[-1]

    def to_xy(self, lat: float, lon: float) -> tuple[float, float]:
        return (
            (lon - self.origin[1]) * self.m_per_deg_lon,
            (lat - self.origin[0]) * self.m_per_deg_lat,
        )

    def to_latlon(self, x: float, y: float) -> tuple[float, float]:
        return (self.origin[0] + y / self.m_per_deg_lat, self.origin[1] + x / self.m_per_deg_lon)

    def at(self, distance_m: float) -> tuple[float, float]:
        """Position along the course, clamped to its ends."""
        return _interpolate(self.xy, self.cum, distance_m)

    def heading(self, distance_m: float) -> tuple[float, float]:
        """Unit direction of travel, smoothed over a short window so hairpins don't flip it."""
        ax, ay = self.at(distance_m - HEADING_HALF_WINDOW_M)
        bx, by = self.at(distance_m + HEADING_HALF_WINDOW_M)
        norm = math.hypot(bx - ax, by - ay) or 1.0
        return ((bx - ax) / norm, (by - ay) / norm)

    def overlaps(self, threshold_m: float) -> list[Overlap]:
        """Stretches within ``threshold_m`` of a part of the course at least 300 m away along it."""
        samples = [i * SAMPLE_STEP_M for i in range(int(self.length_m // SAMPLE_STEP_M) + 1)]
        points = [self.at(s) for s in samples]
        nearest = _nearest_distant_neighbours(points, samples, threshold_m)
        return [self._describe(run, samples, nearest) for run in _runs(nearest)]

    def _describe(self, run, samples, nearest) -> Overlap:
        partners = [nearest[i][1] for i in run]
        facing = sum(
            _dot(self.heading(samples[i]), self.heading(samples[j])) for i, j in zip(run, partners)
        )
        return Overlap(
            start_km=samples[run[0]] / 1000,
            end_km=samples[run[-1]] / 1000,
            partner_start_km=min(samples[j] for j in partners) / 1000,
            partner_end_km=max(samples[j] for j in partners) / 1000,
            min_gap_m=min(nearest[i][0] for i in run),
            opposite_direction=facing / len(run) < -0.5,
        )

    def kinks_km(self) -> list[float]:
        """Distances where the course crosses itself within a short window.

        These are loops such as roundabouts, or kinks an offset has folded into a tight turn.
        """
        return [
            round(self.cum[i] / 1000, 2)
            for i in range(len(self.xy) - 1)
            for _ in range(self._crossings_ahead(i))
        ]

    def _crossings_ahead(self, i: int) -> int:
        """How many later segments within ``KINK_WINDOW_M`` cross segment ``i``."""
        count = 0
        j = i + 2
        while j < len(self.xy) - 1 and self.cum[j] - self.cum[i] < KINK_WINDOW_M:
            count += _segments_cross(self.xy[i], self.xy[i + 1], self.xy[j], self.xy[j + 1])
            j += 1
        return count

    def offset(self, metres: float, side: str) -> "Course":
        """A copy with every point shifted ``metres`` to the given side of travel."""
        sign = 1 if side == "right" else -1
        moved = []
        for (x, y), s in zip(self.xy, self.cum):
            hx, hy = self.heading(s)
            moved.append(self.to_latlon(x + sign * metres * hy, y - sign * metres * hx))
        return Course(_rewrite_points(self.text, moved))


def _point_latlon(attrs: str) -> tuple[float, float]:
    lat, lon = LAT_ATTR.search(attrs), LON_ATTR.search(attrs)
    if not lat or not lon:
        raise SystemExit(f"point without lat/lon: {attrs.strip()}")
    return float(lat.group(1)), float(lon.group(1))


def _cumulative(xy):
    cum = [0.0]
    for (ax, ay), (bx, by) in zip(xy, xy[1:]):
        cum.append(cum[-1] + math.hypot(bx - ax, by - ay))
    return cum


def _interpolate(xy, cum, distance_m):
    distance_m = min(max(distance_m, 0.0), cum[-1])
    lo, hi = 0, len(cum) - 1
    while hi - lo > 1:
        mid = (lo + hi) // 2
        if cum[mid] <= distance_m:
            lo = mid
        else:
            hi = mid
    span = cum[hi] - cum[lo]
    t = (distance_m - cum[lo]) / span if span else 0.0
    return (xy[lo][0] + t * (xy[hi][0] - xy[lo][0]), xy[lo][1] + t * (xy[hi][1] - xy[lo][1]))


def _nearest_distant_neighbours(points, samples, threshold_m):
    """For each sample, ``(gap, index)`` of the closest sample far enough along the course.

    ``None`` where nothing lies within ``threshold_m``.
    """
    cell = threshold_m
    grid: dict[tuple[int, int], list[int]] = {}
    for i, (x, y) in enumerate(points):
        grid.setdefault((int(x // cell), int(y // cell)), []).append(i)
    nearest = []
    for i, (x, y) in enumerate(points):
        best = None
        for j in _grid_neighbours(grid, int(x // cell), int(y // cell)):
            if abs(samples[j] - samples[i]) <= MIN_ALONG_ROUTE_M:
                continue
            gap = math.hypot(points[j][0] - x, points[j][1] - y)
            if gap < threshold_m and (best is None or gap < best[0]):
                best = (gap, j)
        nearest.append(best)
    return nearest


def _grid_neighbours(grid, cx, cy):
    """Indices of samples in the 3x3 block of grid cells around (cx, cy)."""
    for gx in (cx - 1, cx, cx + 1):
        for gy in (cy - 1, cy, cy + 1):
            yield from grid.get((gx, gy), ())


def _runs(nearest):
    """Group consecutive flagged samples, bridging gaps of up to three samples."""
    flagged = [i for i, hit in enumerate(nearest) if hit]
    runs = []
    for i in flagged:
        if runs and i - runs[-1][-1] <= 3:
            runs[-1].append(i)
        else:
            runs.append([i])
    return runs


def _dot(a, b):
    return a[0] * b[0] + a[1] * b[1]


def _segments_cross(a, b, c, d) -> bool:
    denom = (b[0] - a[0]) * (d[1] - c[1]) - (b[1] - a[1]) * (d[0] - c[0])
    if abs(denom) < 1e-12:
        return False
    t = ((c[0] - a[0]) * (d[1] - c[1]) - (c[1] - a[1]) * (d[0] - c[0])) / denom
    u = ((c[0] - a[0]) * (b[1] - a[1]) - (c[1] - a[1]) * (b[0] - a[0])) / denom
    return 0 < t < 1 and 0 < u < 1


def _rewrite_points(text: str, latlon: list[tuple[float, float]]) -> str:
    """Replace only the lat/lon attribute values of each point, in order, and refresh <bounds>."""
    replacements = iter(latlon)

    def rewrite(match):
        lat, lon = next(replacements)
        attrs = LAT_ATTR.sub(f'lat="{lat:.9f}"', match.group(2), count=1)
        attrs = LON_ATTR.sub(f'lon="{lon:.9f}"', attrs, count=1)
        return f"<{match.group(1)}{attrs}>"

    out = POINT_TAG.sub(rewrite, text)
    lats = [lat for lat, _ in latlon]
    lons = [lon for _, lon in latlon]
    bounds = (
        f'<bounds minlat="{min(lats):.9f}" minlon="{min(lons):.9f}"'
        f' maxlat="{max(lats):.9f}" maxlon="{max(lons):.9f}"/>'
    )
    return BOUNDS_TAG.sub(bounds, out, count=1)


def report(label: str, course: Course, threshold_m: float) -> list[Overlap]:
    overlaps = course.overlaps(threshold_m)
    first_legs = [o for o in overlaps if o.start_km < o.partner_start_km]
    covered = sum(o.end_km - o.start_km for o in first_legs)
    print(f"{label}: {course.length_m / 1000:.2f} km, {len(course.latlon)} points")
    print(
        f"  overlapping legs (< {threshold_m:g} m apart): {len(first_legs)} stretches,"
        f" ~{covered:.1f} km of course doubled up"
    )
    for o in first_legs:
        direction = "opposite" if o.opposite_direction else "same/crossing"
        print(
            f"    km {o.start_km:6.2f}-{o.end_km:6.2f}"
            f" vs km {o.partner_start_km:6.2f}-{o.partner_end_km:6.2f}"
            f"  closest {o.min_gap_m:4.1f} m  ({direction} direction)"
        )
    kinks = course.kinks_km()
    print(f"  local self-crossings (loops/roundabouts/kinks): {kinks or 'none'}")
    return overlaps


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("gpx")
    parser.add_argument("-o", "--output", help="write the fixed course here (omit to only report)")
    parser.add_argument(
        "--threshold",
        type=float,
        default=12.0,
        help="minimum gap between legs, metres (default 12: TrainingPeaks' ~10 m plus a margin)",
    )
    parser.add_argument(
        "--offset",
        type=float,
        help="sideways shift in metres (default: smallest whole metre that clears the threshold)",
    )
    parser.add_argument(
        "--side",
        choices=("right", "left"),
        default="right",
        help="side of travel to shift towards (default right)",
    )
    args = parser.parse_args()

    with open(args.gpx, encoding="utf-8") as fh:
        original = Course(fh.read())
    overlaps = report("original", original, args.threshold)
    if not args.output:
        return 1 if overlaps else 0
    if not overlaps and args.offset is None:
        print("nothing to fix")
        return 0

    candidates = [args.offset] if args.offset is not None else range(1, MAX_AUTO_OFFSET_M + 1)
    for metres in candidates:
        fixed = original.offset(metres, args.side)
        if not fixed.overlaps(args.threshold) or args.offset is not None:
            break
    else:
        print(
            f"no offset up to {MAX_AUTO_OFFSET_M} m clears {args.threshold:g} m;"
            " the overlapping legs may run in the same direction",
            file=sys.stderr,
        )
        return 2

    print(f"\napplied {metres:g} m offset to the {args.side}")
    remaining = report("fixed", fixed, args.threshold)
    change = fixed.length_m - original.length_m
    print(f"  length change: {change:+.0f} m ({100 * change / original.length_m:+.3f}%)")
    with open(args.output, "w", encoding="utf-8") as fh:
        fh.write(fixed.text)
    print(f"wrote {args.output}")
    return 1 if remaining else 0


if __name__ == "__main__":
    sys.exit(main())
