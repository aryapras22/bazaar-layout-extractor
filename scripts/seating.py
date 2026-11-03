"""Find every table and the chairs around it in a layout image, for the metre truth.

Chair boxes come from the checked seats.json lists (round chairs found as closed ink rings, looked at by eye).
The table is found from the pixels: a symbol (table with its chairs) is one connected piece of ink, the chair
discs are erased, and what is left is the table outline. Its minimum-area rectangle gives the true size and tilt;
w and h in the truth are the axis-aligned box of that rectangle.

Entries written to "tables":
  {"kind": "table", "table": N, "cx", "cy", "w", "h", "rect": [long, short], "angle": degrees}
  {"kind": "chair", "table": N, "cx", "cy", "w", "h"}            a chair of table N
  {"kind": "chair", "table": null, "cx", "cy", "w", "h"}         a seat that belongs to no table (audience rows)
"""
import collections
import math

import cv2
import numpy as np
from scipy import ndimage as ndi

OUTLINE_PX = 2.0  # the fitted rectangle runs through the stroke centres; this adds the stroke width to reach the outer edge


def chair_masks(shape, chairs, pad=1.5):
    mask = np.zeros(shape, bool)
    for x, y, w, h in chairs:
        cv2.circle(mask.view(np.uint8), (int(round(x + w / 2)), int(round(y + h / 2))), int(round(max(w, h) / 2 + pad)), 1, -1)
    return mask


def find_tables(ink, chairs, join=2, min_pixels=40, pad=2.5):
    """ink: boolean mask of the symbol colour. chairs: [x, y, w, h] boxes in pixels.

    Returns (tables, owner): tables is a list of dicts {"centre": (x, y), "size": (long, short), "angle": deg, "box": (x0, y0, x1, y1)}
    in pixels, owner[i] is the index of the table chair i belongs to, or None.

    A symbol is the table with its chairs, one connected piece of ink. The chair discs are erased, which leaves the table outline.
    All tables of a plan share one symbol, so size and tilt are fitted once on a few clean symbols by sliding a rectangle outline
    over the ink (best overlap wins), then every table is placed by sliding that outline in steps of half a pixel. The first
    guess of a table's centre is the mean of its chairs.
    """
    joined = ndi.binary_dilation(ink, iterations=join)
    labels, _ = ndi.label(joined)
    discs = chair_masks(ink.shape, chairs, pad)
    owner_label = []
    for x, y, w, h in chairs:
        window = labels[max(0, y - 1):y + h + 2, max(0, x - 1):x + w + 2]
        hits = window[window > 0]
        owner_label.append(int(np.bincount(hits).argmax()) if hits.size else 0)
    symbols = []
    for label in sorted(set(owner_label) - {0}):
        members = [i for i, l in enumerate(owner_label) if l == label]
        if len(members) < 2:
            continue  # a lone ring is an audience seat, not a table symbol
        centre = (np.mean([chairs[i][0] + chairs[i][2] / 2 for i in members]), np.mean([chairs[i][1] + chairs[i][3] / 2 for i in members]))
        radius = 36
        x0, y0 = int(centre[0]) - radius, int(centre[1]) - radius
        window = (ink & (labels == label) & ~discs)[max(0, y0):y0 + 2 * radius, max(0, x0):x0 + 2 * radius]
        if int(window.sum()) < min_pixels:
            continue
        symbols.append((label, centre, (max(0, x0), max(0, y0)), window))

    def corners_of(cx, cy, long_side, short_side, theta):
        u = np.array([math.cos(theta), math.sin(theta)])
        v = np.array([-u[1], u[0]])
        c = np.array([cx, cy])
        return np.array([c + sx * long_side / 2 * u + sy * short_side / 2 * v for sx, sy in ((-1, -1), (1, -1), (1, 1), (-1, 1))])

    def overlap(window, origin, cx, cy, long_side, short_side, theta, ys, xs):
        canvas = np.zeros(window.shape, np.uint8)
        pts = corners_of(cx - origin[0], cy - origin[1], long_side, short_side, theta)
        cv2.polylines(canvas, [np.round(pts * 4).astype(np.int32)], True, 1, 2, shift=2)
        return int(canvas[ys, xs].sum())

    # first fit per symbol: minimum-area rectangle of the leftover outline pixels
    fits = []
    for label, centre, origin, window in symbols:
        ys, xs = np.nonzero(window)
        pts = np.column_stack([xs, ys]).astype(np.float32)
        rect = cv2.minAreaRect(pts)
        box = cv2.boxPoints(rect)
        e1, e2 = box[1] - box[0], box[2] - box[1]
        long_edge, short_edge = (e1, e2) if np.linalg.norm(e1) >= np.linalg.norm(e2) else (e2, e1)
        fits.append({"centre": (rect[0][0] + origin[0], rect[0][1] + origin[1]), "long": float(np.linalg.norm(long_edge)),
                     "short": float(np.linalg.norm(short_edge)), "theta": math.atan2(long_edge[1], long_edge[0]) % math.pi})
    long_side = float(np.median([f["long"] for f in fits]))
    short_side = float(np.median([f["short"] for f in fits]))

    def sized(f):
        return abs(f["long"] - long_side) <= 1.5 and abs(f["short"] - short_side) <= 1.5

    # the tables of a plan may stand in more than one direction: keep every tilt that several clean fits share
    counts = collections.Counter(round(math.degrees(f["theta"]) / 5) * 5 % 180 for f in fits if sized(f))
    modes = []
    for degrees, count in counts.most_common():
        if count >= 3:
            members = [f["theta"] for f in fits if sized(f) and abs((math.degrees(f["theta"]) - degrees + 90) % 180 - 90) <= 5]
            modes.append((np.angle(np.mean([np.exp(2j * t) for t in members])) / 2) % math.pi)

    tables, label_to_table = [], {}
    for (label, centre, origin, window), f in zip(symbols, fits):
        ys, xs = np.nonzero(window)
        if sized(f):
            options, start, reach = [f["theta"]], f["centre"], 1.5
        else:
            options, start, reach = modes or [f["theta"]], centre, 5
        best = (-1, start[0], start[1], options[0])
        for option in options:
            for dy in np.arange(-reach, reach + 0.01, 0.5):
                for dx in np.arange(-reach, reach + 0.01, 0.5):
                    score = overlap(window, origin, start[0] + dx, start[1] + dy, long_side, short_side, option, ys, xs)
                    if score > best[0]:
                        best = (score, start[0] + dx, start[1] + dy, option)
        cx, cy, theta = best[1], best[2], best[3]
        outer = (long_side + OUTLINE_PX, short_side + OUTLINE_PX)
        corners = corners_of(cx, cy, outer[0], outer[1], theta)
        label_to_table[label] = len(tables)
        tables.append({"centre": (cx, cy), "size": outer, "angle": math.degrees(theta), "fit": sized(f),
                       "box": (corners[:, 0].min(), corners[:, 1].min(), corners[:, 0].max(), corners[:, 1].max())})
    owner = [label_to_table.get(l) for l in owner_label]
    return tables, owner


def entries(frame, tables, owner, chairs, chair_m, chair_sizes=None):
    """Build the tables list: each table followed by its chairs clockwise from the top, then the seats without a table.

    frame: converts pixels to metres (Frame.x / Frame.y / Frame.length). chair_sizes is an optional list of (w, h) in metres per chair,
    for plans whose chairs differ in size; otherwise every chair is chair_m square.
    """
    def r2(v):
        return round(float(v) + 0.0, 2)

    order = sorted(range(len(tables)), key=lambda i: (round(frame.y(tables[i]["centre"][1])), frame.x(tables[i]["centre"][0])))
    out = []
    for number, index in enumerate(order, 1):
        t = tables[index]
        x0, y0, x1, y1 = t["box"]
        long_side, short_side = t["size"]
        angle = t["angle"] % 180
        out.append({"kind": "table", "table": number, "cx": r2(frame.x(t["centre"][0])), "cy": r2(frame.y(t["centre"][1])),
                    "w": r2(frame.length(x1 - x0)), "h": r2(frame.length(y1 - y0)),
                    "rect": [r2(frame.length(long_side)), r2(frame.length(short_side))], "angle": r2(angle)})
        cx, cy = t["centre"]
        mine = [i for i, o in enumerate(owner) if o == index]
        mine.sort(key=lambda i: math.atan2(chairs[i][0] + chairs[i][2] / 2 - cx, -(chairs[i][1] + chairs[i][3] / 2 - cy)) % (2 * math.pi))
        for i in mine:
            x, y, w, h = chairs[i]
            cw, ch = chair_sizes[i] if chair_sizes else (chair_m, chair_m)
            out.append({"kind": "chair", "table": number, "cx": r2(frame.x(x + w / 2)), "cy": r2(frame.y(y + h / 2)), "w": cw, "h": ch})
    loose = sorted((i for i, o in enumerate(owner) if o is None),
                   key=lambda i: (round(frame.y(chairs[i][1] + chairs[i][3] / 2)), frame.x(chairs[i][0] + chairs[i][2] / 2)))
    for i in loose:
        x, y, w, h = chairs[i]
        cw, ch = chair_sizes[i] if chair_sizes else (chair_m, chair_m)
        out.append({"kind": "chair", "table": None, "cx": r2(frame.x(x + w / 2)), "cy": r2(frame.y(y + h / 2)), "w": cw, "h": ch})
    return out
