"""Run fp-extract on degraded copies of each plan and score every layer against truth moved the same way.

usage: robustness.py [plan numbers] [transform names]   e.g. robustness.py 1,2,3,5,6 half,jpeg40
Geometric transforms (resize, rotate, pad) move the truth boxes and segments with the image; photometric
ones (JPEG, blur, noise) are applied to plan and legend alike, as a scan would; `faded` is applied to the
plan only, so its colours drift from the legend. Needs `swift build -c release --product fp-extract`.
Set FP_EXTRACT to test another binary. Writes under output/robustness and prints one table. Run from the project root.
"""
import json
import os
import re
import subprocess
import sys
from pathlib import Path

import cv2
import numpy as np


def resize(f):
    def m(img):
        h, w = img.shape[:2]
        return np.float32([[f, 0, 0], [0, f, 0]]), (round(w * f), round(h * f))
    return m


def rot90(img):
    h, w = img.shape[:2]
    return np.float32([[0, -1, h - 1], [1, 0, 0]]), (h, w)


def skew(deg):
    def m(img):
        h, w = img.shape[:2]
        return cv2.getRotationMatrix2D((w / 2, h / 2), -deg, 1.0).astype(np.float32), (w, h)
    return m


def pad(k):
    def m(img):
        h, w = img.shape[:2]
        return np.float32([[1, 0, w * (k - 1) // 2], [0, 1, h * (k - 1) // 2]]), (w * k, h * k)
    return m


def jpeg(q):
    return lambda img: cv2.imdecode(cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, q])[1], cv2.IMREAD_COLOR)


def noise(sigma):
    rng = np.random.default_rng(7)
    return lambda img: np.clip(img + rng.normal(0, sigma, img.shape), 0, 255).astype(np.uint8)


GEOMETRIC = {"half": resize(0.5), "double": resize(2.0), "rot90": rot90, "skew1": skew(1.0), "pad2": pad(2)}
PHOTOMETRIC = {"jpeg40": jpeg(40), "blur": lambda img: cv2.GaussianBlur(img, (0, 0), 1.2), "noise": noise(8)}
PLAN_ONLY = {"faded": lambda img: (img * 0.8 + 255 * 0.2).astype(np.uint8)}
ORDER = ["original", *GEOMETRIC, *PHOTOMETRIC, *PLAN_ONLY]


def move_truth(truth, m, size):
    def point(x, y):
        return m[0, 0] * x + m[0, 1] * y + m[0, 2], m[1, 0] * x + m[1, 1] * y + m[1, 2]

    moved = json.loads(json.dumps(truth))
    moved["image"].update(width=size[0], height=size[1])
    for item in moved["items"]:
        x, y, w, h = item["box"]
        xs, ys = zip(*[point(px, py) for px, py in ((x, y), (x + w, y), (x, y + h), (x + w, y + h))])
        item["box"] = [round(min(xs)), round(min(ys)), round(max(xs) - min(xs)), round(max(ys) - min(ys))]
        if "segment" in item:
            x0, y0, x1, y1 = item["segment"]
            item["segment"] = [round(v) for v in (*point(x0, y0), *point(x1, y1))]
        if "width" in item and m[0, 0] ** 2 + m[1, 0] ** 2 != 1:
            item["width"] = item["width"] * float(np.hypot(m[0, 0], m[1, 0]))
    return moved


def metrics(text):
    def frac(label):
        found = re.search(label + r"\s+(\d+)/(\d+)", text)
        return f"{found.group(1)}/{found.group(2)}" if found and found.group(2) != "0" else "-"
    ids = re.search(r"tile ids exact (\d+)/(\d+)", text)
    wall = re.search(r"wall\s+pixel recall ([\d.]+)%", text)
    diagonal = re.search(r"diagonal wall found (\d+)/(\d+)", text)
    return [frac("tiles"), f"{ids.group(1)}/{ids.group(2)}" if ids else "-", frac("object"), frac("pillar"),
            f"{wall.group(1)}%" if wall and "(truth 0" not in text else "-",
            f"{diagonal.group(1)}/{diagonal.group(2)}" if diagonal else "-"]


plans = [int(n) for n in (sys.argv[1] if len(sys.argv) > 1 else "1,2,3,5,6").split(",")]
names = (sys.argv[2].split(",") if len(sys.argv) > 2 else ORDER)
work = Path("output/robustness")
work.mkdir(parents=True, exist_ok=True)
rows = []
for n in plans:
    plan = cv2.imread(f"data/plan{n}/layout.png")
    legend = cv2.imread(f"data/plan{n}/legend.png")
    truth = json.load(open(f"data/plan{n}/truth.json"))
    for name in names:
        stem = work / f"plan{n}_{name}"
        image, key, moved = plan, legend, truth
        if name in GEOMETRIC:
            m, size = GEOMETRIC[name](plan)
            image = cv2.warpAffine(plan, m, size, flags=cv2.INTER_AREA if name == "half" else cv2.INTER_CUBIC,
                                   borderValue=(255, 255, 255))
            moved = move_truth(truth, m, size)
        elif name in PHOTOMETRIC:
            image, key = PHOTOMETRIC[name](plan), PHOTOMETRIC[name](legend)
        elif name in PLAN_ONLY:
            image = PLAN_ONLY[name](plan)
        cv2.imwrite(f"{stem}.png", image)
        cv2.imwrite(f"{stem}_legend.png", key)
        json.dump(moved, open(f"{stem}_truth.json", "w"), indent=1)
        run = subprocess.run([os.environ.get("FP_EXTRACT", ".build/release/fp-extract"), f"{stem}.png", f"{stem}_legend.png", "--out", str(stem),
                              "--feature-print"], capture_output=True)
        if run.returncode != 0:
            rows.append([f"plan{n}", name, "failed", "", "", "", "", ""])
            continue
        scored = subprocess.run([sys.executable, "scripts/score.py", f"{stem}/layout.json", f"{stem}_truth.json"],
                                capture_output=True, text=True).stdout
        rows.append([f"plan{n}", name, *metrics(scored)])
        print(" ".join(rows[-1]), flush=True)

header = ["plan", "transform", "tiles", "ids", "objects", "pillars", "wall px", "diagonal"]
table = "| " + " | ".join(header) + " |\n|" + "---|" * len(header) + "\n"
table += "".join("| " + " | ".join(row) + " |\n" for row in rows)
(work / "report.md").write_text(table)
print(table)
