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
    "Analyze this exhibition floor plan image and perform a complete structural and element extraction into JSON.\n"
    "Extract EVERYTHING visible on the plan:\n"
    '1. "scale": Identify any scale indicator, grid size, or printed dimension reference (pixels_per_meter, printed dimensions such as "3m x 3m", "6x12m", or null if not indicated).\n'
    '2. "items": Extract every single element:\n'
    '   - "booth": every exhibition booth tile with its printed ID (such as "H1", "A100", "F25", "X1", "D6")\n'
    '   - "stage": stage platforms with their printed size (such as "STAGE 6x12m")\n'
    '   - "wall": all outer perimeter walls and interior partition wall segments\n'
    '   - "door": entrances, exits, emergency exits, single/double door swing symbols (such as "ENTRANCE", "IN", "OUT")\n'
    '   - "pillar": structural columns, circular pillars, and square pier blocks\n'
    '   - "table": conference or dining tables with surrounding chairs\n'
    '   - "seating": audience seating rows or theater seating blocks\n'
    '   - "decor": decorative floor elements or designated areas\n'
    "\n"
    "Coordinates: Use 0-1000 normalized coordinates [x1, y1, x2, y2] for the bounding box of each element.\n"
    "Format JSON compactly without unnecessary whitespace so all elements fit within output limits.\n"
    "Return ONLY valid JSON with no markdown commentary:\n"
    '{"scale":{"pixels_per_meter":<float_or_null>,"dimension_reference":"<str_or_null>"},"items":[{"class":"<class>","id":"<id_or_null>","size":"<size_or_null>","box":[x1,y1,x2,y2]}]}'
)

MAX_SIDE = 2048
MAX_TOKENS = 8192

# Visual styling for full element render
COLORS = {
    "booth": (0, 160, 255),    # bright orange
    "wall": (0, 0, 0),         # solid black
    "door": (0, 180, 0),       # vibrant green
    "pillar": (80, 80, 80),    # dark grey
    "table": (220, 110, 30),   # royal blue
    "seating": (180, 50, 180), # magenta
    "stage": (140, 40, 220),   # purple
    "decor": (200, 200, 0),    # cyan
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


def parse_clean_json(raw_text: str) -> dict:
    clean = re.sub(r"<think>.*?</think>", "", raw_text, flags=re.DOTALL).strip()
    m = re.search(r"```(?:json)?\s*(\{.*\})\s*```", clean, flags=re.DOTALL)
    candidate = m.group(1) if m else clean
    try:
        return json.loads(candidate)
    except Exception:
        items = []
        for match in re.finditer(r"\{[^{}]*\}", clean):
            try:
                it = json.loads(match.group(0))
                if isinstance(it, dict) and any(k in it for k in ("box", "id", "class")):
                    items.append(it)
            except Exception:
                continue
        return {"scale": None, "items": items}


def render_complete_layout(items, orig_img, w, h, plan_name, scale_info):
    canvas = np.full((h, w, 3), 255, np.uint8)
    step = GRID_PX.get(plan_name, 33)

    # Grid
    for pos in range(0, max(w, h), step):
        shade = (180, 180, 180) if (pos // step) % 5 == 0 else (235, 235, 235)
        cv2.line(canvas, (pos, 0), (pos, h), shade, 1)
        cv2.line(canvas, (0, pos), (w, pos), shade, 1)

    # Render order: 1) seating/decor/stage/tables, 2) walls, 3) pillars, 4) doors, 5) booths & labels
    class_order = ["decor", "stage", "seating", "table", "wall", "pillar", "door", "booth"]
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
            # Wall: thick solid line or rectangle
            cv2.rectangle(canvas, (bx, by), (bx + bw, by + bh), col, -1 if min(bw, bh) <= 8 else 3)
        elif cls == "pillar":
            cv2.rectangle(canvas, (bx, by), (bx + bw, by + bh), col, -1)
        elif cls == "door":
            cv2.rectangle(canvas, (bx, by), (bx + bw, by + bh), col, 4)
        elif cls == "stage":
            cv2.rectangle(canvas, (bx, by), (bx + bw, by + bh), col, 3)
            # Stage diagonal hatch
            cv2.line(canvas, (bx, by), (bx + bw, by + bh), col, 1)
            cv2.line(canvas, (bx, by + bh), (bx + bw, by), col, 1)
        else:
            cv2.rectangle(canvas, (bx, by), (bx + bw, by + bh), col, 2)

        # Label
        lbl = it.get("id") or it.get("size")
        if lbl:
            txt = str(lbl)
            f_scale = max(0.4, min(1.0, bw / 45.0))
            tx, ty = bx + 3, by + bh // 2 + 5
            cv2.putText(canvas, txt, (tx, ty), cv2.FONT_HERSHEY_SIMPLEX, f_scale, (255, 255, 255), 3)
            cv2.putText(canvas, txt, (tx, ty), cv2.FONT_HERSHEY_SIMPLEX, f_scale, (0, 0, 0), 1)

    # Save standalone render
    render_path = OUT_DIR / f"{plan_name}_everything_render.png"
    cv2.imwrite(str(render_path), canvas)

    # Side-by-side comparison
    target_w = min(1200, w)
    s = target_w / w
    target_h = int(round(h * s))
    r_orig = cv2.resize(orig_img, (target_w, target_h), interpolation=cv2.INTER_AREA)
    r_canv = cv2.resize(canvas, (target_w, target_h), interpolation=cv2.INTER_AREA)

    bar_h = 50
    combo = np.full((target_h + bar_h, target_w * 2 + 20, 3), 245, np.uint8)
    combo[bar_h : bar_h + target_h, 0:target_w] = r_orig
    combo[bar_h : bar_h + target_h, target_w + 20 : target_w * 2 + 20] = r_canv

    # Header labels
    cv2.putText(combo, f"Original Floor Plan ({plan_name})", (20, 32), cv2.FONT_HERSHEY_SIMPLEX, 0.75, (40, 40, 40), 2)
    scale_text = f" | Scale: {scale_info.get('dimension_reference') or 'auto'}" if scale_info else ""
    cv2.putText(
        combo,
        f"Claude Sonnet 5.5 Complete Extraction ({len(items)} items{scale_text})",
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

        print(f"=== Extracting Everything on {pid} with Claude Sonnet 5.5 ===")
        t_start = time.time()
        elapsed, usage, raw_content = call_sonnet(b64_str)
        print(f"  API completed in {elapsed:.1f}s. Tokens: in={usage.get('prompt_tokens')}, out={usage.get('completion_tokens')}")

        parsed_data = parse_clean_json(raw_content)
        json_file.write_text(json.dumps(parsed_data, indent=2))
        print(f"  Saved JSON to {json_file.name}")

        scale_info = parsed_data.get("scale", {})
        items = parsed_data.get("items", [])

        # Count by class
        by_class = {}
        for it in items:
            c = it.get("class", "unknown")
            by_class[c] = by_class.get(c, 0) + 1

        print(f"  Scale Info : {scale_info}")
        print(f"  Total Items: {len(items)}")
        print(f"  Class Breakdown: {by_class}")

        # Render
        ren_p, sbs_p = render_complete_layout(items, orig_img, w, h, pid, scale_info)
        print(f"  Saved renders to:\n    - {ren_p.name}\n    - {sbs_p.name}\n")


if __name__ == "__main__":
    run()
