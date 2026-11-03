"""Write data/plan3/truth.json in metres from the checked pixel truth (truth_px.json), seats.json and the layout image.

Scale: the plan prints dimensions. The stage is 3 x 8.25 m and measures 101 x 274 px outline to outline (33.7 and
33.2 px/m); the H booths are 2 m and repeat every 67 px (33.5). 33.5 px/m is used. Run from the project root.

The plan has no outer wall and no door wall. The only entrance feature is the red GATE bar at the end of the 4 m
aisle, so the GATE line is taken as the door wall: the hall ends at the gate line, the strip east of it (about 8 m
deep, the instructions' fallback depth) is the lobby, and the wall is the gate line over the full height.
"""
import json
import sys

import numpy as np
from PIL import Image
from scipy import ndimage as ndi

sys.path.insert(0, "scripts")
import metre_truth as mt

SCALE = 33.5
HALL_PX = (24, 23, 3391, 964)  # outer edge of the plan, x0, y0, x1, y1
GATE_X0, GATE_X1, GATE_Y0, GATE_Y1 = 3117, 3134, 460, 580
F = mt.Frame(SCALE, HALL_PX[0], HALL_PX[1])
CELL = 4          # px per cell when cutting the tenant spaces into rectangles
MIN_RECT_M2 = 2.0  # leftover slivers smaller than this are not kept

old = json.load(open("data/plan3/truth_px.json"))["items"]
layout = np.array(Image.open("data/plan3/layout.png").convert("RGB")).astype(int)

# ---- shell
hall = [F.pt(HALL_PX[0], HALL_PX[1]), F.pt(GATE_X0, HALL_PX[1]), F.pt(GATE_X0, HALL_PX[3]), F.pt(HALL_PX[0], HALL_PX[3])]
wall = F.rect(GATE_X0, HALL_PX[1], GATE_X1, HALL_PX[3])
centre_x = (GATE_X0 + GATE_X1) / 2
doors = [{"id": "Door A", "role": "both", **mt.rect_m(F.x(centre_x) - 0.36, F.y(GATE_Y0), F.x(centre_x) + 0.36, F.y(GATE_Y1))}]
lobby = [F.pt(GATE_X1, HALL_PX[1]), F.pt(HALL_PX[2], HALL_PX[1]), F.pt(HALL_PX[2], HALL_PX[3]), F.pt(GATE_X1, HALL_PX[3])]
mid_y = (GATE_Y0 + GATE_Y1) / 2
gates = [{"id": "Entrance", "sx": mt.r2(F.x(3225)), "sy": mt.r2(F.y(mid_y - 84))}]
exit_pt = {"id": "Exit", "sx": mt.r2(F.x(3225)), "sy": mt.r2(F.y(mid_y + 84))}

# ---- booths
boxes, ids = [], []
for item in old:
    if item["class"] == "Booth H":
        x, y, w, h = item["box"]
        boxes.append(F.rect(x - 0.5, y - 0.5, x + w + 0.5, y + h + 0.5))
        ids.append(item["id"])
snapped = mt.snap_rects(boxes)
booths = mt.sort_reading_order([mt.booth_entry(i, "goods", snapped[n]) for n, i in enumerate(ids)], lambda b: (b["cx"], b["cy"]))

# ---- seats: 9 tables x 4 chairs from seats.json, and the 55 audience cells (5 columns of 11) found in the image
chairs = json.load(open("data/plan3/seats.json"))["items"]
chair_px = sorted(c["box"][2] for c in chairs)[len(chairs) // 2]
seats = [{"cx": mt.r2(F.x(x + w / 2)), "cy": mt.r2(F.y(y + h / 2)), "w": mt.r2(chair_px / SCALE), "h": mt.r2(chair_px / SCALE)}
         for x, y, w, h in (c["box"] for c in chairs)]
sub = layout[418:608, 468:618]
blue = (sub[:, :, 2] > 180) & (sub[:, :, 0] < 150) & (sub[:, :, 1] > 130) & (sub[:, :, 1] < 190)
labels, _ = ndi.label(blue)
cells = []
for index, sl in enumerate(ndi.find_objects(labels), 1):
    w, h = sl[1].stop - sl[1].start, sl[0].stop - sl[0].start
    if w >= 8 and h >= 12:
        cells.append((sl[1].start + 468, sl[0].start + 418, w, h))
assert len(cells) == 55, len(cells)
for x, y, w, h in cells:
    seats.append({"cx": mt.r2(F.x(x + w / 2)), "cy": mt.r2(F.y(y + h / 2)), "w": mt.r2(13 / SCALE), "h": mt.r2(14 / SCALE)})
tables = mt.sort_reading_order(seats, lambda t: (t["cx"], t["cy"]))
audience = next(i["box"] for i in old if i.get("label") == "audience_seating_block")
kids = F.rect(audience[0], audience[1], audience[0] + audience[2], audience[1] + audience[3])

# ---- stage
stage = {**F.rect(270, 364, 371, 638), "face": "x1"}

# ---- column squares (black, 33 x 34 px = 1 m) from the checked list
pilasters = []
for item in old:
    if item["class"] == "pillar":
        x, y, w, h = item["box"]
        cx, cy = F.x(x + w / 2), F.y(y + h / 2)
        pilasters.append({"kind": "block", **mt.rect_m(cx - 0.5, cy - 0.5, cx + 0.5, cy + 0.5)})
pilasters = mt.sort_reading_order(pilasters, lambda p: ((p["x0"] + p["x1"]) / 2, (p["y0"] + p["y1"]) / 2))

# ---- fixtures: escalator and the tenant spaces cut into inscribed axis-aligned rectangles
fixtures = []
stairs = next(i["box"] for i in old if i.get("label") == "stairs")
fixtures.append({"label": "ESCALATOR", "kind": "fixture", **F.rect(stairs[0], stairs[1], stairs[0] + stairs[2], stairs[1] + stairs[3])})


def largest_rectangle(grid):
    """Largest all-true axis-aligned rectangle in a boolean matrix: (area, row0, col0, row1, col1)."""
    best = (0, 0, 0, 0, 0)
    heights = np.zeros(grid.shape[1], int)
    for row in range(grid.shape[0]):
        heights = np.where(grid[row], heights + 1, 0)
        stack = []
        for col in range(grid.shape[1] + 1):
            h = heights[col] if col < grid.shape[1] else 0
            start = col
            while stack and stack[-1][1] >= h:
                s, sh = stack.pop()
                area = sh * (col - s)
                if area > best[0]:
                    best = (area, row - sh + 1, s, row + 1, col)
                start = s
            stack.append((start, h))
    return best


tenant_colour = layout[100, 300]
mask = (abs(layout - tenant_colour).max(axis=2) < 8)
mask = ndi.binary_dilation(mask, iterations=2)
mask = ndi.binary_closing(mask, structure=np.ones((9, 9)))
rows, cols = (mask.shape[0] // CELL) * CELL, (mask.shape[1] // CELL) * CELL
grid = mask[:rows, :cols].reshape(rows // CELL, CELL, cols // CELL, CELL).mean(axis=(1, 3)) > 0.95
min_cells = MIN_RECT_M2 * (SCALE / CELL) ** 2
tenant_rects = []
while True:
    area, r0, c0, r1, c1 = largest_rectangle(grid)
    if area < min_cells:
        break
    grid[r0:r1, c0:c1] = False
    tenant_rects.append((c0 * CELL, r0 * CELL, c1 * CELL, r1 * CELL))
for x0, y0, x1, y1 in sorted(tenant_rects, key=lambda r: (round(r[1] / 100), r[0])):
    fixtures.append({"label": "TENANT SPACE", "kind": "fixture", **F.rect(x0, y0, x1, y1)})

world = {"w": mt.r2(max(p[0] for p in lobby + hall) + 1), "h": mt.r2(max(p[1] for p in lobby + hall) + 1)}
truth = {
    "meta": {"name": "FLOOR PLAN 3", "sheet": "FLOOR", "world": world, "note": ""},
    "hall": hall, "lobby": lobby, "wall": wall, "doors": doors, "gates": gates, "exitPt": exit_pt,
    "outerDoors": [], "booths": booths, "tables": tables, "stage": stage, "kids": kids,
    "pantia": [], "lobbyBlock": {"x0": 0, "x1": 0, "y0": 0, "y1": 0}, "columns": [],
    "pilasters": pilasters, "fixtures": fixtures, "arrows": [], "closed": [],
}
by_type, n_tables, n_walls = mt.counts(truth)
truth["meta"]["note"] = (
    "Scale 33.5 px/m from the printed 3 x 8.25 m stage (101 x 274 px outline to outline), checked on the printed 2 m H booths (67 px pitch). "
    f"Origin: plan top-left at (1,1). {by_type} (H1 to H86 with 19 numbers not printed); {n_tables} seats in tables "
    "(9 tables x 4 chairs = 36, plus the 55 audience cells of the 5 x 11 block); 31 square columns of 1 m as pilasters of kind block; "
    f"{n_walls} wall. The plan draws no outer wall, door wall or lobby. The red GATE bar at the end of the 4 m aisle is the only entrance feature, "
    "so the hall ends at the GATE line, the wall is that line over the full height (0.5 m, as thick as the drawn bar), the one door is the 3.6 m GATE with role both, "
    "and the lobby is the 7.7 m strip east of it. Real floor continues around the bar; that is a simplification. Gates and exitPt sit 5 m apart in the lobby on free floor, "
    "not at the east edge because a curved tenant space fills it. Tenant spaces and the escalator are fixtures; slanted tenant edges are cut into inscribed rectangles, "
    f"{len(tenant_rects)} of them, so thin slivers along slanted edges stay open. The stage faces x1 where the audience block stands; kids is that block. "
    "Left out: dimension arrows, the dashed stage surround, the red and green dashed circles at the gate, the 'MR. DIY' and 'PRODESIGN' text."
)
mt.finish(truth, "plan3", {"px_per_m": SCALE, "origin_px": [HALL_PX[0], HALL_PX[1]]})
