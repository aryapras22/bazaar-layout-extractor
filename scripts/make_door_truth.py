"""Add door swing symbols from the vector data to data/plan5/truth.json and data/plan6/truth.json.

The PDFs draw a door leaf's swing as a stroke-only path of one Bezier curve (a quarter circle, so its
box is square). Chairs, tables and icons are filled shapes or closed multi-curve paths, so the single
unfilled curve separates them. Curves whose boxes touch or lie within a third of their size are one
symbol, which joins the two halves of a double door. Each item is class "door" with the union box in
layout pixels. Run it after make_plan5_truth.py, make_plan6_truth.py and make_wall_truth.py, which
rewrite the file. Run from the project root.
"""
import json

import pymupdf

PLANS = {
    "plan5": {"clip": pymupdf.Rect(105, 70, 300, 495), "zoom": 5.0},
    "plan6": {"clip": pymupdf.Rect(20, 60, 596, 690), "zoom": 4.0},
}
MIN_SIDE_PX = 7
MAX_SIDE_PX = 60
SQUARENESS = 0.7


def swing_boxes(page, clip, zoom):
    boxes = []
    for drawing in page.get_drawings():
        if drawing.get("fill") is not None or [i[0] for i in drawing["items"]] != ["c"]:
            continue
        r = drawing["rect"]
        x0, y0 = (r.x0 - clip.x0) * zoom, (r.y0 - clip.y0) * zoom
        w, h = r.width * zoom, r.height * zoom
        if not (MIN_SIDE_PX <= max(w, h) <= MAX_SIDE_PX) or min(w, h) < SQUARENESS * max(w, h):
            continue
        boxes.append([x0, y0, x0 + w, y0 + h])
    return boxes


def symbols(boxes):
    parent = list(range(len(boxes)))

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    for i, a in enumerate(boxes):
        for j in range(i + 1, len(boxes)):
            b = boxes[j]
            reach = (max(a[2] - a[0], b[2] - b[0])) / 3
            if a[0] - reach <= b[2] and b[0] - reach <= a[2] and a[1] - reach <= b[3] and b[1] - reach <= a[3]:
                parent[find(i)] = find(j)
    groups = {}
    for i, b in enumerate(boxes):
        groups.setdefault(find(i), []).append(b)
    for group in groups.values():
        yield [min(b[0] for b in group), min(b[1] for b in group), max(b[2] for b in group), max(b[3] for b in group)], len(group)


for name, spec in PLANS.items():
    clip, zoom = spec["clip"], spec["zoom"]
    path = f"data/{name}/truth.json"
    truth = json.load(open(path))
    truth["items"] = [item for item in truth["items"] if item["class"] != "door"]
    page = pymupdf.open(f"data/{name}/source.pdf")[0]
    width, height = truth["image"]["width"], truth["image"]["height"]
    doors = []
    for (x0, y0, x1, y1), arcs in symbols(swing_boxes(page, clip, zoom)):
        if x1 < 0 or y1 < 0 or x0 > width or y0 > height:
            continue
        doors.append({
            "class": "door",
            "box": [round(x0), round(y0), round(x1 - x0), round(y1 - y0)],
            "arcs": arcs,
            "id": None,
        })
    truth["items"] += doors
    truth["source"] += "; door swing symbols from the single stroked curves in the PDF (scripts/make_door_truth.py)"
    with open(path, "w") as f:
        json.dump(truth, f, indent=1)
    print(name, len(doors), "door symbols")
