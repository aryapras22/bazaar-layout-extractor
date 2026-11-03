"""Python mirror of the seat layer (SeatLayer.swift): chairs, tables and the chair-to-table links.

The extractor needs macOS and Apple Vision; this runs anywhere, so a change to the seat layer can be tried and scored
before it is ported. It follows the Swift code step by step: inkMask, the long runs and thick or compact shapes of
scanInk (without the page tilt), chairs(), and tables() with minAreaRect(). Two things differ: Vision's text boxes are
not removed from the ink, and booths are claimed from the truth boxes, as the booth layer would claim them.

usage: python3 scripts/seat_layer_mirror.py [plan1 plan2 ...]   (default plans 1, 2, 3, 6; run from the project root)
Writes output/seat_mirror/planN/layout.json with the chair and table items as fp-extract writes them, then scores it.
"""
import json
import math
import os
import subprocess
import sys

import cv2
import numpy as np
from PIL import Image
from scipy import ndimage as ndi

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from truth_loader import load_truth  # noqa: E402

NON_TILE = {"object", "wall", "diagonal wall", "pillar", "door", "gate", "symbol", "boundary", "chair", "table"}


def content_side(rgb):
    h, w, _ = rgb.shape
    flat = rgb.reshape(-1, 3)[::7] >> 3
    keys = (flat[:, 0].astype(np.int64) << 16) | (flat[:, 1].astype(np.int64) << 8) | flat[:, 2]
    vals, counts = np.unique(keys, return_counts=True)
    g = vals[counts.argmax()]
    ground = np.array([(g >> 16) << 3 | 4, ((g >> 8) & 31) << 3 | 4, (g & 31) << 3 | 4])
    hit = np.abs(rgb.astype(int) - ground).sum(2) > 60
    rows, cols = np.nonzero(hit.sum(1) >= 3)[0], np.nonzero(hit.sum(0) >= 3)[0]
    return max(rows[-1] - rows[0] + 1, cols[-1] - cols[0] + 1)


def ink_mask(rgb):
    r, g, b = (rgb[..., k].astype(int) for k in range(3))
    gray = (299 * r + 587 * g + 114 * b) // 1000
    background = int(np.searchsorted(np.cumsum(np.bincount(gray.ravel(), minlength=256)) * 2, gray.size))
    cut = int(background * 0.75)
    top = np.maximum(np.maximum(r, g), b)
    chroma = top - np.minimum(np.minimum(r, g), b)
    sat = np.where(top == 0, 0, chroma * 255 // np.maximum(top, 1))
    dark = gray < 64
    dark_grey = int((dark & (sat < 40)).sum())
    dark_tinted = int((dark & (sat >= 40) & (chroma < 24)).sum())
    noise = dark_tinted >= 2 * max(dark_grey, 1)
    return ((sat < 40) | (noise & (chroma < 30))) & (gray < cut)


def box_dilate(mask, r):
    if r <= 0:
        return mask
    return ndi.maximum_filter(mask.astype(np.uint8), size=2 * r + 1).astype(bool)


def chairs(ink, page):
    """chairs(ink:w:h:page:): closed round holes in the ink that come in sets of three or more."""
    h, w = ink.shape
    smallest = max(3, int(0.001 * page))
    largest = max(smallest, int(0.015 * page))
    labels, count = ndi.label(~ink, structure=[[0, 1, 0], [1, 1, 1], [0, 1, 0]])
    objs = ndi.find_objects(labels)
    sizes = np.bincount(labels.ravel())
    holes = []
    for k, sl in enumerate(objs, 1):
        if sl is None:
            continue
        y0, y1, x0, x1 = sl[0].start, sl[0].stop - 1, sl[1].start, sl[1].stop - 1
        if x0 == 0 or y0 == 0 or x1 == w - 1 or y1 == h - 1:
            continue
        bw, bh = x1 - x0 + 1, y1 - y0 + 1
        d = max(bw, bh)
        if not (smallest <= d <= largest) or d * 4 > min(bw, bh) * 5:
            continue
        fill = sizes[k] / (bw * bh)
        if not (0.6 <= fill <= 0.97):
            continue
        if any(labels[y, x] == k for y, x in ((y0, x0), (y0, x1), (y1, x0), (y1, x1))):
            continue

        def run(x, y, dx, dy):
            cx, cy, n = x + dx, y + dy, 0
            while 0 <= cx < w and 0 <= cy < h and ink[cy, cx]:
                n += 1
                cx += dx
                cy += dy
            return n
        mx, my = (x0 + x1) // 2, (y0 + y1) // 2
        t = max(1, min(run(x0, my, -1, 0), run(x1, my, 1, 0), run(mx, y0, 0, -1), run(mx, y1, 0, 1)))
        holes.append(((x0 - t, y0 - t, bw + 2 * t, bh + 2 * t), d))
    out = []
    centres = np.array([(r[0] + r[2] / 2, r[1] + r[3] / 2) for r, _ in holes])
    diams = np.array([d for _, d in holes], float)
    for i, (r, d) in enumerate(holes):
        near = (np.abs(diams - d) <= max(1.5, 0.2 * d)) & (np.hypot(*(centres - centres[i]).T) <= 6 * d)
        if near.sum() >= 3:
            out.append(r)
    return out


def runs(mask, min_len, axis):
    """Pixels on straight runs of at least min_len along the axis (no tilt; tiltedRuns with tilt 0)."""
    m = mask if axis == 1 else mask.T
    out = np.zeros_like(m)
    for y in range(m.shape[0]):
        row = m[y]
        if not row.any():
            continue
        d = np.diff(np.concatenate([[0], row.view(np.int8), [0]]))
        starts, ends = np.nonzero(d == 1)[0], np.nonzero(d == -1)[0]
        for s, e in zip(starts, ends):
            if e - s >= min_len:
                out[y, s:e] = True
    return out if axis == 1 else out.T


def scan(rgb, claimed):
    page = content_side(rgb)
    ink = ink_mask(rgb) & ~claimed
    longest = max(5, round(0.025 * page))
    hs, vs = runs(ink, longest, 1), runs(ink, longest, 0)
    k = max(7, round(0.004 * page) | 1)
    opened = ndi.binary_dilation(ndi.binary_erosion(ink, np.ones((k, k))), np.ones((k, k)))
    lab, n = ndi.label(opened, structure=np.ones((3, 3)))
    thick, compact = np.zeros_like(ink), np.zeros_like(ink)
    for i, sl in enumerate(ndi.find_objects(lab), 1):
        reg = lab[sl] == i
        hh, ww = reg.shape
        long, short = max(hh, ww), min(hh, ww)
        fill = reg.sum() / (hh * ww)
        target = thick if (long >= 4 * short and long >= longest) or fill < 0.5 else compact
        target[sl] |= reg
    near = box_dilate(compact, 2)
    hs &= ~near
    vs &= ~near
    return page, ink, hs | vs | thick, compact


def convex_hull(pixels_xy):
    """convexHull in Imaging.swift: row extents, pixel corners, monotone chain, open polygon."""
    xs, ys = pixels_xy[:, 0], pixels_xy[:, 1]
    pts = []
    for y in np.unique(ys):
        row = xs[ys == y]
        for x in (row.min() - 0.5, row.max() + 0.5):
            pts += [(x, y - 0.5), (x, y + 0.5)]
    pts.sort()
    def cross(o, a, b):
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])
    hull = []
    for p in pts:
        while len(hull) >= 2 and cross(hull[-2], hull[-1], p) <= 0:
            hull.pop()
        hull.append(p)
    lower = len(hull) + 1
    for p in reversed(pts[:-1]):
        while len(hull) >= lower and cross(hull[-2], hull[-1], p) <= 0:
            hull.pop()
        hull.append(p)
    hull.pop()
    return hull


def min_area_rect(hull):
    if len(hull) < 3:
        return None
    best = None
    for k in range(len(hull)):
        p, q = hull[k], hull[(k + 1) % len(hull)]
        length = math.hypot(q[0] - p[0], q[1] - p[1])
        if length <= 1e-9:
            continue
        u = ((q[0] - p[0]) / length, (q[1] - p[1]) / length)
        v = (-u[1], u[0])
        s = [r[0] * u[0] + r[1] * u[1] for r in hull]
        t = [r[0] * v[0] + r[1] * v[1] for r in hull]
        area = (max(s) - min(s)) * (max(t) - min(t))
        if best is None or area < best[0] - 1e-9:
            sm, tm = (min(s) + max(s)) / 2, (min(t) + max(t)) / 2
            best = (area, sm * u[0] + tm * v[0], sm * u[1] + tm * v[1], max(s) - min(s), max(t) - min(t), math.atan2(u[1], u[0]))
    _, cx, cy, along, across, theta = best
    if across > along:
        along, across, theta = across, along, theta + math.pi / 2
    deg = math.fmod(math.degrees(theta), 180)
    if deg < 0:
        deg += 180
    if deg >= 179.95:
        deg = 0
    return cx, cy, along, across, deg


def swift_round(v):
    return math.floor(v + 0.5) if v >= 0 else -math.floor(-v + 0.5)


def tables(rest, rest_near, chair_rects):
    """tables(rest:blobs:chairs:w:h:). rest_near is the seat ink grown by the join radius; its blobs are the symbols."""
    h, w = rest.shape
    if len(chair_rects) < 2:
        return []
    side = sorted(c[2] for c in chair_rects)[len(chair_rects) // 2]
    label, n = ndi.label(rest_near, structure=np.ones((3, 3)))
    label = label - 1  # -1 is no blob
    def vote(x0, y0, x1, y1):
        ax, ay, bx, by = max(0, x0), max(0, y0), min(w - 1, x1), min(h - 1, y1)
        if ax > bx or ay > by:
            return None
        win = label[ay:by + 1, ax:bx + 1]
        hits = win[win >= 0]
        if not hits.size:
            return None
        return int(np.bincount(hits).argmax())
    members = {}
    for i, (x, y, cw, ch) in enumerate(chair_rects):
        cx, cy = int(x + cw / 2), int(y + ch / 2)
        b = vote(cx - 1, cy - 1, cx + 1, cy + 1)
        if b is None:
            b = vote(int(x), int(y), int(x + cw), int(y + ch))
        if b is not None:
            members.setdefault(b, []).append(i)
    objs = ndi.find_objects(label + 1)
    found = []
    for blob in sorted(members):
        mine = members[blob]
        if not 2 <= len(mine) <= 8:
            continue
        sl = objs[blob]
        y0, x0 = sl[0].start, sl[1].start
        region = (label[sl] == blob) & rest[sl]
        yy, xx = np.mgrid[sl[0], sl[1]]
        for c in mine:
            x, y, cw, ch = chair_rects[c]
            dcx, dcy, r = swift_round(x + cw / 2), swift_round(y + ch / 2), swift_round(max(cw, ch) / 2 + 1.5)
            region &= (xx - dcx) ** 2 + (yy - dcy) ** 2 > r * r
        parts, k = ndi.label(region, structure=np.ones((3, 3)))
        sizes = np.bincount(parts.ravel())
        keep = [j for j in range(1, k + 1) if sizes[j] >= side]
        ys, xs = np.nonzero(np.isin(parts, keep))
        if len(xs) < 12:
            continue
        fit = min_area_rect(convex_hull(np.column_stack([xs + x0, ys + y0])))
        if fit is None:
            continue
        cx, cy, a, b, deg = fit
        u = (math.cos(math.radians(deg)), math.sin(math.radians(deg)))
        def gap(c):
            x, y, cw, ch = chair_rects[c]
            px, py = x + cw / 2 - cx, y + ch / 2 - cy
            return math.hypot(max(abs(px * u[0] + py * u[1]) - a / 2, 0), max(abs(-px * u[1] + py * u[0]) - b / 2, 0))
        if max(gap(c) for c in mine) > 1.5 * side:
            continue
        found.append({"blob": blob + 1, "members": mine, "cx": cx, "cy": cy, "long": a, "short": b, "theta": math.radians(deg)})
    row = max(1, 2 * side)
    found.sort(key=lambda f: (math.floor(f["cy"] / row), f["cx"]))
    return found


def seat_items(rgb, booth_boxes):
    """Chair and table items for one page, as seatLayer() returns them (without the object blobs)."""
    claimed = np.zeros(rgb.shape[:2], bool)
    for x, y, w, h in booth_boxes:
        claimed[y + 2:y + h - 2, x + 2:x + w - 2] = True
    page, ink, strokes, compact = scan(rgb, claimed)
    found = chairs(ink, page)
    rest = ink & ~box_dilate(strokes, 3) & ~box_dilate(compact, 4)
    side = sorted(r[2] for r in found)[len(found) // 2] if found else 0
    join = min(2, max(1, swift_round(side / 6))) if len(found) >= 8 else 2
    fits = tables(rest, box_dilate(rest, join), found)
    items, table_of = [], {}
    for number, f in enumerate(fits, 1):
        for c in f["members"]:
            table_of[c] = number
        t = f["theta"]
        u, v = (math.cos(t), math.sin(t)), (-math.sin(t), math.cos(t))
        corners = [(f["cx"] + a * f["long"] / 2 * u[0] + b * f["short"] / 2 * v[0], f["cy"] + a * f["long"] / 2 * u[1] + b * f["short"] / 2 * v[1])
                   for a, b in ((-1, -1), (1, -1), (1, 1), (-1, 1))]
        x0, x1 = math.floor(min(p[0] for p in corners)), math.ceil(max(p[0] for p in corners))
        y0, y1 = math.floor(min(p[1] for p in corners)), math.ceil(max(p[1] for p in corners))
        items.append({"class": "object", "box": [x0, y0, x1 - x0, y1 - y0], "id": None, "kind": "table", "seat": True,
                      "chairs": len(f["members"]), "table": number,
                      "table_size": [round(f["long"], 1), round(f["short"], 1)], "angle": round(math.degrees(t), 1)})
    for i, (x, y, w, h) in enumerate(found):
        items.append({"class": "object", "box": [int(x), int(y), int(w), int(h)], "id": None, "kind": "chair", "seat": True,
                      "table": table_of.get(i)})
    return items


def main():
    plans = sys.argv[1:] or ["plan1", "plan2", "plan3", "plan6"]
    for plan in plans:
        truth_path = f"data/{plan}/truth.json"
        truth = load_truth(truth_path)
        rgb = np.array(Image.open(f"data/{plan}/layout.png").convert("RGB"))
        booths = [it["box"] for it in truth["items"] if it["class"] not in NON_TILE and it.get("id")]
        out = f"output/seat_mirror/{plan}"
        os.makedirs(out, exist_ok=True)
        json.dump({"image": truth["image"], "items": seat_items(rgb, booths)}, open(f"{out}/layout.json", "w"))
        result = subprocess.run([sys.executable, "scripts/score.py", f"{out}/layout.json", truth_path], capture_output=True, text=True)
        print("\n".join(l for l in result.stdout.splitlines() if l.startswith(("output", "  chair", "  table"))))


if __name__ == "__main__":
    main()
