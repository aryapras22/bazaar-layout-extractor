"""Write data/plan5/truth.json in metres from the vector data in data/plan5/source.pdf.

Booths are the enclosed cells between divider lines that hold an ID label: filled booth shapes (any colour, white
ones included, closed from all their vertices) are painted at the layout.png zoom, every stroked line is drawn over
them in black, and each enclosed cell holding one distinct label (letters, digits, optional letter) is a booth.

Scale: the plan prints no size. Booth cells repeat every 27.3 px at zoom 5 (5.46 pt); taking that as 3 m gives
1.82 pt/m, which makes the swing doors 1.0 to 1.3 m wide. The assumption is flagged in meta.note; change SCALE_PT
if the real booth size differs. Run from the project root.
"""
import re
import sys

import cv2
import numpy as np
import pymupdf

sys.path.insert(0, "scripts")
import metre_truth as mt

CLIP = pymupdf.Rect(105, 70, 300, 495)
ZOOM = 5.0
PITCH_PX = 27.3
SCALE_PT = PITCH_PX / ZOOM / 3      # pt per metre
ID_PATTERN = re.compile(r"^([A-Z]{1,3})\d{1,3}[A-Z]?$")
MAX_BLOCK_AREA = 8000               # pt squared; larger shapes are zones or floors, not booths
LINE_PX = 3

page = pymupdf.open("data/plan5/source.pdf")[0]
drawings = page.get_drawings()
words = page.get_text("words")
width, height = round(CLIP.width * ZOOM), round(CLIP.height * ZOOM)


def px(point):
    return (round((point[0] - CLIP.x0) * ZOOM), round((point[1] - CLIP.y0) * ZOOM))


def polygon(drawing):
    items = drawing["items"]
    if len(items) == 1 and items[0][0] == "re":
        r = items[0][1]
        return [(r.x0, r.y0), (r.x1, r.y0), (r.x1, r.y1), (r.x0, r.y1)]
    if all(item[0] == "l" for item in items):
        return [(items[0][1].x, items[0][1].y)] + [(item[2].x, item[2].y) for item in items]
    return None


canvas = np.zeros((height, width), np.uint8)
strokes = []
for drawing in drawings:
    r, fill = drawing["rect"], drawing.get("fill")
    if not (r.x1 >= CLIP.x0 and r.x0 <= CLIP.x1 and r.y1 >= CLIP.y0 and r.y0 <= CLIP.y1):
        continue
    poly = polygon(drawing)
    if poly and r.width * r.height < MAX_BLOCK_AREA and (fill is None or max(fill) - min(fill) >= 0.2 or min(fill) > 0.95):
        cv2.fillPoly(canvas, [np.array([px(p) for p in poly], np.int32)], 255)
    if drawing.get("color") is not None:
        strokes.append(drawing)
for drawing in strokes:
    for item in drawing["items"]:
        if item[0] == "l":
            cv2.line(canvas, px(item[1]), px(item[2]), 0, LINE_PX)
        elif item[0] == "re":
            r = item[1]
            cv2.rectangle(canvas, px((r.x0, r.y0)), px((r.x1, r.y1)), 0, LINE_PX)
count, cells, stats, _ = cv2.connectedComponentsWithStats(canvas, connectivity=4)
owners = {}
for word in words:
    match = ID_PATTERN.match(word[4])
    box = pymupdf.Rect(word[:4])
    if not match or not box.intersects(CLIP):
        continue
    x, y = px(((box.x0 + box.x1) / 2, (box.y0 + box.y1) / 2))
    if 0 <= x < width and 0 <= y < height and cells[y, x] > 0:
        owners.setdefault(int(cells[y, x]), set()).add(word[4])
# booth cells whose label is outlined text, not in the PDF text layer: read by eye from layout.png
# (layout pixel x, y of the cell's top-left corner -> printed label; None means the cell prints no label)
MANUAL_LABELS = {(604, 320): "L41", (631, 320): "L44", (238, 1418): "C26", (265, 1418): "C27",
                 (158, 1494): "B20", (185, 1494): "B22", (345, 1502): None}
unlabeled_count = 0
for (mx, my), label in MANUAL_LABELS.items():
    cell = next(c for c in range(1, count) if abs(int(stats[c][0]) - mx) <= 3 and abs(int(stats[c][1]) - my) <= 3 and c not in owners)
    if label is None:
        unlabeled_count += 1
        label = f"U{unlabeled_count}"
    owners[cell] = {label}
crowded = {cell: sorted(texts) for cell, texts in owners.items() if len(texts) != 1}
assert not crowded, crowded

# ---- frame: pt, origin at the hall's top-left bounding corner
HALL_PT = [(132.1, 96.4), (274.5, 96.4), (274.5, 272.7), (192.0, 272.7), (192.0, 327.9), (207.5, 327.9),
           (207.5, 451.8), (123.6, 451.8), (123.6, 327.9), (165.5, 327.9), (165.5, 272.7), (132.1, 272.7)]
F = mt.Frame(SCALE_PT, min(p[0] for p in HALL_PT), min(p[1] for p in HALL_PT))
GROW_PX = (PITCH_PX - 22.2) / 2     # a cell stops short of the divider centre line on each side

rects, ids = [], []
for cell, texts in owners.items():
    x, y, w, h = (int(v) for v in stats[cell][:4])
    x0, y0 = CLIP.x0 + (x - GROW_PX) / ZOOM, CLIP.y0 + (y - GROW_PX) / ZOOM
    x1, y1 = CLIP.x0 + (x + w + GROW_PX) / ZOOM, CLIP.y0 + (y + h + GROW_PX) / ZOOM
    rects.append(mt.rect_m(F.x(x0), F.y(y0), F.x(x1), F.y(y1)))
    ids.append(next(iter(texts)))
snapped = mt.snap_rects(rects, tol=0.15)
mt.resolve_overlaps(snapped)
booths = mt.sort_reading_order([mt.booth_entry(i, "goods", snapped[n]) for n, i in enumerate(ids)], lambda b: (b["cx"], b["cy"]))

# ---- shell: Hall B and the pre-function strip, the connecting corridor, Hall A. Entrance wall: Hall A's south wall.
hall = [F.pt(*p) for p in HALL_PT]
bottom = hall[6][1]
wall = mt.rect_m(F.x(123.6), bottom - 0.05, F.x(207.5), bottom - 0.05 + 0.48)
wall_mid = (wall["y0"] + wall["y1"]) / 2
openings = [("Door A", "exit", 138.8, 142.7), ("Door B", "entrance", 145.1, 149.0),
            ("Door C", "entrance", 179.6, 183.5), ("Door D", "exit", 185.9, 189.7)]
doors = [{"id": i, "role": role, **mt.rect_m(F.x(x0), wall_mid - 0.36, F.x(x1), wall_mid + 0.36)} for i, role, x0, x1 in openings]
lobby_top, lobby_bottom = wall["y1"], mt.r2(F.y(472.5))
lobby = [[mt.r2(F.x(123.6)), lobby_top], [mt.r2(F.x(207.5)), lobby_top], [mt.r2(F.x(207.5)), lobby_bottom], [mt.r2(F.x(123.6)), lobby_bottom]]
gates = [{"id": "Entrance", "sx": mt.r2(F.x(182.0)), "sy": mt.r2(F.y(463.0))}]  # tail of the green IN arrow
exit_pt = {"id": "Exit", "sx": mt.r2(F.x(140.5)), "sy": mt.r2(F.y(463.0))}      # head of the red OUT arrow

# ---- no stage, no seats, no audience block: empty stage, kids is a 2 x 2 m box in a free corner
stage = {"x0": 0, "x1": 0, "y0": 0, "y1": 0, "face": "y1"}
kids = None
for vx, vy, dx, dy in ((hall[7][0], hall[7][1], 1, -1), (hall[0][0], hall[0][1], 1, 1), (hall[1][0], hall[1][1], -1, 1)):
    for step in range(0, 12):
        x0 = vx + 0.2 if dx > 0 else vx - 2.2
        y0 = vy - 2.2 - step * 0.5 if dy < 0 else vy + 0.2 + step * 0.5
        candidate = mt.rect_m(x0, y0, x0 + 2, y0 + 2)
        if all(not (mt.overlap(candidate, b)[0] > 0 and mt.overlap(candidate, b)[1] > 0) for b in booths):
            kids = candidate
            break
    if kids:
        break

world = {"w": mt.r2(max(p[0] for p in lobby + hall) + 1), "h": mt.r2(max(p[1] for p in lobby + hall) + 1)}
truth = {
    "meta": {"name": "FLOOR PLAN 5", "sheet": "FLOOR", "world": world, "note": ""},
    "hall": hall, "lobby": lobby, "wall": wall, "doors": doors, "gates": gates, "exitPt": exit_pt,
    "outerDoors": [], "booths": booths, "tables": [], "stage": stage, "kids": kids,
    "pantia": [], "lobbyBlock": {"x0": 0, "x1": 0, "y0": 0, "y1": 0}, "columns": [],
    "pilasters": [], "fixtures": [], "arrows": [], "closed": [],
}
by_type, n_tables, n_walls = mt.counts(truth)
truth["meta"]["note"] = (
    "Scale 1.82 pt/m (9.1 px/m on layout.png), an estimate: the plan prints no size. Booth cells repeat every 5.46 pt; taken as 3 m the swing doors measure 1.0 to 1.3 m. "
    "Correct SCALE_PT in scripts/make_metre_truth_plan5.py if the real booth size differs. Coordinates come from the PDF vector data. Origin: hall bounding top-left at (1,1). "
    f"{by_type} (the colour legend names countries, not food, so none is fnb; 299 cells labelled in the PDF text, H03, D28 and J20 are printed twice inside one cell; L41, L44, C26, C27, B20 and B22 print their label as outlines and were read by eye; U1 is the unlabeled cell right of D22); no seats are drawn, tables is empty; {n_walls} wall (the south wall of Hall A). "
    "The hall polygon joins Hall B with the pre-function strip, the connecting corridor and Hall A, drawn from the wall lines; the octagon room, the toilet and office blocks and the room block east of the corridor are outside it. "
    "Door A to D are the four double doors in the two gaps of Hall A's south wall: the red OUT arrows mark A and D (exit), the green IN arrows B and C (entrance). "
    "The lobby is the 11 m band below the wall, cut at the office row; gates sit at the tail of the green arrow at Door C, exitPt at the head of the red arrow at Door A. "
    "There is no stage and no audience block drawn (the rounded seminar zone in Hall B is unlabelled and left out), so stage is empty and kids is a 2 x 2 m corner box. "
    "Left out: pillars, office and VIP room partitions along the west of Hall B (as thin as booth dividers), icons, the F&B counters 1 to 5, WANINDO, the other doors, the legend."
)
mt.finish(truth, "plan5", {"px_per_m": SCALE_PT * ZOOM, "origin_px": [(F.ox - CLIP.x0) * ZOOM, (F.oy - CLIP.y0) * ZOOM]})
