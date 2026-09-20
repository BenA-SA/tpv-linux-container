#!/usr/bin/env python3
"""Widen over-tight corners in a GPX course so TrainingPeaks Virtual will accept it.

TPV rejects an upload whose points describe a curve radius below 6 m, naming the
distance into the route and the offending coordinate. The cause is usually a
junction or roundabout that the source data describes with two or three closely
spaced points, turning 90 degrees or more in a few metres.

The fix replaces each tight corner with a circular fillet of the target radius,
tangent to the straight segments either side, sampled densely enough that every
consecutive triple of points sits on that circle. Points outside the corners are
left exactly where they were; elevations across a replaced corner are
interpolated from its two ends.

Usage::

    tools/gpx-widen-curves.py course.gpx                   # report only
    tools/gpx-widen-curves.py course.gpx -o fixed.gpx      # widen to 9 m
    tools/gpx-widen-curves.py course.gpx -o fixed.gpx --radius 12
"""

import argparse
import math
import re
import sys
from dataclasses import dataclass

POINT = re.compile(
    r'<(trkpt|rtept)\b[^>]*\blat="([-+\d.eE]+)"[^>]*\blon="([-+\d.eE]+)"[^>]*>'
    r"(?:\s*<ele>([-+\d.eE]+)</ele>)?.*?</(?:trkpt|rtept)>",
    re.DOTALL,
)
BOUNDS_TAG = re.compile(r"<bounds\b[^>]*/>")

TPV_MIN_RADIUS_M = 6.0
CORNER_CONTEXT_RADIUS_M = 40.0
ARC_STEP_DEG = 10.0
MAX_PASSES = 6
RADIUS_BACKOFF_M = 0.5
MIN_DEFLECTION_DEG = 5.0
HAIRPIN_DEG = 150.0


@dataclass
class Point:
    """One course point: position in local metres, with its elevation carried along."""

    x: float
    y: float
    ele: float | None


class Course:
    """A GPX course projected onto a local flat plane in metres."""

    def __init__(self, text: str):
        self.text = text
        raw = POINT.findall(text)
        if len(raw) < 3:
            raise SystemExit("no <trkpt>/<rtept> points found")
        self.tag = raw[0][0]
        latlon = [(float(lat), float(lon)) for _, lat, lon, _ in raw]
        self.origin = latlon[0]
        mean_lat = sum(lat for lat, _ in latlon) / len(latlon)
        self.m_per_deg_lon = 111_320 * math.cos(math.radians(mean_lat))
        self.m_per_deg_lat = 110_540
        self.points = [
            Point(*self._to_xy(lat, lon), float(ele) if ele else None)
            for (lat, lon), (_, _, _, ele) in zip(latlon, raw)
        ]

    def _to_xy(self, lat: float, lon: float) -> tuple[float, float]:
        return (
            (lon - self.origin[1]) * self.m_per_deg_lon,
            (lat - self.origin[0]) * self.m_per_deg_lat,
        )

    def to_latlon(self, point: Point) -> tuple[float, float]:
        return (
            self.origin[0] + point.y / self.m_per_deg_lat,
            self.origin[1] + point.x / self.m_per_deg_lon,
        )

    @property
    def length_m(self) -> float:
        return sum(_distance(a, b) for a, b in zip(self.points, self.points[1:]))

    def radii(self) -> list[float]:
        """Circumradius of each point and its two neighbours, as TPV measures curvature."""
        inf = float("inf")
        return (
            [inf]
            + [_circumradius(*self.points[i - 1 : i + 2]) for i in range(1, len(self.points) - 1)]
            + [inf]
        )

    def tight_indices(self, minimum_m: float) -> list[int]:
        return [i for i, r in enumerate(self.radii()) if r < minimum_m]

    def distance_to(self, index: int) -> float:
        return sum(
            _distance(a, b) for a, b in zip(self.points[: index + 1], self.points[1 : index + 1])
        )


def _distance(a: Point, b: Point) -> float:
    return math.hypot(b.x - a.x, b.y - a.y)


def _circumradius(a: Point, b: Point, c: Point) -> float:
    """Radius of the circle through three points; infinite when they are collinear."""
    sides = _distance(a, b) * _distance(b, c) * _distance(a, c)
    twice_area = abs((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x))
    if twice_area < 1e-9:
        return float("inf")
    return sides / (2 * twice_area)


def _unit(from_point: Point, to_point: Point) -> tuple[float, float]:
    dx, dy = to_point.x - from_point.x, to_point.y - from_point.y
    norm = math.hypot(dx, dy) or 1.0
    return (dx / norm, dy / norm)


def _corner_groups(radii: list[float], minimum_m: float) -> list[tuple[int, int]]:
    """Index ranges to replace: each tight point, widened to the whole bend it sits in.

    A bend is described by more points than the one TPV flags, so the group grows
    outwards over neighbours that are still curving hard. Overlapping groups merge.
    """
    groups: list[tuple[int, int]] = []
    for i, radius in enumerate(radii):
        if radius >= minimum_m:
            continue
        start, end = _grow(radii, i)
        if groups and start <= groups[-1][1] + 1:
            groups[-1] = (groups[-1][0], max(groups[-1][1], end))
            continue
        groups.append((start, end))
    return groups


def _grow(radii: list[float], index: int) -> tuple[int, int]:
    """Extend outwards from a tight point while the neighbours are still part of the bend."""
    start = index
    while start > 1 and radii[start - 1] < CORNER_CONTEXT_RADIUS_M:
        start -= 1
    end = index
    while end < len(radii) - 2 and radii[end + 1] < CORNER_CONTEXT_RADIUS_M:
        end += 1
    return start, end


@dataclass
class Arc:
    """A fitted arc, with the indices of the two points it hangs between.

    ``before``/``after`` are what the caller must splice against: the arc starts
    on the straight running into ``points[before]`` and ends on the one leaving
    ``points[after]``. They are not always the corner's immediate neighbours,
    because a tight corner is hung between wider pairs (see
    ``Fillet._tangent_candidates``).
    """

    points: list[Point]
    before: int
    after: int


class Fillet:
    """A circular arc of the target radius replacing one corner of the course."""

    def __init__(self, points: list[Point], start: int, end: int, radius_m: float, floor_m: float):
        self.points = points
        self.start, self.end = start, end
        self.radius_m, self.floor_m = radius_m, floor_m

    def arc(self) -> Arc | None:
        """The widest arc that fits this corner, or ``None`` when even the floor radius won't.

        A corner between two short segments has no room for the target radius, so
        the search widens the straights it hangs the arc between, then settles for
        a smaller radius rather than leaving the corner untouched.
        """
        for radius in self._radii():
            for before, after in self._tangent_candidates():
                fitted = self._arc_between(before, after, radius)
                if fitted is not None:
                    return Arc(fitted, before, after)
        return None

    def _radii(self):
        """The target radius, then progressively smaller ones down to the floor."""
        radius = self.radius_m
        while radius >= self.floor_m:
            yield radius
            radius -= RADIUS_BACKOFF_M

    def _tangent_candidates(self):
        """Successively wider pairs of straight segments to hang the arc between."""
        for back in range(1, 4):
            before, after = self.start - back, self.end + back
            if before < 1 or after > len(self.points) - 2:
                return
            yield before, after

    def _arc_between(self, before: int, after: int, radius: float) -> list[Point] | None:
        entry, exit_ = self.points[before], self.points[after]
        heading_in = _unit(self.points[before - 1], entry)
        heading_out = _unit(exit_, self.points[after + 1])
        deflection = _signed_angle(heading_in, heading_out)
        if abs(math.degrees(deflection)) < MIN_DEFLECTION_DEG:
            return None
        apex = _intersect(entry, heading_in, exit_, heading_out)
        if apex is None:
            return None
        tangent_m = radius * abs(math.tan(deflection / 2))
        if not self._tangents_fit(tangent_m, apex, before, after, heading_in, heading_out):
            return None
        return self._sample(
            apex, tangent_m, deflection, heading_in, heading_out, before, after, radius
        )

    def _tangents_fit(self, tangent_m, apex, before, after, heading_in, heading_out) -> bool:
        """Whether both tangent points land on the straights, not beyond the points feeding them."""
        room_in = (apex.x - self.points[before - 1].x) * heading_in[0] + (
            apex.y - self.points[before - 1].y
        ) * heading_in[1]
        room_out = (self.points[after + 1].x - apex.x) * heading_out[0] + (
            self.points[after + 1].y - apex.y
        ) * heading_out[1]
        return tangent_m < room_in and tangent_m < room_out

    def _sample(self, apex, tangent_m, deflection, heading_in, heading_out, before, after, radius):
        start = Point(apex.x - tangent_m * heading_in[0], apex.y - tangent_m * heading_in[1], None)
        finish = Point(
            apex.x + tangent_m * heading_out[0], apex.y + tangent_m * heading_out[1], None
        )
        turn = 1 if deflection > 0 else -1
        centre = Point(
            start.x - turn * radius * heading_in[1],
            start.y + turn * radius * heading_in[0],
            None,
        )
        steps = max(2, math.ceil(abs(math.degrees(deflection)) / ARC_STEP_DEG))
        first = math.atan2(start.y - centre.y, start.x - centre.x)
        arc = [
            Point(
                centre.x + radius * math.cos(first + deflection * step / steps),
                centre.y + radius * math.sin(first + deflection * step / steps),
                None,
            )
            for step in range(steps + 1)
        ]
        arc[0], arc[-1] = start, finish
        return _with_elevations(arc, self.points[before - 1].ele, self.points[after + 1].ele)


def _with_elevations(
    arc: list[Point], start_ele: float | None, end_ele: float | None
) -> list[Point]:
    """Spread the elevation change across the corner in proportion to distance along it."""
    if start_ele is None or end_ele is None:
        return arc
    spans = [0.0]
    for a, b in zip(arc, arc[1:]):
        spans.append(spans[-1] + _distance(a, b))
    total = spans[-1] or 1.0
    for point, along in zip(arc, spans):
        point.ele = start_ele + (end_ele - start_ele) * along / total
    return arc


def _signed_angle(a: tuple[float, float], b: tuple[float, float]) -> float:
    return math.atan2(a[0] * b[1] - a[1] * b[0], a[0] * b[0] + a[1] * b[1])


def _intersect(
    a: Point, da: tuple[float, float], b: Point, db: tuple[float, float]
) -> Point | None:
    """Where the two straights would meet if extended; ``None`` when they are parallel."""
    denom = da[0] * db[1] - da[1] * db[0]
    if abs(denom) < 1e-9:
        return None
    t = ((b.x - a.x) * db[1] - (b.y - a.y) * db[0]) / denom
    return Point(a.x + t * da[0], a.y + t * da[1], None)


def widen(
    course: Course, radius_m: float, minimum_m: float
) -> tuple[list[Point], list[str], int]:
    """Rebuild the course with each corner tighter than ``minimum_m`` replaced by an arc.

    Widening one corner can leave its new end points curving tighter than the
    threshold, so the sweep repeats until nothing is left to fix. Corners that no
    arc fits are reported once and then left alone, rather than retried forever.
    """
    points, notes, widened = course.points, [], 0
    stuck: set[tuple[float, float]] = set()
    for _ in range(MAX_PASSES):
        radii = Course.radii(_as_course(course, points))
        groups = [g for g in _corner_groups(radii, minimum_m) if _key(points, g) not in stuck]
        if not groups:
            break
        points, failures = _apply_groups(points, groups, radius_m, minimum_m, stuck)
        widened += len(groups) - len(failures)
        notes.extend(failures)
    return points, notes, widened


def _key(points: list[Point], group: tuple[int, int]) -> tuple[float, float]:
    """Identifies a corner by position, so it survives the renumbering a pass causes."""
    return (round(points[group[0]].x, 2), round(points[group[0]].y, 2))


def _as_course(course: Course, points: list[Point]) -> Course:
    """A shallow stand-in carrying replacement points, for reusing the geometry helpers."""
    clone = object.__new__(Course)
    clone.__dict__ = dict(course.__dict__)
    clone.points = points
    return clone


def _apply_groups(points, groups, radius_m, minimum_m, stuck) -> tuple[list[Point], list[str]]:
    """Replace each corner with its arc, in order, keeping everything between them."""
    rebuilt: list[Point] = []
    cursor = 0
    failures = []
    for start, end in groups:
        fitted = Fillet(points, start, end, radius_m, minimum_m).arc()
        if fitted is None:
            stuck.add(_key(points, (start, end)))
            failures.append(_why_stuck(points, start, end, minimum_m))
            continue
        rebuilt.extend(points[cursor : max(cursor, fitted.before)])
        rebuilt.extend(fitted.points)
        cursor = max(cursor, fitted.after + 1)
    rebuilt.extend(points[cursor:])
    return rebuilt, failures


def _why_stuck(points: list[Point], start: int, end: int, minimum_m: float) -> str:
    """Explain a corner no arc fits, naming a hairpin because that needs the other tool."""
    turn = abs(
        math.degrees(
            _signed_angle(
                _unit(points[start - 1], points[start]), _unit(points[end], points[end + 1])
            )
        )
    )
    where = f"point {start} turns {turn:.0f} deg"
    if start - 1 < 1 or end + 1 > len(points) - 2:
        return (
            f"the corner where {where} sits at the route boundary: widening hangs an"
            " arc between the straights either side, and there is no room for one"
            " here, so extend the route past the corner or redraw it by hand"
        )
    if turn < HAIRPIN_DEG:
        return f"no arc of {minimum_m:g} m or wider fits the corner where {where}"
    return (
        f"no arc of {minimum_m:g} m or wider fits the hairpin where {where}:"
        " its legs are too close together, so separate them further"
        " with gpx-separate-legs.py --offset before widening"
    )


def _render(course: Course, points: list[Point]) -> str:
    """The original file with its point list replaced and <bounds> refreshed."""
    latlon = [course.to_latlon(p) for p in points]
    tag = course.tag
    body = "\n".join(
        f'    <{tag} lat="{lat:.9f}" lon="{lon:.9f}">\n        <ele>{p.ele:.1f}</ele>\n    </{tag}>'
        if p.ele is not None
        else f'    <{tag} lat="{lat:.9f}" lon="{lon:.9f}"></{tag}>'
        for (lat, lon), p in zip(latlon, points)
    )
    head, _, rest = course.text.partition(f"<{tag}")
    _, _, tail = rest.rpartition(f"</{tag}>")
    out = f"{head}{body.lstrip()}{tail}"
    lats = [lat for lat, _ in latlon]
    lons = [lon for _, lon in latlon]
    bounds = (
        f'<bounds minlat="{min(lats):.9f}" minlon="{min(lons):.9f}"'
        f' maxlat="{max(lats):.9f}" maxlon="{max(lons):.9f}"/>'
    )
    return BOUNDS_TAG.sub(bounds, out, count=1)


def report(label: str, course: Course, minimum_m: float) -> list[int]:
    radii = course.radii()
    tight = course.tight_indices(minimum_m)
    curved = [r for r in radii if r != float("inf")]
    print(f"{label}: {course.length_m / 1000:.2f} km, {len(course.points)} points")
    if curved:
        print(f"  tightest curve radius: {min(curved):.2f} m")
    else:
        print("  tightest curve radius: n/a (no curvature; every point is collinear)")
    print(f"  points under {minimum_m:g} m: {len(tight)}")
    for i in tight:
        lat, lon = course.to_latlon(course.points[i])
        print(
            f"    {course.distance_to(i):9.1f} m in:"
            f" r={radii[i]:6.2f} m (lat {lat:.5f}, lon {lon:.5f})"
        )
    return tight


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("gpx")
    parser.add_argument(
        "-o", "--output", help="write the widened course here (omit to only report)"
    )
    parser.add_argument(
        "--radius",
        type=float,
        default=9.0,
        help="radius of the replacement arcs, metres (default 9)",
    )
    parser.add_argument(
        "--minimum",
        type=float,
        default=8.0,
        help="widen anything tighter than this, metres"
        f" (default 8; TPV rejects under {TPV_MIN_RADIUS_M:g})",
    )
    args = parser.parse_args()

    with open(args.gpx, encoding="utf-8") as fh:
        original = Course(fh.read())
    tight = report("original", original, args.minimum)
    if not args.output:
        return 1 if tight else 0
    if not tight:
        print("nothing to fix")
        return 0

    points, notes, widened = widen(original, args.radius, args.minimum)
    fixed = Course(_render(original, points))
    print(f"\nwidened {widened} corner(s) to {args.radius:g} m")
    for note in notes:
        print(f"  ! {note}", file=sys.stderr)
    remaining = report("fixed", fixed, args.minimum)
    change = fixed.length_m - original.length_m
    print(f"  length change: {change:+.0f} m ({100 * change / original.length_m:+.3f}%)")
    with open(args.output, "w", encoding="utf-8") as fh:
        fh.write(fixed.text)
    print(f"wrote {args.output}")
    return 1 if remaining or notes else 0


if __name__ == "__main__":
    sys.exit(main())
