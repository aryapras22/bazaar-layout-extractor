"""Score fp-extract output against the truth files.

usage: score.py [--layer booth,wall,door,seat] [layout.json truth.json]...
Default: output/extractor/planN/layout.json for plans 1 to 3, 5 and 6, run from the project root. --layer prints only the lines
of those pipelines, so one pipeline can be improved and read on its own:
  booth  tiles, tile IDs and class names
  wall   walls, diagonal walls, pillars
  door   doors, gates
  seat   objects, chairs, tables, chair-to-table links

Tiles and objects use greedy box IoU matching (tiles 0.5, others 0.3). Tiles match on box and ID only,
and class names are counted separately. Walls are thin and fragmented, so they use pixel coverage.
Objects leave out single chairs (kind "chair") and tables (kind "table"); chairs are scored as "chair" against the seats of
the truth, tables as "table" (box IoU 0.5, then centre, size and angle), and each matched chair on whether it names the right table.

The truth is data/planN/truth.json (metres, read through truth_loader.py and frame.json) or a pixel truth with an "items"
list (truth_px.json, or the moved copies of robustness.py). Against the metre truth the tiles are the booths, doors are the
openings of the door wall, chairs are the "tables" entries, pillars are block pilasters and columns, and walls are the door
wall, wall pilasters and the hall edges. Diagonal walls, gates and object groups have no metre truth and print 0 truth items.
Chairs come from data/planN/seats.json only when the truth has no chairs of its own.
"""
import json
import os
import sys

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from truth_loader import load_truth  # noqa: E402

PAIRS = [
    ("output/extractor/plan1/layout.json", "data/plan1/truth.json"),
    ("output/extractor/plan2/layout.json", "data/plan2/truth.json"),
    ("output/extractor/plan3/layout.json", "data/plan3/truth.json"),
    ("output/extractor/plan5/layout.json", "data/plan5/truth.json"),
    ("output/extractor/plan6/layout.json", "data/plan6/truth.json"),
]
NON_TILE = {"object", "wall", "diagonal wall", "pillar", "door", "gate", "symbol", "boundary", "chair", "table"}
WALL_SLACK = 6
SEAT_LABELS = {"table_with_chairs", "audience_seating", "audience_seating_block"}


def iou(a, b):
    ix = max(0, min(a[0] + a[2], b[0] + b[2]) - max(a[0], b[0]))
    iy = max(0, min(a[1] + a[3], b[1] + b[3]) - max(a[1], b[1]))
    inter = ix * iy
    union = a[2] * a[3] + b[2] * b[3] - inter
    return inter / union if union else 0.0


def greedy_match(truth, engine, threshold):
    scored = sorted(
        ((iou(t["box"], e["box"]), ti, ei) for ti, t in enumerate(truth) for ei, e in enumerate(engine)),
        reverse=True,
    )
    used_t, used_e, pairs = set(), set(), []
    for score, ti, ei in scored:
        if score < threshold:
            break
        if ti in used_t or ei in used_e:
            continue
        used_t.add(ti)
        used_e.add(ei)
        pairs.append((ti, ei))
    return pairs


def segment_mask(items, shape, grow):
    mask = np.zeros(shape, dtype=np.uint8)
    for it in items:
        x0, y0, x1, y1 = it["segment"]
        cv2.line(mask, (x0, y0), (x1, y1), 1, max(1, round(it.get("width", 2))) + 2 * grow)
    return mask.astype(bool)


def wall_mask(items, shape, grow=0):
    mask = np.zeros(shape, dtype=bool)
    for it in items:
        x, y, w, h = it["box"]
        mask[max(0, y - grow): y + h + grow, max(0, x - grow): x + w + grow] = True
    return mask


def wall_scores(truth, engine, shape):
    t_mask, e_mask = wall_mask(truth, shape), wall_mask(engine, shape)
    t_near = wall_mask(truth, shape, WALL_SLACK)
    e_near = wall_mask(engine, shape, WALL_SLACK)
    recall = (t_mask & e_near).sum() / max(t_mask.sum(), 1)
    precision = (e_mask & t_near).sum() / max(e_mask.sum(), 1)
    return recall, precision


DOOR_COVER = 0.5  # plans 1 and 2: the truth is the opening band, the engine box is the whole swing symbol around it


def cover_match(truth, engine, threshold):
    """Match an engine box to a truth box when it covers at least threshold of the truth box area."""
    scored = []
    for ti, t in enumerate(truth):
        tx, ty, tw, th = t["box"]
        for ei, e in enumerate(engine):
            ex, ey, ew, eh = e["box"]
            ix = max(0, min(tx + tw, ex + ew) - max(tx, ex))
            iy = max(0, min(ty + th, ey + eh) - max(ty, ey))
            scored.append((ix * iy / (tw * th), ti, ei))
    used_t, used_e, pairs = set(), set(), []
    for cover, ti, ei in sorted(scored, reverse=True):
        if cover < threshold:
            break
        if ti not in used_t and ei not in used_e:
            used_t.add(ti)
            used_e.add(ei)
            pairs.append((ti, ei))
    return pairs


LAYERS = ("booth", "wall", "door", "seat")
CLASS_LAYER = {"object": "seat", "pillar": "wall", "door": "door", "gate": "door"}
shown = set(LAYERS)


def say(layer, text):
    if layer in shown:
        print(text)


def row(name, found, truth_n, engine_n):
    precision = found / engine_n if engine_n else float("nan")
    return f"  {name:<8} {found:>4}/{truth_n:<4} recall {found / truth_n if truth_n else float('nan'):>6.1%}   engine {engine_n:>4}  precision {precision:>6.1%}"


def angle_gap(a, b):
    return abs((a - b + 90) % 180 - 90)


def score_tables(truth_items, engine_items, t_chairs, e_chairs, chair_pairs):
    """Tables match on box IoU 0.5. A matched chair has the right table when the engine's table of that chair is the
    match of the truth's table, or when neither gives it a table (audience rows, loose seats)."""
    t_tables = [i for i in truth_items if i["class"] == "table"]
    e_tables = [i for i in engine_items if i["class"] == "object" and i.get("kind") == "table"]
    if not t_tables and not e_tables:
        return
    pairs = greedy_match(t_tables, e_tables, 0.5)
    say("seat", row("table", len(pairs), len(t_tables), len(e_tables)))
    shifts, sizes, turns = [], [], []
    for ti, ei in pairs:
        t, e = t_tables[ti], e_tables[ei]
        if "centre" in t and "table_size" in e:
            ex, ey = e["box"][0] + e["box"][2] / 2, e["box"][1] + e["box"][3] / 2
            shifts.append(np.hypot(ex - t["centre"][0], ey - t["centre"][1]))
            sizes.append(max(abs(a - b) for a, b in zip(e["table_size"], t["table_size"])))
            turns.append(angle_gap(e["angle"], t["angle"]))
    if shifts:
        say("seat", f"  table geometry px: centre off median {np.median(shifts):.1f} max {max(shifts):.1f}, "
              f"size off median {np.median(sizes):.1f} max {max(sizes):.1f}, angle off median {np.median(turns):.1f} max {max(turns):.1f} deg")
    engine_to_truth = {e_tables[ei].get("table"): t_tables[ti].get("table") for ti, ei in pairs}
    right = sum(1 for ti, ei in chair_pairs
                if (t_chairs[ti].get("table") is None and e_chairs[ei].get("table") is None)
                or (e_chairs[ei].get("table") is not None and engine_to_truth.get(e_chairs[ei]["table"]) == t_chairs[ti].get("table")))
    say("seat", f"  chair table links right {right}/{len(chair_pairs)} matched chairs")


def score(layout_path, truth_path):
    layout = json.load(open(layout_path))
    truth = load_truth(truth_path)
    engine_items, truth_items = layout["items"], truth["items"]
    shape = (layout["image"]["height"], layout["image"]["width"])
    print(f"{layout_path} vs {truth_path}")

    t_tiles = [i for i in truth_items if i["class"] not in NON_TILE]
    e_tiles = [i for i in engine_items if i["class"] not in NON_TILE]
    pairs = greedy_match(t_tiles, e_tiles, 0.5)
    say("booth", row("tiles", len(pairs), len(t_tiles), len(e_tiles)))
    same_class = sum(1 for ti, ei in pairs if t_tiles[ti]["class"] == e_tiles[ei]["class"])
    derived = "source" in truth
    say("booth", f"  tile class names equal {same_class}/{len(pairs)}" + ("   (truth class names come from the ID letters)" if derived else ""))
    ids_truth = [t for t in t_tiles if t.get("id")]
    exact = sum(1 for ti, ei in pairs if t_tiles[ti].get("id") and e_tiles[ei].get("id") == t_tiles[ti]["id"])
    with_suggestion = sum(1 for ti, ei in pairs if t_tiles[ti].get("id") and t_tiles[ti]["id"] in (e_tiles[ei].get("id"), e_tiles[ei].get("suggested_id")))
    say("booth", f"  tile ids exact {exact}/{len(ids_truth)}, with suggested_id {with_suggestion}/{len(ids_truth)}")

    for cls in ("object", "pillar", "door", "gate"):
        t = [i for i in truth_items if i["class"] == cls]
        e = [i for i in engine_items if i["class"] == cls and i.get("kind") not in ("chair", "table")]
        if cls == "door":
            pairs = cover_match(t, e, DOOR_COVER)
            say("door", f"  door     {len(pairs):>4}/{len(t):<4} recall {len(pairs) / len(t) if t else float('nan'):>6.1%}   swing symbols not in truth {len(e) - len(pairs)}")
            continue
        pairs = greedy_match(t, e, 0.3)
        say(CLASS_LAYER[cls], row(cls, len(pairs), len(t), len(e)))
        if cls == "object" and t:
            judged = [(ti, ei) for ti, ei in pairs if "seat" in e[ei]]
            right = sum(1 for ti, ei in judged if e[ei]["seat"] == (t[ti].get("label") in SEAT_LABELS))
            say("seat", f"  seat flag right {right}/{len(judged)} judged, {len(pairs) - len(judged)} matched objects not judged")
            negatives = [(ti, ei) for ti, ei in judged if t[ti].get("label") not in SEAT_LABELS]
            say("seat", f"  seat flag on matched negatives {sum(1 for ti, ei in negatives if not e[ei]['seat'])}/{len(negatives)} right")
            matched = {ei for _, ei in pairs}
            extra = [i for k, i in enumerate(e) if k not in matched]
            say("seat", f"  unmatched objects flagged seat {sum(1 for i in extra if i.get('seat'))}/{len(extra)}")

    seats_path = truth_path.replace("truth.json", "seats.json")
    t = [i for i in truth_items if i["class"] == "chair"]
    if not t and os.path.exists(seats_path):
        t = json.load(open(seats_path))["items"]
    if t:
        e = [i for i in engine_items if i["class"] == "object" and i.get("kind") == "chair"]
        chair_pairs = greedy_match(t, e, 0.5)
        say("seat", row("chair", len(chair_pairs), len(t), len(e)))
        score_tables(truth_items, engine_items, t, e, chair_pairs)

    t_diagonal = [i for i in truth_items if i["class"] == "diagonal wall"]
    if t_diagonal:
        e_diagonal = [i for i in engine_items if i["class"] == "wall" and i.get("segment")]
        covered = segment_mask(e_diagonal, shape, WALL_SLACK)
        found = 0
        for item in t_diagonal:
            own = segment_mask([item], shape, 0)
            found += (own & covered).sum() >= 0.5 * max(own.sum(), 1)
        say("wall", f"  diagonal wall found {found}/{len(t_diagonal)}   engine diagonal walls {len(e_diagonal)}")

    t_walls = [i for i in truth_items if i["class"] == "wall"]
    e_walls = [i for i in engine_items if i["class"] == "wall"]
    recall, precision = wall_scores(t_walls, e_walls, shape)
    say("wall", f"  wall     pixel recall {recall:.1%}   pixel precision {precision:.1%}   (truth {len(t_walls)}, engine {len(e_walls)})")


def main():
    global shown
    args = sys.argv[1:]
    if args[:1] == ["--layer"]:
        shown = set(args[1].split(","))
        unknown = shown - set(LAYERS)
        if unknown:
            sys.exit(f"unknown layer {sorted(unknown)}, use {','.join(LAYERS)}")
        args = args[2:]
    pairs = list(zip(args[0::2], args[1::2])) if args else PAIRS
    for layout_path, truth_path in pairs:
        score(layout_path, truth_path)


main()
