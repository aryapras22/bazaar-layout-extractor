"""Add the diagonal wall segments from the vector data to data/plan5/truth.json and data/plan6/truth.json.

Walls are stroke-only lines and rectangle edges at least 0.5 pt wide and 8 pt long; stall dividers are
0.19 pt and booth outlines are filled shapes, so width and fill separate them. Only slanted ones (more
than 6 degrees off the axes) are kept: zone dividers and stage outlines are stroked the same way as
walls, so axis-aligned lines are not reliable truth, while the slanted ones are building edges. Each
item is class "diagonal wall" with a pixel `segment` [x0, y0, x1, y1], a stroke `width` in pixels and
the bounding `box`. Run it after
make_plan5_truth.py and make_plan6_truth.py, which rewrite the whole file. Run from the project root.
"""
import json
import math

import pymupdf

PLANS = {
    "plan5": {"clip": pymupdf.Rect(105, 70, 300, 495), "zoom": 5.0},
    "plan6": {"clip": pymupdf.Rect(20, 60, 596, 690), "zoom": 4.0},
}
MIN_WIDTH_PT = 0.5
MIN_LENGTH_PT = 8


def segments(drawing):
    for item in drawing["items"]:
        if item[0] == "l":
            yield item[1], item[2]
        elif item[0] == "re":
            r = item[1]
            corners = [(r.x0, r.y0), (r.x1, r.y0), (r.x1, r.y1), (r.x0, r.y1)]
            for a, b in zip(corners, corners[1:] + corners[:1]):
                yield pymupdf.Point(*a), pymupdf.Point(*b)


for name, spec in PLANS.items():
    clip, zoom = spec["clip"], spec["zoom"]
    path = f"data/{name}/truth.json"
    truth = json.load(open(path))
    truth["items"] = [item for item in truth["items"] if item["class"] not in ("wall", "diagonal wall")]
    walls = []
    for drawing in pymupdf.open(f"data/{name}/source.pdf")[0].get_drawings():
        width = drawing.get("width") or 0
        # Booth and furniture outlines are filled shapes with a stroke; walls are stroke-only.
        if drawing.get("color") is None or drawing.get("fill") is not None or width < MIN_WIDTH_PT:
            continue
        for a, b in segments(drawing):
            if math.hypot(b.x - a.x, b.y - a.y) < MIN_LENGTH_PT:
                continue
            x0, y0, x1, y1 = (round((a.x - clip.x0) * zoom), round((a.y - clip.y0) * zoom),
                              round((b.x - clip.x0) * zoom), round((b.y - clip.y0) * zoom))
            angle = abs(math.degrees(math.atan2(b.y - a.y, b.x - a.x))) % 90
            if min(angle, 90 - angle) <= 6:
                continue
            if max(x0, x1) < 0 or max(y0, y1) < 0 or min(x0, x1) > truth["image"]["width"] or min(y0, y1) > truth["image"]["height"]:
                continue
            half = max(1, round(width * zoom / 2))
            walls.append({
                "class": "diagonal wall",
                "box": [min(x0, x1) - half, min(y0, y1) - half, abs(x1 - x0) + 2 * half, abs(y1 - y0) + 2 * half],
                "segment": [x0, y0, x1, y1],
                "width": round(width * zoom, 1),
                "id": None,
            })
    truth["items"] += walls
    truth["source"] += "; diagonal wall segments from the PDF strokes at least 0.5 pt wide (scripts/make_wall_truth.py)"
    with open(path, "w") as f:
        json.dump(truth, f, indent=1)
    print(name, len(walls), "diagonal wall segments")
