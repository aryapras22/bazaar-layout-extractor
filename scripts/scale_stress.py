"""Pad each plan with white margins so its booths shrink relative to the page, then score fp-extract on it.

usage: scale_stress.py [plan numbers] [pad factors]   e.g. scale_stress.py 1,5,6 2,3
A scale-aware extractor scores about the same padded as unpadded. Needs `swift build -c release
--product fp-extract`, and writes its work under output/stress. Run from the project root.
"""
import json
import subprocess
import sys
from pathlib import Path

import cv2

plans = [int(n) for n in (sys.argv[1] if len(sys.argv) > 1 else "1,5,6").split(",")]
factors = [int(k) for k in (sys.argv[2] if len(sys.argv) > 2 else "2,3").split(",")]
work = Path("output/stress")
work.mkdir(parents=True, exist_ok=True)

for n in plans:
    image = cv2.imread(f"data/plan{n}/layout.png")
    height, width = image.shape[:2]
    truth = json.load(open(f"data/plan{n}/truth.json"))
    for k in factors:
        left, top = width * (k - 1) // 2, height * (k - 1) // 2
        padded = cv2.copyMakeBorder(image, top, height * k - height - top, left, width * k - width - left,
                                    cv2.BORDER_CONSTANT, value=(255, 255, 255))
        stem = work / f"plan{n}_x{k}"
        cv2.imwrite(f"{stem}.png", padded)
        shifted = json.loads(json.dumps(truth))
        shifted["image"].update(width=width * k, height=height * k)
        for item in shifted["items"]:
            item["box"][0] += left
            item["box"][1] += top
        json.dump(shifted, open(f"{stem}_truth.json", "w"), indent=1)
        subprocess.run([".build/release/fp-extract", f"{stem}.png", f"data/plan{n}/legend.png",
                        "--out", str(stem), "--feature-print"], check=True, capture_output=True)
        print(f"plan {n} padded x{k}")
        subprocess.run([sys.executable, "scripts/score.py", f"{stem}/layout.json", f"{stem}_truth.json"], check=True)
