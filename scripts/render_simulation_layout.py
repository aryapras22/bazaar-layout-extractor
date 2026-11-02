import json
from pathlib import Path
import cv2
import numpy as np

ROOT = Path("/Users/arya/projects/ada/bazaar/floor-plan-extractor/legend-only")
sim_path = ROOT / "output/vlm_renders/claude-sonnet-5.5/layout1_sim.json"
orig_img_path = ROOT / "data/plan1/layout.png"

with open(sim_path) as f:
    d = json.load(f)

orig = cv2.imread(str(orig_img_path))
orig_h, orig_w = orig.shape[:2]

meta_world = d.get("meta", {}).get("world", {})
world_w = meta_world.get("w", 65.08)
world_h = meta_world.get("h", 85.08)

scale_x = orig_w / world_w
scale_y = orig_h / world_h
scale_m = min(scale_x, scale_y)  # ~33-36 px per metre

# Create canvas
canvas = np.full((orig_h, orig_w, 3), 244, dtype=np.uint8)


def to_px(x_m, y_m):
    return int(round(x_m * scale_m)), int(round(y_m * scale_m))


# 1. Base floor fills
hall = d.get("hall", [])
if len(hall) >= 3:
    pts = np.array([to_px(p[0], p[1]) for p in hall], dtype=np.int32)
    cv2.fillPoly(canvas, [pts], (255, 255, 255))

lobby = d.get("lobby", [])
if len(lobby) >= 3:
    pts = np.array([to_px(p[0], p[1]) for p in lobby], dtype=np.int32)
    cv2.fillPoly(canvas, [pts], (246, 243, 238))

# 2. Box background: 1m, 5m, and 10m grid lines drawn OVER the floor
max_m_x = int(orig_w / scale_m) + 1
max_m_y = int(orig_h / scale_m) + 1

# 1-metre thin grid lines
for m in range(0, max_m_x + 1):
    gx = int(round(m * scale_m))
    if gx >= orig_w:
        break
    col = (130, 130, 130) if m % 10 == 0 else ((180, 180, 180) if m % 5 == 0 else (228, 228, 228))
    thick = 2 if m % 10 == 0 else 1
    cv2.line(canvas, (gx, 0), (gx, orig_h), col, thick)

for m in range(0, max_m_y + 1):
    gy = int(round(m * scale_m))
    if gy >= orig_h:
        break
    col = (130, 130, 130) if m % 10 == 0 else ((180, 180, 180) if m % 5 == 0 else (228, 228, 228))
    thick = 2 if m % 10 == 0 else 1
    cv2.line(canvas, (0, gy), (orig_w, gy), col, thick)

# 3. Coordinate rulers along top and left edges
# Top ruler bar
cv2.rectangle(canvas, (0, 0), (orig_w, 32), (240, 240, 240), -1)
cv2.line(canvas, (0, 32), (orig_w, 32), (100, 100, 100), 2)
# Left ruler bar
cv2.rectangle(canvas, (0, 0), (36, orig_h), (240, 240, 240), -1)
cv2.line(canvas, (36, 0), (36, orig_h), (100, 100, 100), 2)

for m in range(0, max_m_x + 1):
    gx = int(round(m * scale_m))
    if gx >= orig_w:
        break
    if m % 5 == 0:
        cv2.line(canvas, (gx, 16), (gx, 32), (40, 40, 40), 2)
        txt = f"{m}m"
        cv2.putText(canvas, txt, (gx + 3, 24), cv2.FONT_HERSHEY_SIMPLEX, 0.45, (40, 40, 40), 1)
    else:
        cv2.line(canvas, (gx, 24), (gx, 32), (120, 120, 120), 1)

for m in range(0, max_m_y + 1):
    gy = int(round(m * scale_m))
    if gy >= orig_h:
        break
    if m % 5 == 0:
        cv2.line(canvas, (20, gy), (36, gy), (40, 40, 40), 2)
        txt = f"{m}m"
        cv2.putText(canvas, txt, (2, gy + 14), cv2.FONT_HERSHEY_SIMPLEX, 0.40, (40, 40, 40), 1)
    else:
        cv2.line(canvas, (28, gy), (36, gy), (120, 120, 120), 1)

# 4. Outlines of Hall and Lobby
if len(hall) >= 3:
    pts = np.array([to_px(p[0], p[1]) for p in hall], dtype=np.int32)
    cv2.polylines(canvas, [pts], True, (50, 50, 50), 3)

if len(lobby) >= 3:
    pts = np.array([to_px(p[0], p[1]) for p in lobby], dtype=np.int32)
    cv2.polylines(canvas, [pts], True, (80, 80, 80), 2)

# 5. Outer Door Wall & Pilasters (Interior walls)
wall = d.get("wall", {})
if wall and wall.get("x1", 0) > wall.get("x0", 0):
    wp0 = to_px(wall["x0"], wall["y0"])
    wp1 = to_px(wall["x1"], wall["y1"])
    cv2.rectangle(canvas, wp0, wp1, (30, 30, 30), -1)

pilasters = d.get("pilasters", [])
for p in pilasters:
    pp0 = to_px(p["x0"], p["y0"])
    pp1 = to_px(p["x1"], p["y1"])
    kind = p.get("kind", "wall")
    if kind == "wall":
        cv2.rectangle(canvas, pp0, pp1, (40, 40, 40), -1)
    elif kind == "rail":
        cv2.rectangle(canvas, pp0, pp1, (100, 100, 180), 2)
    else:
        cv2.rectangle(canvas, pp0, pp1, (80, 80, 80), -1)

# 6. Stage
stg = d.get("stage", {})
if stg:
    p0 = to_px(stg["x0"], stg["y0"])
    p1 = to_px(stg["x1"], stg["y1"])
    cv2.rectangle(canvas, p0, p1, (230, 200, 245), -1)
    cv2.rectangle(canvas, p0, p1, (140, 40, 180), 3)
    cv2.putText(
        canvas,
        "STAGE (12x6m)",
        (p0[0] + 15, (p0[1] + p1[1]) // 2 + 8),
        cv2.FONT_HERSHEY_SIMPLEX,
        0.85,
        (100, 20, 140),
        2,
    )

# 7. Kids / Audience seating blocks
kids_raw = d.get("kids", [])
kids_list = kids_raw if isinstance(kids_raw, list) else ([kids_raw] if isinstance(kids_raw, dict) else [])
for idx, kb in enumerate(kids_list):
    if kb and kb.get("x1", 0) > kb.get("x0", 0):
        kp0 = to_px(kb["x0"], kb["y0"])
        kp1 = to_px(kb["x1"], kb["y1"])
        cv2.rectangle(canvas, kp0, kp1, (215, 240, 255), -1)
        cv2.rectangle(canvas, kp0, kp1, (0, 170, 220), 2)
        cv2.putText(
            canvas,
            "AUDIENCE",
            (kp0[0] + 8, (kp0[1] + kp1[1]) // 2 + 4),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.5,
            (0, 120, 180),
            2,
        )

# 8. Doors
doors = d.get("doors", [])
for dr in doors:
    dp0 = to_px(dr["x0"], dr["y0"])
    dp1 = to_px(dr["x1"], dr["y1"])
    cv2.rectangle(canvas, dp0, dp1, (70, 210, 90), -1)
    cv2.rectangle(canvas, dp0, dp1, (20, 130, 40), 2)
    cv2.putText(canvas, dr.get("id", "DOOR"), (dp0[0], dp0[1] - 8), cv2.FONT_HERSHEY_SIMPLEX, 0.55, (20, 130, 40), 2)

# 9. Entrance Gates & Exit
gates = d.get("gates", [])
for g in gates:
    gx, gy = to_px(g["sx"], g["sy"])
    cv2.circle(canvas, (gx, gy), 14, (0, 200, 0), -1)
    cv2.putText(canvas, "ENTRANCE", (gx - 50, gy - 18), cv2.FONT_HERSHEY_SIMPLEX, 0.65, (0, 140, 0), 2)

exit_pt = d.get("exitPt", {})
if exit_pt:
    ex, ey = to_px(exit_pt["sx"], exit_pt["sy"])
    cv2.circle(canvas, (ex, ey), 14, (0, 0, 220), -1)
    cv2.putText(canvas, "EXIT", (ex - 20, ey + 28), cv2.FONT_HERSHEY_SIMPLEX, 0.65, (0, 0, 180), 2)

# 10. Dining tables
tables = d.get("tables", [])
for tb in tables:
    tcx, tcy = to_px(tb["cx"], tb["cy"])
    tw, th = int(round(tb["w"] * scale_m)), int(round(tb["h"] * scale_m))
    x0, y0 = tcx - tw // 2, tcy - th // 2
    cv2.rectangle(canvas, (x0, y0), (x0 + tw, y0 + th), (255, 235, 200), -1)
    cv2.rectangle(canvas, (x0, y0), (x0 + tw, y0 + th), (220, 120, 40), 1)

# 11. Fixtures
fixtures = d.get("fixtures", [])
for fix in fixtures:
    fp0 = to_px(fix["x0"], fix["y0"])
    fp1 = to_px(fix["x1"], fix["y1"])
    cv2.rectangle(canvas, fp0, fp1, (210, 210, 210), -1)
    cv2.rectangle(canvas, fp0, fp1, (70, 70, 70), 2)
    lbl = fix.get("label", "FIXTURE")
    cv2.putText(
        canvas,
        lbl,
        (fp0[0] + 4, (fp0[1] + fp1[1]) // 2 + 4),
        cv2.FONT_HERSHEY_SIMPLEX,
        0.42,
        (40, 40, 40),
        1,
    )

# 12. Booths with semi-transparent fill and clear borders
booth_colors = {
    "goods": (0, 160, 255),    # orange
    "fnb": (0, 200, 120),      # mint green
    "fit": (220, 100, 180),    # violet
}

booths = d.get("booths", [])
overlay_booths = canvas.copy()
for b in booths:
    bcx, bcy = to_px(b["cx"], b["cy"])
    bw, bh = int(round(b["w"] * scale_m)), int(round(b["h"] * scale_m))
    x0, y0 = bcx - bw // 2, bcy - bh // 2
    btype = b.get("type", "goods")
    col = booth_colors.get(btype, (0, 160, 255))
    cv2.rectangle(overlay_booths, (x0, y0), (x0 + bw, y0 + bh), col, -1)

# Blend booths at 25% opacity so the 1m grid squares underneath remain visible
cv2.addWeighted(overlay_booths, 0.25, canvas, 0.75, 0, canvas)

for b in booths:
    bcx, bcy = to_px(b["cx"], b["cy"])
    bw, bh = int(round(b["w"] * scale_m)), int(round(b["h"] * scale_m))
    x0, y0 = bcx - bw // 2, bcy - bh // 2
    btype = b.get("type", "goods")
    col = booth_colors.get(btype, (0, 160, 255))
    cv2.rectangle(canvas, (x0, y0), (x0 + bw, y0 + bh), col, 2)

    bid = b.get("id", "")
    scale_txt = max(0.35, min(0.65, bw / 60.0))
    tx, ty = x0 + 4, y0 + bh // 2 + 5
    cv2.putText(canvas, bid, (tx, ty), cv2.FONT_HERSHEY_SIMPLEX, scale_txt, (255, 255, 255), 3)
    cv2.putText(canvas, bid, (tx, ty), cv2.FONT_HERSHEY_SIMPLEX, scale_txt, (0, 0, 0), 1)

# 13. Scale legend card
legend_w, legend_h = 420, 130
lx0, ly0 = orig_w - legend_w - 20, 50
cv2.rectangle(canvas, (lx0, ly0), (lx0 + legend_w, ly0 + legend_h), (255, 255, 255), -1)
cv2.rectangle(canvas, (lx0, ly0), (lx0 + legend_w, ly0 + legend_h), (100, 100, 100), 2)
cv2.putText(canvas, "GRID & SCALE REFERENCE", (lx0 + 15, ly0 + 26),
            cv2.FONT_HERSHEY_SIMPLEX, 0.65, (0, 0, 0), 2)
# Draw 5m scale bar
bar_len_px = int(round(5.0 * scale_m))
cv2.rectangle(canvas, (lx0 + 15, ly0 + 40), (lx0 + 15 + bar_len_px, ly0 + 55), (40, 40, 40), -1)
cv2.putText(canvas, "5 metres", (lx0 + 25 + bar_len_px, ly0 + 53),
            cv2.FONT_HERSHEY_SIMPLEX, 0.6, (40, 40, 40), 2)
cv2.putText(canvas, "- 1 box = 1m x 1m | Bold line = 5m", (lx0 + 15, ly0 + 82),
            cv2.FONT_HERSHEY_SIMPLEX, 0.52, (60, 60, 60), 1)
cv2.putText(canvas, f"- Standard booth = 3m x 2m ({int(round(3*scale_m))} x {int(round(2*scale_m))} px)", (lx0 + 15, ly0 + 105),
            cv2.FONT_HERSHEY_SIMPLEX, 0.50, (60, 60, 60), 1)

# Save images
out_dir = ROOT / "output/vlm_renders/claude-sonnet-5.5"
render_path = out_dir / "layout1_sim_render.png"
cv2.imwrite(str(render_path), canvas)
print(f"Saved {render_path}")

target_w = 1200
s = target_w / orig_w
target_h = int(round(orig_h * s))
r_orig = cv2.resize(orig, (target_w, target_h), interpolation=cv2.INTER_AREA)
r_canv = cv2.resize(canvas, (target_w, target_h), interpolation=cv2.INTER_AREA)

bar_h = 50
combo = np.full((target_h + bar_h, target_w * 2 + 30, 3), 245, dtype=np.uint8)
combo[bar_h : bar_h + target_h, 0:target_w] = r_orig
combo[bar_h : bar_h + target_h, target_w + 30 : target_w * 2 + 30] = r_canv

cv2.putText(combo, "Original Floor Plan (Layout 1)", (20, 34), cv2.FONT_HERSHEY_SIMPLEX, 0.8, (40, 40, 40), 2)
cv2.putText(
    combo,
    f"Simulation Map with 1m/5m Box Grid ({len(booths)} booths, {len(tables)} tables)",
    (target_w + 50, 34),
    cv2.FONT_HERSHEY_SIMPLEX,
    0.75,
    (0, 120, 200),
    2,
)

sbs_path = out_dir / "layout1_sim_side_by_side.png"
cv2.imwrite(str(sbs_path), combo)
print(f"Saved {sbs_path}")

overlay_img = cv2.addWeighted(orig, 0.45, canvas, 0.55, 0)
ovl_path = out_dir / "layout1_sim_overlay.png"
cv2.imwrite(str(ovl_path), overlay_img)
print(f"Saved {ovl_path}")
