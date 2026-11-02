import base64
import json
import os
import re
import time
import urllib.request
from pathlib import Path
import cv2
import numpy as np

ROOT = Path("/Users/arya/projects/ada/bazaar/floor-plan-extractor/legend-only")
env_path = ROOT / ".env"
for line in env_path.read_text().splitlines():
    if line.strip().startswith("OPENROUTER_API_KEY="):
        os.environ["OPENROUTER_API_KEY"] = line.split("=", 1)[1].strip().strip('"\'')

API_KEY = os.environ.get("OPENROUTER_API_KEY", "")
OUT_DIR = ROOT / "output/vlm_renders/claude-sonnet-5.5"
OUT_DIR.mkdir(parents=True, exist_ok=True)

PLANS = [
    {"id": "plan1", "image": ROOT / "data/plan1/layout.png", "truth": ROOT / "data/plan1/truth.json"},
    {"id": "plan2", "image": ROOT / "data/plan2/layout.png", "truth": ROOT / "data/plan2/truth.json"},
]

PROMPT = (
    "Extract ALL elements and structure from this exhibition floor plan image into a complete JSON specification.\n"
    "Identify and extract:\n"
    '1. "scale": Identify any scale indicator, grid size, or printed dimension reference (pixels_per_meter, printed dimensions such as "3m x 3m", "6x12m", or null if not indicated).\n'
    '2. "stage": Stage platforms with printed name/dimensions and bounding box [x1, y1, x2, y2].\n'
    '3. "walls": All outer boundary walls and interior partition wall segments [x1, y1, x2, y2].\n'
    '4. "doors": Entrances, exits, emergency exits, and door swing symbols with label and box [x1, y1, x2, y2].\n'
    '5. "pillars": All structural columns, round pillars, and pier blocks [x1, y1, x2, y2].\n'
    '6. "tables": All cafe/dining tables with surrounding chairs [x1, y1, x2, y2].\n'
    '7. "seating": All audience seating rows or chair groups [x1, y1, x2, y2].\n'
    '8. "booths": ALL exhibition booths as compact tuples: ["<ID>", x1, y1, x2, y2] (e.g. ["H1", 467, 115, 510, 138]).\n'
    "\n"
    "Coordinates: Use 0-1000 normalized coordinates [x1, y1, x2, y2] for every box.\n"
    "Return ONLY valid JSON matching this schema with no markdown:\n"
    "{\n"
    '  "scale": {"pixels_per_meter": <number_or_null>, "dimension_reference": "<str_or_null>"},\n'
    '  "stage": [{"name": "<str>", "dimension": "<str_or_null>", "box": [x1, y1, x2, y2]}],\n'
    '  "walls": [[x1, y1, x2, y2], ...],\n'
    '  "doors": [{"label": "<str>", "box": [x1, y1, x2, y2]}],\n'
    '  "pillars": [[x1, y1, x2, y2], ...],\n'
    '  "tables": [[x1, y1, x2, y2], ...],\n'
    '  "seating": [[x1, y1, x2, y2], ...],\n'
    '  "booths": [["<ID>", x1, y1, x2, y2], ...]\n'
    "}"
)

MAX_SIDE = 2048
MAX_TOKENS = 8192

COLORS = {
    "booth": (0, 160, 255),    # bright orange
    "wall": (0, 0, 0),         # black
    "door": (0, 180, 0),       # green
    "pillar": (80, 80, 80),    # dark grey
    "table": (220, 110, 30),   # royal blue
    "seating": (180, 50, 180), # magenta
    "stage": (140, 40, 220),   # purple
}

GRID_PX = {"plan1": 33, "plan2": 60}


def prepare_b64(path: Path):
    img = cv2.imread(str(path))
    h, w = img.shape[:2]
    scale = min(1.0, MAX_SIDE / max(w, h))
    rw, rh = int(round(w * scale)), int(round(h * scale))
    resized = cv2.resize(img, (rw, rh), interpolation=cv2.INTER_AREA)
    _, buf = cv2.imencode(".png", resized)
    return base64.b64encode(buf).decode("utf-8"), img, w, h


def call_sonnet(b64_str: str) -> tuple[float, dict, str]:
    payload = {
        "model": "anthropic/claude-sonnet-5.5",
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": PROMPT},
                    {"type": "image_url", "image_url": {"url": f"data:image/png;base64,{b64_str}"}},
                ],
            }
        ],
        "temperature": 0.0,
        "max_tokens": MAX_TOKENS,
    }
    req = urllib.request.Request(
        "https://openrouter.ai/api/v1/chat/completions",
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {API_KEY}",
            "Content-Type": "application/json",
            "HTTP-Referer": "https://github.com/floor-plan-extractor",
            "X-Title": "Floor Plan Complete Extractor",
        },
    )
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=180) as resp:
        body = json.loads(resp.read().decode("utf-8"))
    elapsed = time.time() - t0
    content = body["choices"][0]["message"]["content"]
    usage = body.get("usage", {})
    return elapsed, usage, content


def parse_response(raw_text: str) -> dict:
    clean = re.sub(r"<think>.*?</think>", "", raw_text, flags=re.DOTALL).strip()
    m = re.search(r"```(?:json)?\s*(\{.*\})\s*```", clean, flags=re.DOTALL)
    candidate = m.group(1) if m else clean
    data = json.loads(candidate)
    return data


def unpack_to_flat_items(data: dict) -> list[dict]:
    items = []
    # Booths
    for b in data.get("booths", []):
        if isinstance(b, list) and len(b) >= 5:
            items.append({"class": "booth", "id": str(b[0]), "box": [b[1], b[2], b[3], b[4]]})
        elif isinstance(b, dict):
            items.append({"class": "booth", "id": b.get("id"), "box": b.get("box")})
    # Stage
    for s in data.get("stage", []):
        if isinstance(s, dict):
            items.append({"class": "stage", "id": s.get("name"), "size": s.get("dimension"), "box": s.get("box")})
        elif isinstance(s, list) and len(s) == 4:
            items.append({"class": "stage", "box": s})
    # Walls
    for w in data.get("walls", []):
        if isinstance(w, list) and len(w) == 4:
            items.append({"class": "wall", "box": w})
        elif isinstance(w, dict):
            items.append({"class": "wall", "box": w.get("box")})
    # Doors
    for d in data.get("doors", []):
        if isinstance(d, dict):
            items.append({"class": "door", "id": d.get("label"), "box": d.get("box")})
        elif isinstance(d, list) and len(d) == 4:
            items.append({"class": "door", "box": d})
    # Pillars
    for p in data.get("pillars", []):
        if isinstance(p, list) and len(p) == 4:
            items.append({"class": "pillar", "box": p})
        elif isinstance(p, dict):
            items.append({"class": "pillar", "box": p.get("box")})
    # Tables
    for t in data.get("tables", []):
        if isinstance(t, list) and len(t) == 4:
            items.append({"class": "table", "box": t})
        elif isinstance(t, dict):
            items.append({"class": "table", "box": t.get("box")})
    # Seating
    for st in data.get("seating", []):
        if isinstance(st, list) and len(st) == 4:
            items.append({"class": "seating", "box": st})
        elif isinstance(st, dict):
            items.append({"class": "seating", "box": st.get("box")})
    return items


def render_complete(items, orig_img, w, h, plan_name, scale_info):
    canvas = np.full((h, w, 3), 255, np.uint8)
    step = GRID_PX.get(plan_name, 33)

    for pos in range(0, max(w, h), step):
        shade = (180, 180, 180) if (pos // step) % 5 == 0 else (235, 235, 235)
        cv2.line(canvas, (pos, 0), (pos, h), shade, 1)
        cv2.line(canvas, (0, pos), (w, pos), shade, 1)

    class_order = ["stage", "seating", "table", "wall", "pillar", "door", "booth"]
    sorted_items = sorted(items, key=lambda it: class_order.index(it.get("class", "booth")) if it.get("class", "booth") in class_order else 0)

    for it in sorted_items:
        bb = it.get("box", [0, 0, 0, 0])
        if not isinstance(bb, list) or len(bb) != 4:
            continue
        try:
            v = [float(x) for x in bb]
        except Exception:
            continue
        x1, y1, x2, y2 = v[0] * w / 1000.0, v[1] * h / 1000.0, v[2] * w / 1000.0, v[3] * h / 1000.0
        bx, by, bw, bh = int(round(x1)), int(round(y1)), int(round(max(2.0, x2 - x1))), int(round(max(2.0, y2 - y1)))
        cls = str(it.get("class", "booth")).lower()
        col = COLORS.get(cls, (0, 160, 255))

        if cls == "wall":
            cv2.rectangle(canvas, (bx, by), (bx + bw, by + bh), col, -1 if min(bw, bh) <= 8 else 3)
        elif cls == "pillar":
            cv2.rectangle(canvas, (bx, by), (bx + bw, by + bh), col, -1)
        elif cls == "door":
            cv2.rectangle(canvas, (bx, by), (bx + bw, by + bh), col, 4)
        elif cls == "stage":
            cv2.rectangle(canvas, (bx, by), (bx + bw, by + bh), col, 3)
            cv2.line(canvas, (bx, by), (bx + bw, by + bh), col, 1)
            cv2.line(canvas, (bx, by + bh), (bx + bw, by), col, 1)
        else:
            cv2.rectangle(canvas, (bx, by), (bx + bw, by + bh), col, 2)

        lbl = it.get("id") or it.get("size")
        if lbl:
            txt = str(lbl)
            f_scale = max(0.4, min(0.9, bw / 45.0))
            tx, ty = bx + 3, by + bh // 2 + 5
            cv2.putText(canvas, txt, (tx, ty), cv2.FONT_HERSHEY_SIMPLEX, f_scale, (255, 255, 255), 3)
            cv2.putText(canvas, txt, (tx, ty), cv2.FONT_HERSHEY_SIMPLEX, f_scale, (0, 0, 0), 1)

    # Save standalone render
    render_path = OUT_DIR / f"{plan_name}_everything_render.png"
    cv2.imwrite(str(render_path), canvas)

    # Side-by-side
    target_w = min(1200, w)
    s = target_w / w
    target_h = int(round(h * s))
    r_orig = cv2.resize(orig_img, (target_w, target_h), interpolation=cv2.INTER_AREA)
    r_canv = cv2.resize(canvas, (target_w, target_h), interpolation=cv2.INTER_AREA)

    bar_h = 50
    combo = np.full((target_h + bar_h, target_w * 2 + 20, 3), 245, np.uint8)
    combo[bar_h : bar_h + target_h, 0:target_w] = r_orig
    combo[bar_h : bar_h + target_h, target_w + 20 : target_w * 2 + 20] = r_canv

    cv2.putText(combo, f"Original Floor Plan ({plan_name})", (20, 32), cv2.FONT_HERSHEY_SIMPLEX, 0.75, (40, 40, 40), 2)
    dim_str = scale_info.get("dimension_reference") or ""
    ppm_str = f"{scale_info.get('pixels_per_meter')} px/m" if scale_info.get("pixels_per_meter") else ""
    scale_label = f" | Scale: {dim_str} ({ppm_str})" if dim_str or ppm_str else ""
    cv2.putText(
        combo,
        f"Claude Sonnet 5.5 Full Extraction ({len(items)} items{scale_label})",
        (target_w + 30, 32),
        cv2.FONT_HERSHEY_SIMPLEX,
        0.75,
        (0, 100, 200),
        2,
    )

    sbs_path = OUT_DIR / f"{plan_name}_everything_side_by_side.png"
    cv2.imwrite(str(sbs_path), combo)
    return render_path, sbs_path


def run():
    for plan in PLANS:
        pid = plan["id"]
        json_file = OUT_DIR / f"everything_{pid}.json"
        b64_str, orig_img, w, h = prepare_b64(plan["image"])

        print(f"=== Extracting Complete Structure & Elements: {pid} ===")
        elapsed, usage, raw_content = call_sonnet(b64_str)
        print(f"  API completed in {elapsed:.1f}s. Tokens: in={usage.get('prompt_tokens')}, out={usage.get('completion_tokens')}")

        data = parse_response(raw_content)
        json_file.write_text(json.dumps(data, indent=2))
        print(f"  Saved structured JSON to {json_file.name}")

        scale_info = data.get("scale", {})
        flat_items = unpack_to_flat_items(data)

        # Breakdown
        counts = {
            "booths": len(data.get("booths", [])),
            "walls": len(data.get("walls", [])),
            "doors": len(data.get("doors", [])),
            "pillars": len(data.get("pillars", [])),
            "tables": len(data.get("tables", [])),
            "seating": len(data.get("seating", [])),
            "stage": len(data.get("stage", [])),
        }

        print(f"  Scale : {scale_info}")
        print(f"  Counts: {counts}")
        print(f"  Total items: {len(flat_items)}")

        # Render PNGs
        ren_p, sbs_p = render_complete(flat_items, orig_img, w, h, pid, scale_info)
        print(f"  Rendered:\n    - {ren_p.name}\n    - {sbs_p.name}\n")


if __name__ == "__main__":
    run()
