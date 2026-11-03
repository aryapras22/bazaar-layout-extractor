"""Load a truth file as pixel items, whichever format it is in.

load_truth(path) returns {"image": {"width", "height"}, "items": [...]} with every item in layout.png pixels,
the shape that score.py, robustness.py, scale_stress.py and the notebooks work with.

- A file with an "items" list (truth_px.json, or a moved copy written by robustness.py) is returned as it is.
- The metre truth (data/planN/truth.json) is converted with data/planN/frame.json, pixel = (metres - 1) * px_per_m + origin.

What the metre truth becomes:
  booths               "Booth <ID letters>" tiles with their id and type; class names are derived from the ID, so
                       the legend names of the old truth ("Large booth X", "Interactive space I") do not come back
  fixtures             BLOCKED -> "Blocked", UNLABELED BLOCK -> "Unlabeled block", DOORPRIZE BOOTH -> "Booth J" (no id),
                       TENANT SPACE -> "boundary", the rest -> "object" with the label in lower case
  stage                "Stage" (skipped when the plan has none)
  doors                "door" boxes of the opening in the wall
  tables               a "table" box (the axis-aligned box of the tilted table, with its centre, true size in pixels and angle)
                       and a "chair" box per chair, both with their table number
  block pilasters, columns   "pillar"
  wall, wall pilasters, rails, hall edges   "wall" boxes (hall edges are 0.3 m wide)
Not in the metre truth, so not scored any more: diagonal walls, gates, object groups, swing-symbol boxes.
"""
import json
from pathlib import Path

FIXTURE_CLASS = {"BLOCKED": "Blocked", "UNLABELED BLOCK": "Unlabeled block", "DOORPRIZE BOOTH": "Booth J", "TENANT SPACE": "boundary"}
HALL_EDGE_M = 0.3


def load_truth(path):
    data = json.load(open(path))
    if "items" in data:
        return data
    frame = json.load(open(Path(path).with_name("frame.json")))
    scale, (ox, oy) = frame["px_per_m"], frame["origin_px"]

    def px_x(m):
        return (m - 1) * scale + ox

    def px_y(m):
        return (m - 1) * scale + oy

    def box(x0, x1, y0, y1):
        left, top, right, bottom = round(px_x(x0)), round(px_y(y0)), round(px_x(x1)), round(px_y(y1))
        return [left, top, max(1, right - left), max(1, bottom - top)]

    def rect(r):
        return box(r["x0"], r["x1"], r["y0"], r["y1"])

    def centred(r):
        return box(r["cx"] - r["w"] / 2, r["cx"] + r["w"] / 2, r["cy"] - r["h"] / 2, r["cy"] + r["h"] / 2)

    items = []
    for b in data["booths"]:
        letters = b["id"].rstrip("0123456789")
        items.append({"class": f"Booth {letters}", "box": centred(b), "id": b["id"], "kind": b["type"]})
    for f in data["fixtures"]:
        label = f["label"]
        if f["kind"] == "stage":
            items.append({"class": "object", "box": rect(f), "id": None, "label": label.lower()})
        elif label in FIXTURE_CLASS:
            items.append({"class": FIXTURE_CLASS[label], "box": rect(f), "id": None, "label": label.lower()})
        else:
            items.append({"class": "object", "box": rect(f), "id": None, "label": label.lower()})
    stage = data["stage"]
    if any(stage[k] for k in ("x0", "x1", "y0", "y1")):
        items.append({"class": "Stage", "box": rect(stage), "id": None})
    for d in data["doors"]:
        items.append({"class": "door", "box": rect(d), "id": None, "label": d["id"], "role": d["role"]})
    for t in data["tables"]:
        if t["kind"] == "table":
            items.append({"class": "table", "box": centred(t), "id": None, "table": t["table"],
                          "table_size": [t["rect"][0] * scale, t["rect"][1] * scale], "angle": t["angle"],
                          "centre": [px_x(t["cx"]), px_y(t["cy"])]})
        else:
            items.append({"class": "chair", "box": centred(t), "id": None, "table": t["table"]})
    for p in data["pilasters"]:
        if p["kind"] == "block":
            items.append({"class": "pillar", "box": rect(p), "id": None})
        else:
            items.append({"class": "wall", "box": rect(p), "id": None, "label": p["kind"]})
    for c in data["columns"]:
        half = c["d"] / 2
        items.append({"class": "pillar", "box": box(c["x"] - half, c["x"] + half, c["y"] - half, c["y"] + half), "id": None})
    items.append({"class": "wall", "box": rect(data["wall"]), "id": None, "label": "door wall"})
    hall, half = data["hall"], HALL_EDGE_M / 2
    for (x0, y0), (x1, y1) in zip(hall, hall[1:] + hall[:1]):
        if abs(y0 - y1) < 1e-6:
            items.append({"class": "wall", "box": box(min(x0, x1), max(x0, x1), y0 - half, y0 + half), "id": None, "label": "hall edge"})
        elif abs(x0 - x1) < 1e-6:
            items.append({"class": "wall", "box": box(x0 - half, x0 + half, min(y0, y1), max(y0, y1)), "id": None, "label": "hall edge"})
    return {"image": frame["image"], "items": items, "source": "metre truth converted with frame.json"}
