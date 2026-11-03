"""Write data/plan6/truth.json in metres from the vector data in data/plan6/source.pdf.

Scale: the plan prints its sizes. The 3 m labels sit on 15.5 pt booths (5.17 pt/m), the stage area is printed
24 x 14 m and measures 124 x 72 pt, the stage is printed 6 x 10 m and measures 31.6 x 51.5 pt, the workshop is
printed 12 x 8 m. All agree on 5.167 pt/m (20.67 px/m on layout.png). Everything below works in PDF points and is
converted once. Run from the project root.
"""
import re
import sys

import pymupdf

sys.path.insert(0, "scripts")
import metre_truth as mt

SCALE = 15.5 / 3  # pt per metre
CLIP_ORIGIN, ZOOM = (20, 60), 4.0  # layout.png is the PDF clipped at (20, 60) and drawn at zoom 4
HALL_PT = (25.8, 148.8, 582.4, 612.6)
F = mt.Frame(SCALE, HALL_PT[0], HALL_PT[1])
page = pymupdf.open("data/plan6/source.pdf")[0]
words = page.get_text("words")
drawings = page.get_drawings()
HALL = pymupdf.Rect(*HALL_PT)
ID_PATTERN = re.compile(r"^([A-Z]{1,3})\d{1,3}$")
ZONE_PREFIX = {(1.0, 0.2, 0.8): "B", (0.0, 0.69, 0.94): "W", (0.44, 0.19, 0.63): "F", (1.0, 1.0, 0.0): "M", (0.57, 0.82, 0.31): "S"}
ZONES = [(pymupdf.Rect(d["rect"]), ZONE_PREFIX[tuple(round(c, 2) for c in d["fill"])]) for d in drawings
         if d.get("fill") and tuple(round(c, 2) for c in d["fill"]) in ZONE_PREFIX and d["rect"].width > 100]


def centre(rect):
    return pymupdf.Point((rect.x0 + rect.x1) / 2, (rect.y0 + rect.y1) / 2)


def mrect(rect):
    return mt.rect_m(F.x(rect.x0), F.y(rect.y0), F.x(rect.x1), F.y(rect.y1))


def words_in(rect):
    return [w[4] for w in words if rect.contains(centre(pymupdf.Rect(w[:4])))]


# ---- booths: white and black rectangles holding one ID label
labels = [(pymupdf.Rect(w[:4]), w[4]) for w in words if ID_PATTERN.match(w[4])]
rects = {}
for d in drawings:
    fill, r = d.get("fill"), d["rect"]
    if fill is None or tuple(fill) not in {(1.0, 1.0, 1.0), (0.0, 0.0, 0.0)} or not (6 < r.width < 90 and 6 < r.height < 90) or not r.intersects(HALL):
        continue
    rects[(round(r.x0, 1), round(r.y0, 1), round(r.x1, 1), round(r.y1, 1))] = r
booth_rects, booth_ids, resolved = [], [], []
for key, r in sorted(rects.items()):
    inside = [t for b, t in labels if r.contains(centre(b))]
    if len(inside) == 2:  # a stray hidden label shares the rectangle: keep the one that matches the zone prefix
        prefix = next((p for z, p in ZONES if z.contains(centre(r))), None)
        match = [t for t in inside if t.startswith(prefix or "?") and ID_PATTERN.match(t).group(1) == prefix]
        resolved.append((inside, match))
        inside = match[:1]
    if len(inside) == 1:
        booth_rects.append(mrect(r))
        booth_ids.append(inside[0])

# named boxes: orange exhibitors are booths, FITTING ROOM is a fit booth, COFFEE SHOP an fnb booth; the other peach
# FACILITIES boxes are fixtures
fixtures, named = [], []
for d in drawings:
    fill, r = d.get("fill"), d["rect"]
    if not fill or not r.intersects(HALL) or r.width < 6 or r.height < 6 or r.width * r.height > 9000:
        continue
    colour = tuple(round(c, 2) for c in fill)
    if colour not in {(0.98, 0.77, 0.6), (0.92, 0.44, 0.05)}:
        continue
    text = " ".join(words_in(r))
    text = re.sub(r"\b\d+ m\b", "", text).strip()
    named.append((round(r.x0, 1), round(r.y0, 1), colour, text, r))
seen, unlabeled = set(), []
for x, y, colour, text, r in sorted(named, key=lambda n: (n[1], n[0])):
    if (x, y) in seen:
        continue
    seen.add((x, y))
    if colour == (0.92, 0.44, 0.05):
        unlabeled.append((mrect(r), "goods", text))
    elif text == "FITTING ROOM":
        unlabeled.append((mrect(r), "fit", text))
    elif text == "COFFEE SHOP":
        unlabeled.append((mrect(r), "fnb", text))
    else:
        fixtures.append({"label": text.upper(), "kind": "fixture", **mrect(r)})

all_rects = booth_rects + [u[0] for u in unlabeled] + [{k: f[k] for k in ("x0", "x1", "y0", "y1")} for f in fixtures]
snapped = mt.snap_rects(all_rects, tol=0.1)
mt.resolve_overlaps(snapped)
booths = []
for n, booth_id in enumerate(booth_ids):
    prefix = ID_PATTERN.match(booth_id).group(1)
    booths.append(mt.booth_entry(booth_id, "fnb" if prefix == "S" else "goods", snapped[n]))
for n, (rect, kind, text) in enumerate(unlabeled):
    booths.append(mt.booth_entry(f"U{n + 1}", kind, snapped[len(booth_ids) + n]))
for n, f in enumerate(fixtures):
    f.update(snapped[len(booth_ids) + len(unlabeled) + n])
booths = mt.sort_reading_order(booths, lambda b: (b["cx"], b["cy"]))
unlabeled_names = {f"U{n + 1}": text for n, (_, _, text) in enumerate(unlabeled)}

# ---- stage, audience area
stage = {**mt.rect_m(F.x(51.3), F.y(175.5), F.x(82.9), F.y(227.0)), "face": "x1"}
area = next(pymupdf.Rect(d["rect"]) for d in drawings if 123 < d["rect"].width < 126 and 70 < d["rect"].height < 74 and d.get("fill") is None)
kids = mrect(area)

# ---- seats: the benches of the picnic sets in the FNB zone (the table between each pair of benches is not listed)
bench_keys, seats = set(), []
for d in drawings:
    fill, r = d.get("fill"), d["rect"]
    if fill and tuple(round(c, 2) for c in fill) == (0.8, 0.4, 0.0) and 1.5 < r.height < 2.1 and 7 < r.width < 9 and r.intersects(HALL):
        key = (round(r.x0, 1), round(r.y0, 1))
        if key in bench_keys:
            continue
        bench_keys.add(key)
        seats.append({"cx": mt.r2(F.x((r.x0 + r.x1) / 2)), "cy": mt.r2(F.y((r.y0 + r.y1) / 2)),
                      "w": mt.r2(r.width / SCALE), "h": mt.r2(r.height / SCALE)})
tables = mt.sort_reading_order(seats, lambda t: (t["cx"], t["cy"]))

# ---- columns and pilasters: black 1 m squares on the top and bottom wall lines, 4 round black dots
pilasters, columns, square_keys = [], [], set()
for d in drawings:
    fill, r = d.get("fill"), d["rect"]
    if not fill or tuple(fill) != (0.0, 0.0, 0.0) or not (4.5 < r.width < 6 and 4.5 < r.height < 6):
        continue
    if not (r.x0 > HALL_PT[0] and r.x1 < HALL_PT[2] and HALL_PT[1] - 6 < r.y0 < HALL_PT[3] + 6):
        continue
    key = (round(r.x0, 1), round(r.y0, 1))
    if key in square_keys:
        continue
    square_keys.add(key)
    if d["items"][0][0] == "c":
        columns.append({"x": mt.r2(F.x((r.x0 + r.x1) / 2)), "y": mt.r2(F.y((r.y0 + r.y1) / 2)), "d": mt.r2(r.width / SCALE)})
    else:
        pilasters.append({"kind": "block", **mrect(r)})
pilasters = mt.sort_reading_order(pilasters, lambda p: ((p["x0"] + p["x1"]) / 2, (p["y0"] + p["y1"]) / 2))

# ---- shell: the south wall holds four door openings (two OUT, two IN), each about 5.5 m, split by 1 m columns
hall = [F.pt(HALL_PT[0], HALL_PT[1]), F.pt(HALL_PT[2], HALL_PT[1]), F.pt(HALL_PT[2], HALL_PT[3]), F.pt(HALL_PT[0], HALL_PT[3])]
bottom = hall[2][1]
wall = mt.rect_m(F.x(HALL_PT[0]), bottom - 0.05, F.x(HALL_PT[2]), bottom - 0.05 + 0.48)
wall_mid = (wall["y0"] + wall["y1"]) / 2
openings = [(134.1, 162.4, "exit"), (167.6, 195.9, "exit"), (412.4, 440.7, "entrance"), (445.9, 474.2, "entrance")]
doors = [{"id": f"Door {chr(65 + n)}", "role": role, **mt.rect_m(F.x(x0), wall_mid - 0.36, F.x(x1), wall_mid + 0.36)}
         for n, (x0, x1, role) in enumerate(openings)]
band_bottom, foyer_bottom = 643.3, 688.0
y_top, y_band, y_end = wall["y1"], mt.r2(F.y(band_bottom)), mt.r2(F.y(foyer_bottom))
lobby = [[mt.r2(F.x(134.1)), y_top], [mt.r2(F.x(195.9)), y_top], [mt.r2(F.x(195.9)), y_band], [mt.r2(F.x(412.4)), y_band],
         [mt.r2(F.x(412.4)), y_top], [mt.r2(F.x(474.2)), y_top], [mt.r2(F.x(474.2)), y_band], [mt.r2(F.x(HALL_PT[2])), y_band],
         [mt.r2(F.x(HALL_PT[2])), y_end], [mt.r2(F.x(HALL_PT[0])), y_end], [mt.r2(F.x(HALL_PT[0])), y_band], [mt.r2(F.x(134.1)), y_band]]
gates = [{"id": "Entrance", "sx": mt.r2(F.x(428.5)), "sy": mt.r2(F.y(649))}]   # tail of the first IN arrow
exit_pt = {"id": "Exit", "sx": mt.r2(F.x(151.5)), "sy": mt.r2(F.y(652))}      # head of the first OUT arrow

world = {"w": mt.r2(max(p[0] for p in lobby + hall) + 1), "h": mt.r2(max(p[1] for p in lobby + hall) + 1)}
truth = {
    "meta": {"name": "FLOOR PLAN 6", "sheet": "FLOOR", "world": world, "note": ""},
    "hall": hall, "lobby": lobby, "wall": wall, "doors": doors, "gates": gates, "exitPt": exit_pt,
    "outerDoors": [], "booths": booths, "tables": tables, "stage": stage, "kids": kids,
    "pantia": [], "lobbyBlock": {"x0": 0, "x1": 0, "y0": 0, "y1": 0}, "columns": columns,
    "pilasters": pilasters, "fixtures": fixtures, "arrows": [], "closed": [],
}
by_type, n_tables, n_walls = mt.counts(truth)
truth["meta"]["note"] = (
    "Scale 5.167 pt/m (20.67 px/m on layout.png) from the printed 24 x 14 m stage area (124 x 72 pt) and 6 x 10 m stage, checked on the printed 3 m booths (15.5 pt) and the 12 x 8 m workshop. "
    "Coordinates come from the PDF vector data. Origin: hall top-left at (1,1). "
    f"{by_type} (S1 to S15 in the FNB zone are fnb; U-ids are booths with no printed ID: "
    + ", ".join(f"{k} {v}" for k, v in sorted(unlabeled_names.items(), key=lambda kv: int(kv[0][1:]))) + "); "
    f"{n_tables} seats in tables (picnic-set benches in the FNB zone, 2 per set; the table between them is not listed); {n_walls} wall (the south wall; the hall has no other drawn partition). "
    "Sponsor booths with a printed ID are booths. B38 and B39 are printed twice (beauty zone and mom and baby zone). "
    "Two rectangles hold a hidden second label; the one matching the zone prefix is used (B75 not A59, M21 not D78). "
    "The south wall opens in two 12 m gaps, each split by a 1 m column into two doors of about 5.5 m: the left two carry the OUT arrows (exit), the right two the IN arrows (entrance). "
    "The lobby is the two passages through the room band plus the foyer, cut at the image edge. Gates sit at the tail of the first IN arrow and exitPt at the head of the first OUT arrow. "
    f"The peach FACILITIES boxes are fixtures ({len(fixtures)}); the 4 round black dots are columns of d 1 m; the 22 black squares on the top and bottom wall lines are block pilasters. "
    "Left out: doors on the north wall, the red-brown and grey zone fills around the stage, the thick line along the stage area, the toilet and cafe rooms south of the wall, "
    "the foyer items (sustainability corner, donation box, ambience installation, peach bars), and the objects outside the east wall (giant maps)."
)
mt.finish(truth, "plan6", {"px_per_m": SCALE * ZOOM, "origin_px": [(HALL_PT[0] - CLIP_ORIGIN[0]) * ZOOM, (HALL_PT[1] - CLIP_ORIGIN[1]) * ZOOM]})
if resolved:
    print("  resolved double labels:", resolved)
