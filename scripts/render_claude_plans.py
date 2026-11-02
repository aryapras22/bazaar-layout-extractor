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
OUT_DIR = ROOT / "output/vlm_renders"
OUT_DIR.mkdir(parents=True, exist_ok=True)

PROMPT = (
    "Extract the floor plan elements from this image into JSON.\n"
    "Valid classes: booth, stage, pillar, wall, door, table, seating, stairs.\n"
    'Use 0-1000 normalized coordinates [x1, y1, x2, y2] for each bounding box. Include "id" (such as "H1", "A100", "F25") for labeled booths and null otherwise.\n'
    "Return ONLY valid JSON with no markdown commentary:\n"
    '{"items":[{"class":"booth","id":"H1","box":[x1,y1,x2,y2]}]}'
)

MAX_SIDE = 2048
MAX_TOKENS = 8192

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

GRID_PX = {"plan1": 33, "plan2": 60, "plan3": 33}


def prepare_b64(path: Path):
    img = cv2.imread(str(path))
    h, w = img.shape[:2]
    scale = min(1.0, MAX_SIDE / max(w, h))
    rw, rh = int(round(w * scale)), int(round(h * scale))
    resized = cv2.resize(img, (rw, rh), interpolation=cv2.INTER_AREA)
    _, buf = cv2.imencode(".png", resized)
    b64_str = base64.b64encode(buf).decode("utf-8")
    return b64_str, img, w, h


def render_and_save(items, orig_img, w, h, plan_name, model_slug):
    model_dir = OUT_DIR / model_slug
    model_dir.mkdir(parents=True, exist_ok=True)

    canvas = np.full((h, w, 3), 255, np.uint8)
    step = GRID_PX.get(plan_name, 33)
    for pos in range(0, max(w, h), step):
        shade = (180, 180, 180) if (pos // step) % 5 == 0 else (230, 230, 230)
        cv2.line(canvas, (pos, 0), (pos, h), shade, 1)
        cv2.line(canvas, (0, pos), (w, pos), shade, 1)

    for it in items:
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
        thick = 3 if cls in ("wall", "door") else 2
        cv2.rectangle(canvas, (bx, by), (bx + bw, by + bh), col, thick)

        label = it.get("id")
        if label:
            txt = str(label)
            scale = max(0.4, min(1.0, bw / 45.0))
            tx, ty = bx + 3, by + bh // 2 + 5
            cv2.putText(canvas, txt, (tx, ty), cv2.FONT_HERSHEY_SIMPLEX, scale, (255, 255, 255), 3)
            cv2.putText(canvas, txt, (tx, ty), cv2.FONT_HERSHEY_SIMPLEX, scale, (0, 0, 0), 1)

    render_path = model_dir / f"{plan_name}_render.png"
    cv2.imwrite(str(render_path), canvas)

    # Side by side
    target_w = min(1200, w)
    s = target_w / w
    target_h = int(round(h * s))
    r_orig = cv2.resize(orig_img, (target_w, target_h), interpolation=cv2.INTER_AREA)
    r_canv = cv2.resize(canvas, (target_w, target_h), interpolation=cv2.INTER_AREA)

    bar_h = 40
    combo = np.full((target_h + bar_h, target_w * 2 + 20, 3), 245, np.uint8)
    combo[bar_h : bar_h + target_h, 0:target_w] = r_orig
    combo[bar_h : bar_h + target_h, target_w + 20 : target_w * 2 + 20] = r_canv
    cv2.putText(combo, f"Original ({plan_name})", (20, 26), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (40, 40, 40), 2)
    cv2.putText(
        combo,
        f"{model_slug} Extraction ({len(items)} items)",
        (target_w + 40, 26),
        cv2.FONT_HERSHEY_SIMPLEX,
        0.7,
        (0, 100, 200),
        2,
    )
    sbs_path = model_dir / f"{plan_name}_side_by_side.png"
    cv2.imwrite(str(sbs_path), combo)
    print(f"  Saved {render_path.name} & {sbs_path.name} ({len(items)} items)")


def run_claude_plans():
    for plan_name in ("plan2", "plan3"):
        img_p = ROOT / f"data/{plan_name}/layout.png"
        raw_cache = Path(f"/Users/arya/.gemini/antigravity-cli/brain/2a635bb0-eacf-4531-9dc5-7131ff33c9f6/scratch/sonnet55_{plan_name}_raw.json")
        b64_str, orig_img, w, h = prepare_b64(img_p)

        if raw_cache.exists():
            print(f"Loading cached Sonnet 5.5 {plan_name}...")
            content = raw_cache.read_text()
        else:
            print(f"Calling Sonnet 5.5 on {plan_name}...")
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
                headers={"Authorization": f"Bearer {API_KEY}", "Content-Type": "application/json"},
            )
            with urllib.request.urlopen(req, timeout=180) as resp:
                body = json.loads(resp.read().decode("utf-8"))
            content = body["choices"][0]["message"]["content"]
            raw_cache.write_text(content)

        clean = re.sub(r"<think>.*?</think>", "", content, flags=re.DOTALL).strip()
        m = re.search(r"```(?:json)?\s*(\{.*\})\s*```", clean, flags=re.DOTALL)
        candidate = m.group(1) if m else clean
        try:
            items = json.loads(candidate).get("items", [])
        except Exception:
            items = []
            for match in re.finditer(r"\{[^{}]*\}", clean):
                try:
                    it = json.loads(match.group(0))
                    if isinstance(it, dict) and any(k in it for k in ("box", "id", "class")):
                        items.append(it)
                except Exception:
                    continue
        render_and_save(items, orig_img, w, h, plan_name, "claude-sonnet-5.5")


if __name__ == "__main__":
    run_claude_plans()
