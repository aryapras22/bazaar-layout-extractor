"""Draw data/planN/truth.json (metres) to a PNG so it can be compared with layout.png by eye.

Usage: python3 scripts/render_metre_truth.py data/plan1/truth.json out.png [pixels_per_metre]
Hall is pale yellow, lobby pale blue, booths green (goods) or orange (fnb), tables blue, walls black,
fixtures grey, closed zones red hatch, kids lilac, stage dark red. Doors are drawn magenta.
"""
import json
import sys

from PIL import Image, ImageDraw

path, out = sys.argv[1], sys.argv[2]
ppm = float(sys.argv[3]) if len(sys.argv) > 3 else 12
t = json.load(open(path))
W, H = t["meta"]["world"]["w"], t["meta"]["world"]["h"]
img = Image.new("RGB", (int(W * ppm), int(H * ppm)), "white")
d = ImageDraw.Draw(img)


def P(x, y):
    return (x * ppm, y * ppm)


def R(item, fill=None, outline=None, width=1):
    if "cx" in item:
        x0, x1, y0, y1 = item["cx"] - item["w"] / 2, item["cx"] + item["w"] / 2, item["cy"] - item["h"] / 2, item["cy"] + item["h"] / 2
    else:
        x0, x1, y0, y1 = item["x0"], item["x1"], item["y0"], item["y1"]
    d.rectangle([P(x0, y0), P(x1, y1)], fill=fill, outline=outline, width=width)


d.polygon([P(*p) for p in t["hall"]], fill=(255, 249, 214), outline=(120, 120, 120))
d.polygon([P(*p) for p in t["lobby"]], fill=(222, 238, 252), outline=(120, 120, 120))
for c in t["closed"]:
    R(c, fill=(250, 200, 200), outline=(200, 0, 0))
R(t["kids"], fill=(225, 215, 250), outline=(120, 90, 200))
R(t["stage"], fill=(170, 80, 80), outline=(90, 0, 0))
for f in t["fixtures"]:
    R(f, fill=(190, 190, 190), outline=(60, 60, 60))
    d.text(P(f["x0"] + 0.1, f["y0"] + 0.1), f["label"][:12], fill=(0, 0, 0))
for b in t["booths"]:
    R(b, fill=(150, 215, 150) if b["type"] == "goods" else (250, 180, 90) if b["type"] == "fnb" else (200, 170, 230), outline=(30, 90, 30))
    d.text(P(b["cx"] - b["w"] / 2 + 0.1, b["cy"] - 0.3), b["id"], fill=(0, 0, 0))
import math
for tb in t["tables"]:
    if tb["kind"] == "table":
        long_side, short_side = tb["rect"]
        a = math.radians(tb["angle"])
        u, v = (math.cos(a), math.sin(a)), (-math.sin(a), math.cos(a))
        pts = [P(tb["cx"] + sx * long_side / 2 * u[0] + sy * short_side / 2 * v[0], tb["cy"] + sx * long_side / 2 * u[1] + sy * short_side / 2 * v[1])
               for sx, sy in ((-1, -1), (1, -1), (1, 1), (-1, 1))]
        d.polygon(pts, fill=(200, 220, 250), outline=(0, 0, 120))
    else:
        R(tb, fill=(250, 190, 110), outline=(120, 60, 0))
for p in t["pilasters"]:
    R(p, fill=(0, 0, 0))
for c in t["columns"]:
    d.ellipse([P(c["x"] - c["d"] / 2, c["y"] - c["d"] / 2), P(c["x"] + c["d"] / 2, c["y"] + c["d"] / 2)], fill=(0, 0, 0))
R(t["wall"], fill=(0, 0, 0))
for door in t["doors"]:
    R(door, fill=(230, 60, 200))
    d.text(P(door["x0"], door["y0"] - 0.8), door["id"] + " " + door["role"], fill=(150, 0, 120))
for o in t["outerDoors"]:
    d.line([P(o["x"], o["y0"]), P(o["x"], o["y1"])], fill=(230, 60, 200), width=4)
for g in t["gates"]:
    d.ellipse([P(g["sx"] - 0.5, g["sy"] - 0.5), P(g["sx"] + 0.5, g["sy"] + 0.5)], fill=(0, 160, 0))
e = t["exitPt"]
d.ellipse([P(e["sx"] - 0.5, e["sy"] - 0.5), P(e["sx"] + 0.5, e["sy"] + 0.5)], fill=(220, 0, 0))
img.save(out)
print(img.size)
