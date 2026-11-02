import json
import re
from pathlib import Path
import cv2
import numpy as np

ROOT = Path("/Users/arya/projects/ada/bazaar/floor-plan-extractor/legend-only")
OUTPUT_BASE = ROOT / "output/vlm_renders"
OUTPUT_BASE.mkdir(parents=True, exist_ok=True)

FRONTIER_DIR = Path("/Users/arya/.gemini/antigravity-cli/brain/2a635bb0-eacf-4531-9dc5-7131ff33c9f6/scratch/frontier_bench")
LOCAL_DIR = Path("/Users/arya/.gemini/antigravity-cli/brain/2a635bb0-eacf-4531-9dc5-7131ff33c9f6/scratch/full_image_vlm")

COLORS = {
    "booth": (0, 160, 255),    # orange in BGR
    "wall": (0, 0, 0),         # black
    "door": (0, 180, 0),       # green
    "pillar": (100, 100, 100), # grey
    "table": (220, 100, 30),   # blue
    "seating": (180, 50, 180), # purple
    "stage": (180, 50, 180),   # purple
    "stairs": (0, 100, 200),   # dark orange
}

GRID_PX = {"plan1": 33, "plan2": 60, "plan3": 33, "plan4": 33, "plan5": 33, "plan6": 33}


def iou(a, b):
    ix = max(0.0, min(a[0] + a[2], b[0] + b[2]) - max(a[0], b[0]))
    iy = max(0.0, min(a[1] + a[3], b[1] + b[3]) - max(a[1], b[1]))
    inter = ix * iy
    union = a[2] * a[3] + b[2] * b[3] - inter
    return inter / union if union > 0 else 0.0


def determine_coord_mode(items, truth_path, W, H):
    if not truth_path or not truth_path.exists():
        return "rel1000_xyxy"
    truth_items = json.loads(truth_path.read_text())["items"]
    truth_booths = [t for t in truth_items if t.get("id")]
    best_mode = "rel1000_xyxy"
    best_found = -1

    for mode in ("rel1000_xyxy", "rel1000_yxyx"):
        found = 0
        used = set()
        for tb in truth_booths:
            bi, bv = None, 0.0
            for i, it in enumerate(items):
                if i in used:
                    continue
                bb = it.get("box", [0, 0, 0, 0])
                if not isinstance(bb, list) or len(bb) != 4:
                    continue
                try:
                    vals = [float(x) for x in bb]
                except Exception:
                    continue
                if mode == "rel1000_xyxy":
                    x1, y1, x2, y2 = vals[0] * W / 1000, vals[1] * H / 1000, vals[2] * W / 1000, vals[3] * H / 1000
                else:
                    y1, x1, y2, x2 = vals[0] * H / 1000, vals[1] * W / 1000, vals[2] * H / 1000, vals[3] * W / 1000
                box = [x1, y1, max(0.0, x2 - x1), max(0.0, y2 - y1)]
                v = iou(tb["box"], box)
                if v > bv:
                    bv, bi = v, i
            if bi is not None and bv >= 0.5:
                used.add(bi)
                found += 1
        if found > best_found:
            best_found = found
            best_mode = mode
    return best_mode


def render_items_on_canvas(items, mode, orig_w, orig_h, plan_name):
    canvas = np.full((orig_h, orig_w, 3), 255, np.uint8)
    step = GRID_PX.get(plan_name, 33)

    # Grid
    for pos in range(0, max(orig_w, orig_h), step):
        shade = (180, 180, 180) if (pos // step) % 5 == 0 else (230, 230, 230)
        cv2.line(canvas, (pos, 0), (pos, orig_h), shade, 1)
        cv2.line(canvas, (0, pos), (orig_w, pos), shade, 1)

    for it in items:
        bb = it.get("box") or it.get("bbox") or it.get("bbox_2d") or it.get("box_2d")
        if not isinstance(bb, list) or len(bb) != 4:
            continue
        try:
            v = [float(x) for x in bb]
        except Exception:
            continue
        if mode == "rel1000_xyxy":
            x1, y1, x2, y2 = v[0] * orig_w / 1000.0, v[1] * orig_h / 1000.0, v[2] * orig_w / 1000.0, v[3] * orig_h / 1000.0
        elif mode == "rel1000_yxyx":
            y1, x1, y2, x2 = v[0] * orig_h / 1000.0, v[1] * orig_w / 1000.0, v[2] * orig_h / 1000.0, v[3] * orig_w / 1000.0
        else:
            x1, y1, x2, y2 = v[0], v[1], v[2], v[3]

        x, y, w, h = int(round(x1)), int(round(y1)), int(round(max(2.0, x2 - x1))), int(round(max(2.0, y2 - y1)))
        cls = str(it.get("class", "booth")).lower()
        col = COLORS.get(cls, (0, 160, 255))
        thick = 3 if cls in ("wall", "door") else 2
        cv2.rectangle(canvas, (x, y), (x + w, y + h), col, thick)

        label = it.get("id")
        if label:
            # Draw black text with white outline for readability
            txt = str(label)
            font_scale = max(0.4, min(1.0, w / 45.0))
            tx, ty = x + 3, y + h // 2 + 5
            cv2.putText(canvas, txt, (tx, ty), cv2.FONT_HERSHEY_SIMPLEX, font_scale, (255, 255, 255), 3)
            cv2.putText(canvas, txt, (tx, ty), cv2.FONT_HERSHEY_SIMPLEX, font_scale, (0, 0, 0), 1)

    return canvas


def make_side_by_side(orig_img, canvas, plan_name, model_label, items_count):
    h, w = orig_img.shape[:2]
    # Resize down for side-by-side if very large
    target_w = min(1200, w)
    scale = target_w / w
    target_h = int(round(h * scale))

    r_orig = cv2.resize(orig_img, (target_w, target_h), interpolation=cv2.INTER_AREA)
    r_canv = cv2.resize(canvas, (target_w, target_h), interpolation=cv2.INTER_AREA)

    # Add header bars
    bar_h = 40
    combo = np.full((target_h + bar_h, target_w * 2 + 20, 3), 245, np.uint8)

    # Insert images
    combo[bar_h : bar_h + target_h, 0:target_w] = r_orig
    combo[bar_h : bar_h + target_h, target_w + 20 : target_w * 2 + 20] = r_canv

    # Headers
    cv2.putText(combo, f"Original Floor Plan ({plan_name})", (20, 26), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (40, 40, 40), 2)
    cv2.putText(
        combo,
        f"{model_label} Extraction ({items_count} items)",
        (target_w + 40, 26),
        cv2.FONT_HERSHEY_SIMPLEX,
        0.7,
        (0, 100, 200),
        2,
    )
    return combo


def process_all():
    all_json_files = sorted(list(FRONTIER_DIR.glob("*.json")) + list(LOCAL_DIR.glob("mlx-community_*.json")))
    print(f"Found {len(all_json_files)} model result files to render.")
    total_rendered = 0

    for jf in all_json_files:
        model_data = json.loads(jf.read_text())
        model_name = model_data.get("model", jf.stem)
        slug = model_name.split("/")[-1].replace(":", "_")
        model_out_dir = OUTPUT_BASE / slug
        model_out_dir.mkdir(parents=True, exist_ok=True)

        print(f"=== Rendering {slug} ===")
        plans = model_data.get("plans", {})

        for plan_name, plan_info in plans.items():
            items = plan_info.get("all_items") or plan_info.get("sample_items")
            # If Sonnet 5.5 plan1 raw exists, load all 180 items
            if "claude-sonnet-5.5" in model_name and plan_name == "plan1":
                raw_sonnet = Path("/Users/arya/.gemini/antigravity-cli/brain/2a635bb0-eacf-4531-9dc5-7131ff33c9f6/scratch/sonnet55_plan1_raw.json")
                if raw_sonnet.exists():
                    items = json.loads(raw_sonnet.read_text()).get("items", items)

            if not items:
                print(f"  {plan_name}: no items found, skipping.")
                continue

            img_path = ROOT / f"data/{plan_name}/layout.png"
            if not img_path.exists():
                continue

            truth_path = ROOT / f"data/{plan_name}/truth.json"
            orig_img = cv2.imread(str(img_path))
            orig_h, orig_w = orig_img.shape[:2]

            mode = determine_coord_mode(items, truth_path, orig_w, orig_h)
            canvas = render_items_on_canvas(items, mode, orig_w, orig_h, plan_name)

            render_png = model_out_dir / f"{plan_name}_render.png"
            cv2.imwrite(str(render_png), canvas)

            side_by_side = make_side_by_side(orig_img, canvas, plan_name, slug, len(items))
            sbs_png = model_out_dir / f"{plan_name}_side_by_side.png"
            cv2.imwrite(str(sbs_png), side_by_side)

            print(f"  {plan_name}: rendered {len(items)} items -> {render_png.name} & {sbs_png.name}")
            total_rendered += 2

    print(f"\nAll done! Successfully generated {total_rendered} PNG renders in {OUTPUT_BASE}")


if __name__ == "__main__":
    process_all()
