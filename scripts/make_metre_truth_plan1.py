"""Write data/plan1/truth.json in metres from the checked pixel truth (truth_px.json) and the layout image.

Scale: the 12 x 6 m stage measures 403 x 201 px outline to outline (33.6 px/m), the 3 x 3 m stage extension
101 px (33.7), and the 3 x 3 m booths repeat every 100.5 px (33.5). Run from the project root.
"""
import json
import sys

sys.path.insert(0, "scripts")
import metre_truth as mt

SCALE = 33.6
HALL_PX = (59, 80, 2289, 2209)  # inner faces of the outer walls: x0, y0, x1, y1
FRAME = mt.Frame(SCALE, HALL_PX[0], HALL_PX[1])
GROW = 1.5  # the tile boxes stop 1.5 px short of the divider on each side
FNB_CLASSES = set()  # the legend does not separate food from goods, so every booth is goods

old = json.load(open("data/plan1/truth_px.json"))["items"]
F = FRAME


def px_rect(box, grow=0.0):
    x, y, w, h = box
    return F.rect(x - grow, y - grow, x + w + grow, y + h + grow)


# ---- shell
hall = [F.pt(HALL_PX[0], HALL_PX[1]), F.pt(HALL_PX[2], HALL_PX[1]), F.pt(HALL_PX[2], HALL_PX[3]), F.pt(HALL_PX[0], HALL_PX[3])]
wall = F.rect(1283, 2209, 2106, 2225)
doors = [
    {"id": "Door A", "role": "exit", **F.rect(1473, 2205, 1535, 2229)},
    {"id": "Door B", "role": "entrance", **F.rect(1854, 2205, 1916, 2229)},
]
lobby = [F.pt(1288, 2225), F.pt(2101, 2225), F.pt(2101, 2822), F.pt(1350, 2822), F.pt(1288, 2762)]
outer_doors = [{"x": mt.r2(F.x(2101)), "y0": mt.r2(F.y(2507)), "y1": mt.r2(F.y(2575))},
               {"x": mt.r2(F.x(2101)), "y0": mt.r2(F.y(2679)), "y1": mt.r2(F.y(2747))}]
gates = [{"id": "Entrance", "sx": mt.r2(F.x(2101) - 0.5), "sy": mt.r2(F.y(2541))}]
exit_pt = {"id": "Exit", "sx": mt.r2(F.x(2101) - 0.5), "sy": mt.r2(F.y(2713))}

# ---- booths
booth_boxes, booth_meta, fixtures = [], [], []
for item in old:
    cls = item["class"]
    if cls.startswith(("Booth", "Large booth")):
        if item["id"] is None:
            fixtures.append({"label": "DOORPRIZE BOOTH", "kind": "fixture", **px_rect(item["box"], GROW)})
            continue
        booth_boxes.append(px_rect(item["box"], GROW))
        booth_meta.append(item["id"])
    elif cls == "Blocked":
        fixtures.append({"label": "BLOCKED", "kind": "fixture", **px_rect(item["box"], GROW)})
    elif cls == "object" and item.get("label") == "decor":
        fixtures.append({"label": "DECOR", "kind": "fixture", **px_rect(item["box"])})
fixtures.append({"label": "ENTRANCE", "kind": "fixture", **F.rect(1753, 2266, 2065, 2585)})
fixtures.append({"label": "STAGE EXT", "kind": "stage", **F.rect(740, 1845, 842, 1946)})

snapped = mt.snap_rects(booth_boxes + [{k: v for k, v in f.items() if k in ("x0", "x1", "y0", "y1")} for f in fixtures[:-2]])
booths = []
for index, booth_id in enumerate(booth_meta):
    kind = "fnb" if booth_id.rstrip("0123456789") in FNB_CLASSES else "goods"
    booths.append(mt.booth_entry(booth_id, kind, snapped[index]))
for offset, f in enumerate(fixtures[:-2]):
    f.update(snapped[len(booth_meta) + offset])
booths = mt.sort_reading_order(booths, lambda b: (b["cx"], b["cy"]))

# ---- tables: every chair is one entry (seats.json, checked by eye: 136 tables x 4 chairs + 2 audience grids of 100)
audience = next(i["box"] for i in old if i["class"] == "object" and i.get("label") == "audience_seating")
chairs = json.load(open("data/plan1/seats.json"))["items"]
chair_px = sorted(c["box"][2] for c in chairs)[len(chairs) // 2]
chair_m = mt.r2(chair_px / SCALE)  # the median chair is 9 to 10 px wide, a round seat of about 0.3 m
tables = [{"cx": mt.r2(F.x(x + w / 2)), "cy": mt.r2(F.y(y + h / 2)), "w": chair_m, "h": chair_m}
          for x, y, w, h in (c["box"] for c in chairs)]
tables = mt.sort_reading_order(tables, lambda t: (t["cx"], t["cy"]))
kids = F.rect(audience[0], audience[1], audience[0] + audience[2], audience[1] + audience[3])

# ---- stage, walls, pillars
stage = {**F.rect(589, 1945, 992, 2146), "face": "y0"}
T = 10  # drawn partitions are thin lines; the instructions ask for 0.25 to 0.35 m, 10 px is 0.3 m
pilasters = [
    {"kind": "wall", **F.rect(1711, 2225, 1721, 2630)},    # entrance vestibule, west side
    {"kind": "wall", **F.rect(1711, 2620, 2101, 2630)},    # entrance vestibule, south side
    {"kind": "wall", **F.rect(515, 1559, 525, 1943)},      # seating enclosure, west
    {"kind": "wall", **F.rect(515, 1559, 1055, 1569)},     # seating enclosure, north
    {"kind": "wall", **F.rect(1045, 1559, 1055, 1805)},    # seating enclosure, east
]
square_centres = [(53, y + 10) for y in (331, 600, 868, 1136, 1404, 1672, 1940)]
square_centres += [(2295, y + 10) for y in (331, 600, 868, 1136, 1404, 1672, 1940)]
square_centres += [(x + 10, 73) for x in (278, 613, 948, 1283, 1617, 1952)]
square_centres += [(x + 10, 2217) for x in (613, 948, 1283)]
square_centres += [(2296, 74), (2296, 2217), (1607, 2203), (1782, 2203)]
half = 12 / SCALE  # drawn as 24 px (0.72 m) hollow squares on the wall line
for cx, cy in square_centres:
    pilasters.append({"kind": "block", **mt.rect_m(F.x(cx) - half, F.y(cy) - half, F.x(cx) + half, F.y(cy) + half)})

# ---- meta
world_w = max(p[0] for p in lobby + hall) + 1
world_h = max(p[1] for p in lobby + hall) + 1
truth = {
    "meta": {"name": "FLOOR PLAN 1", "sheet": "FLOOR", "world": {"w": mt.r2(world_w), "h": mt.r2(world_h)}, "note": ""},
    "hall": hall, "lobby": lobby, "wall": wall, "doors": doors, "gates": gates, "exitPt": exit_pt,
    "outerDoors": outer_doors, "booths": booths, "tables": tables, "stage": stage, "kids": kids,
    "pantia": [], "lobbyBlock": {"x0": 0, "x1": 0, "y0": 0, "y1": 0}, "columns": [],
    "pilasters": pilasters, "fixtures": fixtures, "arrows": [], "closed": [],
}
by_type, n_tables, n_walls = mt.counts(truth)
truth["meta"]["note"] = (
    f"Scale 33.6 px/m from the 6 x 12 m stage (403 x 201 px outline to outline), checked on the 3 x 3 m stage extension "
    f"(101 px) and 3 x 3 m booths (100.5 px pitch). Origin: hall inner top-left at (1,1). {by_type} (the legend has no food class, "
    f"so none is fnb); {n_tables} seats in tables (one entry per chair: 136 table symbols x 4 chairs = 544, plus 200 audience chairs; table cores are not listed); {n_walls} walls (door wall, 2 vestibule, 3 seating enclosure). "
    "Door A is the exit and Door B the entrance: Door B opens into the vestibule that holds the foyer entrance door, Door A into the open foyer that holds the foyer exit door. "
    "kids holds the two 10 x 10 audience chair grids (200 chairs). 27 hollow square wall pillars are pilasters of kind block. "
    "J1 to J4 and K1 to K10 stand in the lobby, outside the hall polygon, and are kept because they are drawn. "
    "The printed D6 appears twice (a D row and a C column). The DOORPRIZE BOOTH, 3 BLOCKED tiles, 4 DECOR boxes and the ENTRANCE box are fixtures; drop ENTRANCE if it is a walkable zone. "
    "Left out: the north bay doors, the west and east emergency doors (not on the door wall), the thin inner layout rectangle, the lobby walls (the lobby polygon edge is the wall), "
    "the EMERGENCY EXIT label. Hall polygon is the outer wall inner face."
)
mt.finish(truth, "plan1")
