"""Write data/plan5/truth.json from the vector data in data/plan5/source.pdf.

Booths are coloured blocks cut into stalls by thin divider lines. The coloured fills are painted white
on a blank canvas at the layout.png zoom, every stroked line is drawn over them in black, and each
enclosed cell that holds exactly one ID label (letters then digits) is a booth. Cells holding two or
more labels, and labels outside any block, are left out. Run from the project root.
"""
import json
import re

import cv2
import numpy as np
import pymupdf

CLIP = pymupdf.Rect(105, 70, 300, 495)
ZOOM = 5.0
ID_PATTERN = re.compile(r"^([A-Z]{1,3})\d{1,3}$")
MAX_BLOCK_AREA = 8000  # PDF points squared; larger fills are zones, not booths
LINE_PX = 3

page = pymupdf.open("data/plan5/source.pdf")[0]
width, height = round(CLIP.width * ZOOM), round(CLIP.height * ZOOM)


def px(point):
    return (round((point[0] - CLIP.x0) * ZOOM), round((point[1] - CLIP.y0) * ZOOM))


def within_clip(rect):
    # Rect.intersects is false for a straight line (zero height or width), which is what dividers are.
    return rect.x1 >= CLIP.x0 and rect.x0 <= CLIP.x1 and rect.y1 >= CLIP.y0 and rect.y0 <= CLIP.y1


def outline(drawing):
    items = drawing["items"]
    if len(items) == 1 and items[0][0] == "re":
        r = items[0][1]
        return [(r.x0, r.y0), (r.x1, r.y0), (r.x1, r.y1), (r.x0, r.y1)]
    if all(item[0] == "l" for item in items):
        return [(item[1].x, item[1].y) for item in items]
    return None


canvas = np.zeros((height, width), np.uint8)
strokes = []
for drawing in page.get_drawings():
    if not within_clip(drawing["rect"]):
        continue
    fill = drawing.get("fill")
    polygon = outline(drawing)
    if fill is not None and polygon and max(fill) - min(fill) >= 0.2 \
            and drawing["rect"].width * drawing["rect"].height < MAX_BLOCK_AREA:
        cv2.fillPoly(canvas, [np.array([px(p) for p in polygon], np.int32)], 255)
    if drawing.get("color") is not None:
        strokes.append(drawing)
for drawing in strokes:
    for item in drawing["items"]:
        if item[0] == "l":
            cv2.line(canvas, px(item[1]), px(item[2]), 0, LINE_PX)
        elif item[0] == "re":
            r = item[1]
            cv2.rectangle(canvas, px((r.x0, r.y0)), px((r.x1, r.y1)), 0, LINE_PX)

count, cells, stats, _ = cv2.connectedComponentsWithStats(canvas, connectivity=4)
owners = {}
for word in page.get_text("words"):
    match = ID_PATTERN.match(word[4])
    box = pymupdf.Rect(word[:4])
    if not match or not box.intersects(CLIP):
        continue
    x, y = px(((box.x0 + box.x1) / 2, (box.y0 + box.y1) / 2))
    if 0 <= x < width and 0 <= y < height and cells[y, x] > 0:
        owners.setdefault(int(cells[y, x]), []).append(word[4])

items, crowded = [], []
for cell, texts in owners.items():
    if len(texts) != 1:
        crowded.append(texts)
        continue
    x, y, w, h = (int(v) for v in stats[cell][:4])
    items.append({"class": "Booth " + ID_PATTERN.match(texts[0]).group(1),
                  "box": [x - 1, y - 1, w + 2, h + 2], "id": texts[0]})

items.sort(key=lambda item: (item["box"][1], item["box"][0]))
truth = {
    "source": "generated from the PDF vector data: enclosed cells between divider lines that hold one ID label; "
              "not checked by eye; cells with two or more labels and labels outside any block are left out",
    "image": {"height": height, "origin": "top-left", "unit": "px", "width": width},
    "items": items,
}
with open("data/plan5/truth.json", "w") as f:
    json.dump(truth, f, indent=1)
print(len(items), "booths;", len(crowded), "cells with several labels:", crowded[:8])
