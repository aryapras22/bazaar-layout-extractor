"""Shared helpers for the metre-based truth files (data/planN/truth.json).

Each plan has its own builder (make_metre_truth_planN.py) that lists what is drawn, in layout pixels, and
hands it to this module. This module converts pixels to metres, snaps booth edges, checks the result
(Pass 7 of the tracing instructions) and writes the JSON with the keys in the required order.

Coordinates: metres, origin at the top-left of the traced area, x right, y down. The hall's top-left
corner sits at (1, 1), so the world box is hall plus lobby plus 1 m on every side.
"""
import json
import math

import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage as ndi

KEY_ORDER = ["meta", "hall", "lobby", "wall", "doors", "gates", "exitPt", "outerDoors", "booths", "tables",
             "stage", "kids", "pantia", "lobbyBlock", "columns", "pilasters", "fixtures", "arrows", "closed"]


class Frame:
    """Pixel to metre conversion: metres = (pixel - origin) / scale + 1."""

    def __init__(self, scale, ox, oy):
        self.scale, self.ox, self.oy = scale, ox, oy

    def x(self, px):
        return (px - self.ox) / self.scale + 1

    def y(self, py):
        return (py - self.oy) / self.scale + 1

    def length(self, px):
        return px / self.scale

    def pt(self, px, py):
        return [r2(self.x(px)), r2(self.y(py))]

    def rect(self, x0, y0, x1, y1):
        return {"x0": r2(self.x(x0)), "x1": r2(self.x(x1)), "y0": r2(self.y(y0)), "y1": r2(self.y(y1))}


def r2(v):
    return round(float(v) + 0.0, 2)


def rect_m(x0, y0, x1, y1):
    return {"x0": r2(x0), "x1": r2(x1), "y0": r2(y0), "y1": r2(y1)}


def centre_size(rect):
    return {"cx": r2((rect["x0"] + rect["x1"]) / 2), "cy": r2((rect["y0"] + rect["y1"]) / 2),
            "w": r2(rect["x1"] - rect["x0"]), "h": r2(rect["y1"] - rect["y0"])}


def cluster(values, tol):
    """Map every value to the mean of its cluster; neighbours closer than tol join one cluster."""
    order = sorted(set(values))
    mapping, group = {}, []
    for v in order + [None]:
        if v is not None and group and v - group[-1] <= tol:
            group.append(v)
            continue
        if group:
            mean = sum(group) / len(group)
            for g in group:
                mapping[g] = mean
        group = [v] if v is not None else []
    return mapping


def snap_rects(rects, tol=0.12):
    """Snap the edges of {x0,x1,y0,y1} rectangles (metres) so neighbours touch and rows align."""
    if not rects:
        return rects
    mx = cluster([r["x0"] for r in rects] + [r["x1"] for r in rects], tol)
    my = cluster([r["y0"] for r in rects] + [r["y1"] for r in rects], tol)
    return [{"x0": mx[r["x0"]], "x1": mx[r["x1"]], "y0": my[r["y0"]], "y1": my[r["y1"]]} for r in rects]


def resolve_overlaps(rects, limit=0.1):
    """Remove overlaps deeper than `limit` on both axes, in place.

    Two booths that overlap in a square corner (an L cut by a diagonal, the vertical arm taller than wide)
    give the corner to the horizontal arm. Any other overlap is split evenly along its thinner axis.
    """
    for i in range(len(rects)):
        for j in range(i + 1, len(rects)):
            a, b = rects[i], rects[j]
            ox = min(a["x1"], b["x1"]) - max(a["x0"], b["x0"])
            oy = min(a["y1"], b["y1"]) - max(a["y0"], b["y0"])
            if ox <= limit or oy <= limit:
                continue
            a_vertical = (a["y1"] - a["y0"]) > (a["x1"] - a["x0"])
            b_vertical = (b["y1"] - b["y0"]) > (b["x1"] - b["x0"])
            if abs(ox - oy) < 0.2 and a_vertical != b_vertical:
                vertical, other = (a, b) if a_vertical else (b, a)
                if (vertical["y0"] + vertical["y1"]) > (other["y0"] + other["y1"]):
                    vertical["y0"] = other["y1"]
                else:
                    vertical["y1"] = other["y0"]
            elif ox > oy:
                top, bottom = (a, b) if a["y0"] + a["y1"] < b["y0"] + b["y1"] else (b, a)
                mid = (top["y1"] + bottom["y0"]) / 2
                top["y1"], bottom["y0"] = mid, mid
            else:
                left, right = (a, b) if a["x0"] + a["x1"] < b["x0"] + b["x1"] else (b, a)
                mid = (left["x1"] + right["x0"]) / 2
                left["x1"], right["x0"] = mid, mid
    return rects


def booth_entry(booth_id, kind, rect):
    return {"id": booth_id, "type": kind, **centre_size(rect)}


def sort_reading_order(items, key):
    """Row by row, left to right: rows are grouped by the centre y rounded to the nearest metre."""
    return sorted(items, key=lambda item: (round(key(item)[1]), key(item)[0]))


# ---------------------------------------------------------------- checks

def poly_area(poly):
    return sum(poly[i][0] * poly[(i + 1) % len(poly)][1] - poly[(i + 1) % len(poly)][0] * poly[i][1]
               for i in range(len(poly))) / 2


def in_polygon(point, poly):
    x, y = point
    inside = False
    for i in range(len(poly)):
        x1, y1 = poly[i]
        x2, y2 = poly[(i + 1) % len(poly)]
        if (y1 > y) != (y2 > y) and x < (x2 - x1) * (y - y1) / (y2 - y1) + x1:
            inside = not inside
    return inside


def box(item):
    if "cx" in item:
        return item["cx"] - item["w"] / 2, item["cx"] + item["w"] / 2, item["cy"] - item["h"] / 2, item["cy"] + item["h"] / 2
    return item["x0"], item["x1"], item["y0"], item["y1"]


def overlap(a, b):
    """Overlap depth in metres along the thinner axis (0 when apart)."""
    ax0, ax1, ay0, ay1 = box(a)
    bx0, bx1, by0, by1 = box(b)
    return max(0.0, min(ax1, bx1) - max(ax0, bx0)), max(0.0, min(ay1, by1) - max(ay0, by0))


def raster(truth, res=0.1):
    """Boolean grids over the world: free floor (hall, lobby, door openings) and blocked cells."""
    world = truth["meta"]["world"]
    nx, ny = int(math.ceil(world["w"] / res)), int(math.ceil(world["h"] / res))

    def poly_mask(poly):
        img = Image.new("L", (nx, ny), 0)
        ImageDraw.Draw(img).polygon([(x / res, y / res) for x, y in poly], fill=1)
        return np.array(img, bool)

    def rect_mask(item):
        x0, x1, y0, y1 = box(item)
        m = np.zeros((ny, nx), bool)
        m[max(0, int(math.floor(y0 / res))):max(0, int(math.ceil(y1 / res))),
          max(0, int(math.floor(x0 / res))):max(0, int(math.ceil(x1 / res)))] = True
        return m

    floor = poly_mask(truth["hall"]) | poly_mask(truth["lobby"])
    blocked = np.zeros((ny, nx), bool)
    for item in truth["booths"] + truth["fixtures"] + truth["pilasters"] + truth["closed"]:
        blocked |= rect_mask(item)
    blocked |= rect_mask(truth["stage"])
    for column in truth["columns"]:
        yy, xx = np.mgrid[0:ny, 0:nx]
        blocked |= (xx * res + res / 2 - column["x"]) ** 2 + (yy * res + res / 2 - column["y"]) ** 2 <= (column["d"] / 2) ** 2
    walls = rect_mask(truth["wall"])
    openings = np.zeros((ny, nx), bool)
    for door in truth["doors"]:
        openings |= rect_mask(door)
    floor |= openings
    # the wall rectangle and the doors: the wall blocks, the doors open it again
    blocked |= walls
    blocked &= ~openings
    return floor, blocked, res


def check(truth, expect_outside=()):
    """Pass 7 checks. Returns (problems, notes). expect_outside lists booth ids allowed outside the hall."""
    problems, notes = [], []

    def rects():
        for name in ("pilasters", "fixtures", "closed"):
            for item in truth[name]:
                yield name, item
        for name in ("wall", "stage", "kids"):
            if name == "stage" and not any(truth["stage"][k] for k in ("x0", "x1", "y0", "y1")):
                continue  # a plan without a stage keeps an empty rectangle
            yield name, truth[name]
        for item in truth["doors"]:
            yield "door", item
        for item in truth["booths"]:
            yield "booth", item
        for item in truth["tables"]:
            yield "table", item

    for name, item in rects():
        x0, x1, y0, y1 = box(item)
        if not (x1 > x0 and y1 > y0):
            problems.append(f"{name} {item.get('id') or item.get('label') or ''} has empty extent {item}")
    wall = truth["wall"]
    for door in truth["doors"]:
        ox, oy = overlap(door, wall)
        if ox <= 0 or oy <= 0:
            problems.append(f"{door['id']} does not overlap the wall")
    for key, polygon in (("gates", truth["lobby"]),):
        for gate in truth["gates"]:
            if not in_polygon((gate["sx"], gate["sy"]), polygon):
                problems.append(f"gate {gate['id']} is outside the lobby")
    if not in_polygon((truth["exitPt"]["sx"], truth["exitPt"]["sy"]), truth["lobby"]):
        problems.append("exitPt is outside the lobby")
    if poly_area(truth["hall"]) < 0:
        notes.append("hall polygon is counter-clockwise on screen")

    # booths inside the hall and not overlapping
    booths = truth["booths"]
    outside = []
    for booth in booths:
        x0, x1, y0, y1 = box(booth)
        corners = [(x0 + 0.01, y0 + 0.01), (x1 - 0.01, y0 + 0.01), (x1 - 0.01, y1 - 0.01), (x0 + 0.01, y1 - 0.01)]
        if not all(in_polygon(c, truth["hall"]) for c in corners):
            outside.append(booth["id"])
    in_lobby = {b["id"] for b in booths if b["id"] in outside and in_polygon((b["cx"], b["cy"]), truth["lobby"])}
    outside_unexpected = [b for b in outside if b not in expect_outside and b not in in_lobby]
    if outside_unexpected:
        problems.append(f"{len(outside_unexpected)} booths not inside the hall: {outside_unexpected[:12]}")
    if outside:
        notes.append(f"{len(outside)} booths lie outside the hall polygon (kept, they are drawn; {len(in_lobby)} of them in the lobby): {outside[:20]}")
    order = sorted(range(len(booths)), key=lambda i: box(booths[i])[0])
    for a_pos, i in enumerate(order):
        a = booths[i]
        for j in order[a_pos + 1:]:
            b = booths[j]
            if box(b)[0] >= box(a)[1] - 0.1:
                break
            ox, oy = overlap(a, b)
            if ox > 0.1 and oy > 0.1:
                problems.append(f"booths {a['id']} and {b['id']} overlap {ox:.2f} x {oy:.2f} m")
    # booths against solid items
    solids = [("wall", truth["wall"])] + [(k, p) for k, p in [(p["kind"], p) for p in truth["pilasters"]]] \
        + [("fixture", f) for f in truth["fixtures"]] + [("stage", truth["stage"])]
    for booth in booths:
        for kind, item in solids:
            ox, oy = overlap(booth, item)
            if ox > 0.1 and oy > 0.1:
                problems.append(f"booth {booth['id']} lies on {kind} {item.get('label', '')} ({ox:.2f} x {oy:.2f} m)")
        for column in truth["columns"]:
            x0, x1, y0, y1 = box(booth)
            if x0 - column["d"] / 2 < column["x"] < x1 + column["d"] / 2 and y0 - column["d"] / 2 < column["y"] < y1 + column["d"] / 2:
                nearest_x = min(max(column["x"], x0), x1)
                nearest_y = min(max(column["y"], y0), y1)
                if math.hypot(column["x"] - nearest_x, column["y"] - nearest_y) < column["d"] / 2 - 0.05:
                    problems.append(f"booth {booth['id']} lies on a column at {column['x']},{column['y']}")

    # route: gates -> booth -> exit
    floor, blocked, res = raster(truth)
    walk = floor & ~blocked
    radius = 2  # 0.2 m clearance on each side, a passage must be at least 0.4 m wide
    walk_eroded = ndi.binary_erosion(walk, iterations=radius)
    labels, _ = ndi.label(walk_eroded)

    def component(point):
        gx, gy = int(point[0] / res), int(point[1] / res)
        for r in range(0, 15):
            window = labels[max(0, gy - r):gy + r + 1, max(0, gx - r):gx + r + 1]
            hits = window[window > 0]
            if hits.size:
                return int(np.bincount(hits).argmax())
        return 0

    start = component((truth["gates"][0]["sx"], truth["gates"][0]["sy"]))
    end = component((truth["exitPt"]["sx"], truth["exitPt"]["sy"]))
    if start == 0:
        problems.append("gate is not on walkable floor")
    if end != start:
        problems.append("exitPt is not connected to the entrance gate")
    unreachable = []
    for booth in booths:
        x0, x1, y0, y1 = box(booth)
        ring = np.zeros_like(blocked)
        a, b = max(0, int((y0 - 0.5) / res)), max(0, int((y1 + 0.5) / res))
        c, d = max(0, int((x0 - 0.5) / res)), max(0, int((x1 + 0.5) / res))
        ring[a:b, c:d] = True
        if not (labels[ring] == start).any():
            unreachable.append(booth["id"])
    if unreachable:
        problems.append(f"{len(unreachable)} booths cannot be reached from the gate: {unreachable[:25]}")
    return problems, notes


# ---------------------------------------------------------------- output

def finish(truth, name, frame, expect_outside=()):
    """Order the keys, run the checks, print the report, write data/<name>/truth.json and data/<name>/frame.json.

    frame is {"px_per_m": ..., "origin_px": [x, y]}: the layout.png pixel of the metre point (1, 1), so that
    pixel = (metres - 1) * px_per_m + origin_px. truth.json has no pixel scale; scripts/truth_loader.py reads
    frame.json to turn the truth back into pixel boxes for the scorer and the notebooks.
    """
    truth = {key: truth[key] for key in KEY_ORDER}
    problems, notes = check(truth, expect_outside)
    print(name, "booths", len(truth["booths"]), "tables", len(truth["tables"]), "pilasters", len(truth["pilasters"]),
          "fixtures", len(truth["fixtures"]), "columns", len(truth["columns"]), "closed", len(truth["closed"]))
    for note in notes:
        print("  note:", note)
    for problem in problems:
        print("  PROBLEM:", problem)
    lines = ["{"]
    for index, key in enumerate(KEY_ORDER):
        value = truth[key]
        comma = "," if index < len(KEY_ORDER) - 1 else ""
        if isinstance(value, list) and value and isinstance(value[0], dict):
            body = ",\n".join("  " + json.dumps(v, separators=(", ", ": ")) for v in value)
            lines.append(f' "{key}": [\n{body}\n ]{comma}')
        else:
            lines.append(f' "{key}": {json.dumps(value, separators=(", ", ": "))}{comma}')
    lines.append("}")
    with open(f"data/{name}/truth.json", "w") as f:
        f.write("\n".join(lines) + "\n")
    width, height = Image.open(f"data/{name}/layout.png").size
    sidecar = {"px_per_m": round(frame["px_per_m"], 4), "origin_px": [round(v, 2) for v in frame["origin_px"]],
               "image": {"width": width, "height": height}}
    with open(f"data/{name}/frame.json", "w") as f:
        json.dump(sidecar, f, indent=1)
        f.write("\n")
    return truth, problems


def counts(truth):
    kinds = {}
    for booth in truth["booths"]:
        kinds[booth["type"]] = kinds.get(booth["type"], 0) + 1
    walls = 1 + sum(1 for p in truth["pilasters"] if p["kind"] == "wall")
    parts = [f"{n} {k}" for k, n in sorted(kinds.items())]
    return ", ".join(parts), len(truth["tables"]), walls
