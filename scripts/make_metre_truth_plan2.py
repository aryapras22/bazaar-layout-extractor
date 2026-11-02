"""Write data/plan2/truth.json in metres from the checked pixel truth (truth_px.json), seats.json and the layout image.

Scale: the plan prints no size. The booth pitch is 64 px (A, B, C rows), 51 px (F) and 126.5 px (I blocks).
Taking the I blocks as 5 x 5 m gives 25.3 px/m, A as 2.5 m gives 25.6 and F as 2 m gives 25.5; the swing doors
come out at 2.0 m and the hall at 67.3 x 63.3 m, the same as plan 1's hall. 25.6 px/m is used. Run from the project root.
"""
import json
import sys

sys.path.insert(0, "scripts")
import metre_truth as mt

SCALE = 25.6
HALL_PX = (17, 16, 1737, 1633)  # inner faces of the outer walls: x0, y0, x1, y1
F = mt.Frame(SCALE, HALL_PX[0], HALL_PX[1])
GROW = {"Booth A": 2, "Booth B": 2, "Booth C": 2, "Booth F": 3, "Interactive space I": 2.25}
FNB_CLASSES = set()  # the legend has no food class

old = json.load(open("data/plan2/truth_px.json"))["items"]

# ---- shell
hall = [F.pt(HALL_PX[0], HALL_PX[1]), F.pt(HALL_PX[2], HALL_PX[1]), F.pt(HALL_PX[2], HALL_PX[3]), F.pt(HALL_PX[0], HALL_PX[3])]
hall_bottom = hall[2][1]
wall = mt.rect_m(F.x(968), hall_bottom - 0.05, F.x(1585), hall_bottom - 0.05 + 0.48)
wall_mid = (wall["y0"] + wall["y1"]) / 2
half_door = 1.0
doors = [
    {"id": "Door A", "role": "exit", **mt.rect_m(F.x(1078) - half_door, wall_mid - 0.36, F.x(1078) + half_door, wall_mid + 0.36)},
    {"id": "Door B", "role": "entrance", **mt.rect_m(F.x(1425) - half_door, wall_mid - 0.36, F.x(1425) + half_door, wall_mid + 0.36)},
]
lobby_top = wall["y1"]
lobby = [[mt.r2(F.x(968)), lobby_top], [mt.r2(F.x(1585)), lobby_top], [mt.r2(F.x(1585)), mt.r2(F.y(2092))],
         [mt.r2(F.x(1018)), mt.r2(F.y(2092))], [mt.r2(F.x(968)), mt.r2(F.y(2045))]]
outer_doors = [{"x": mt.r2(F.x(1585)), "y0": mt.r2(F.y(1835)), "y1": mt.r2(F.y(1905))},
               {"x": mt.r2(F.x(1585)), "y0": mt.r2(F.y(1982)), "y1": mt.r2(F.y(2050))}]
gates = [{"id": "Entrance", "sx": mt.r2(F.x(1585) - 0.5), "sy": mt.r2(F.y(1870))}]
exit_pt = {"id": "Exit", "sx": mt.r2(F.x(1585) - 0.5), "sy": mt.r2(F.y(2016))}

# ---- booths and fixtures
boxes, ids, fixtures = [], [], []
for item in old:
    cls = item["class"]
    x, y, w, h = item["box"]
    g = GROW.get(cls, 0)
    rect = F.rect(x - g, y - g, x + w + g, y + h + g)
    if cls in GROW and item["id"]:
        boxes.append(rect)
        ids.append(item["id"])
    elif cls == "Unlabeled block":
        fixtures.append({"label": "UNLABELED BLOCK", "kind": "fixture", **rect})
snapped = mt.snap_rects(boxes + [{k: f[k] for k in ("x0", "x1", "y0", "y1")} for f in fixtures])
mt.resolve_overlaps(snapped)  # the C corner pairs are L shapes cut by a diagonal: the horizontal arm keeps the corner
booths = [mt.booth_entry(i, "fnb" if i.rstrip("0123456789") in FNB_CLASSES else "goods", snapped[n]) for n, i in enumerate(ids)]
for n, f in enumerate(fixtures):
    f.update(snapped[len(ids) + n])
booths = mt.sort_reading_order(booths, lambda b: (b["cx"], b["cy"]))

# ---- seats: every chair is one entry (26 tables x 4 chairs, checked by eye)
chairs = json.load(open("data/plan2/seats.json"))["items"]
chair_px = sorted(c["box"][2] for c in chairs)[len(chairs) // 2]
chair_m = mt.r2(chair_px / SCALE)
tables = mt.sort_reading_order(
    [{"cx": mt.r2(F.x(x + w / 2)), "cy": mt.r2(F.y(y + h / 2)), "w": chair_m, "h": chair_m} for x, y, w, h in (c["box"] for c in chairs)],
    lambda t: (t["cx"], t["cy"]))

# ---- walls: the entrance vestibule inside the lobby
T = 0.3
x_west = F.x(1170)
y_south = F.y(1957)
pilasters = [
    {"kind": "wall", **mt.rect_m(x_west - T / 2, lobby_top, x_west + T / 2, y_south + T / 2)},
    {"kind": "wall", **mt.rect_m(x_west - T / 2, y_south - T / 2, F.x(1585), y_south + T / 2)},
]

# ---- no stage, no audience block: stage is empty and kids is the 2 x 2 m corner box the instructions ask for
stage = {"x0": 0, "x1": 0, "y0": 0, "y1": 0, "face": "y1"}
kids = mt.rect_m(1.2, 1.2, 3.2, 3.2)

world = {"w": mt.r2(max(p[0] for p in lobby + hall) + 1), "h": mt.r2(max(p[1] for p in lobby + hall) + 1)}
truth = {
    "meta": {"name": "FLOOR PLAN 2", "sheet": "FLOOR", "world": world, "note": ""},
    "hall": hall, "lobby": lobby, "wall": wall, "doors": doors, "gates": gates, "exitPt": exit_pt,
    "outerDoors": outer_doors, "booths": booths, "tables": tables, "stage": stage, "kids": kids,
    "pantia": [], "lobbyBlock": {"x0": 0, "x1": 0, "y0": 0, "y1": 0}, "columns": [],
    "pilasters": pilasters, "fixtures": fixtures, "arrows": [], "closed": [],
}
by_type, n_tables, n_walls = mt.counts(truth)
truth["meta"]["note"] = (
    "Scale 25.6 px/m, an estimate: the plan prints no size. Booth pitch is 64 px for A, B and C, 51 px for F and 126.5 px for the I blocks; "
    "A as 2.5 m, F as 2 m and I as 5 x 5 m agree within 2%, the swing doors then measure 2.0 m and the hall 67.3 x 63.3 m like plan 1. "
    "Correct SCALE in scripts/make_metre_truth_plan2.py if the real booth size differs. Origin: hall inner top-left at (1,1). "
    f"{by_type} (I1 to I9 are the Interactive spaces, counted as goods; the legend has no food class); {n_tables} seats in tables (26 tables x 4 chairs, one entry per chair); "
    f"{n_walls} walls (door wall, 2 vestibule). Door A (OUT) is the exit and Door B (IN) the entrance, matching the printed OUT and IN. "
    "There is no stage, so stage is an empty rectangle, and no audience block, so kids is the 2 x 2 m corner box. "
    "The two red Unlabeled blocks are fixtures. Left out as unclear: two thin line stubs (one near B7 to B12, one L near F30), "
    "the small slanted wall near A4, each C corner pair (C1/C2 and so on) is an L cut by a diagonal and is traced as two rectangles, the horizontal arm keeping the corner square. Hall polygon is the outer wall inner face."
)
mt.finish(truth, "plan2")
