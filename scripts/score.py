"""Score extract_swift4 output against the truth files.

usage: score.py [layout.json truth.json]...   (default: the swift4 outputs for plans 1 to 3, 5 and 6, run from the project root)

Tiles and objects use greedy box IoU matching (tiles 0.5, others 0.3). Tiles match on box and ID only,
and class names are counted separately. Walls are thin and fragmented, so they use pixel coverage.
"""
import json
import sys

import numpy as np

PAIRS = [
    ("output/swift4/plan1/layout.json", "data/plan1/truth.json"),
    ("output/swift4/plan2/layout.json", "data/plan2/truth.json"),
    ("output/swift4/plan3/layout.json", "data/plan3/truth.json"),
    ("output/swift4/plan5/layout.json", "data/plan5/truth.json"),
    ("output/swift4/plan6/layout.json", "data/plan6/truth.json"),
]
NON_TILE = {"object", "wall", "pillar", "door", "symbol", "boundary"}
WALL_SLACK = 6


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


def row(name, found, truth_n, engine_n):
    precision = found / engine_n if engine_n else float("nan")
    return f"  {name:<8} {found:>4}/{truth_n:<4} recall {found / truth_n if truth_n else float('nan'):>6.1%}   engine {engine_n:>4}  precision {precision:>6.1%}"


def score(layout_path, truth_path):
    layout = json.load(open(layout_path))
    truth = json.load(open(truth_path))
    engine_items, truth_items = layout["items"], truth["items"]
    shape = (layout["image"]["height"], layout["image"]["width"])
    print(f"{layout_path} vs {truth_path}")

    t_tiles = [i for i in truth_items if i["class"] not in NON_TILE]
    e_tiles = [i for i in engine_items if i["class"] not in NON_TILE]
    pairs = greedy_match(t_tiles, e_tiles, 0.5)
    print(row("tiles", len(pairs), len(t_tiles), len(e_tiles)))
    same_class = sum(1 for ti, ei in pairs if t_tiles[ti]["class"] == e_tiles[ei]["class"])
    print(f"  tile class names equal {same_class}/{len(pairs)}")
    ids_truth = [t for t in t_tiles if t.get("id")]
    exact = sum(1 for ti, ei in pairs if t_tiles[ti].get("id") and e_tiles[ei].get("id") == t_tiles[ti]["id"])
    with_suggestion = sum(1 for ti, ei in pairs if t_tiles[ti].get("id") and t_tiles[ti]["id"] in (e_tiles[ei].get("id"), e_tiles[ei].get("suggested_id")))
    print(f"  tile ids exact {exact}/{len(ids_truth)}, with suggested_id {with_suggestion}/{len(ids_truth)}")

    for cls in ("object", "pillar", "door"):
        t = [i for i in truth_items if i["class"] == cls]
        e = [i for i in engine_items if i["class"] == cls]
        print(row(cls, len(greedy_match(t, e, 0.3)), len(t), len(e)))

    t_walls = [i for i in truth_items if i["class"] == "wall"]
    e_walls = [i for i in engine_items if i["class"] == "wall"]
    recall, precision = wall_scores(t_walls, e_walls, shape)
    print(f"  wall     pixel recall {recall:.1%}   pixel precision {precision:.1%}   (truth {len(t_walls)}, engine {len(e_walls)})")


def main():
    args = sys.argv[1:]
    pairs = list(zip(args[0::2], args[1::2])) if args else PAIRS
    for layout_path, truth_path in pairs:
        score(layout_path, truth_path)


main()
