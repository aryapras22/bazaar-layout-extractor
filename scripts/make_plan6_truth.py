"""Write data/plan6/truth.json from the vector data in data/plan6/source.pdf.

A booth is a small white or black filled rectangle with exactly one ID label (letters then digits)
centred inside it. Rectangles holding two labels are skipped as ambiguous. Pixel boxes use the same
clip and zoom as make_pdf_plans.py. Run from the project root.
"""
import json
import re

import pymupdf

CLIP = pymupdf.Rect(20, 60, 596, 690)
ZOOM = 4.0
ID_PATTERN = re.compile(r"^([A-Z]{1,3})\d{1,3}$")
FILLS = {(1.0, 1.0, 1.0): "Booth", (0.0, 0.0, 0.0): "Sponsor booth"}

page = pymupdf.open("data/plan6/source.pdf")[0]
labels = [(pymupdf.Rect(w[:4]), w[4]) for w in page.get_text("words") if ID_PATTERN.match(w[4])]


def centre(rect):
    return pymupdf.Point((rect.x0 + rect.x1) / 2, (rect.y0 + rect.y1) / 2)


items = []
skipped = []
for drawing in page.get_drawings():
    rect, fill = drawing["rect"], drawing.get("fill")
    if fill is None or tuple(fill) not in FILLS or not rect.intersects(CLIP):
        continue
    if not (6 < rect.width < 90 and 6 < rect.height < 90):
        continue
    inside = [text for box, text in labels if rect.contains(centre(box))]
    if len(inside) == 2:
        skipped.append(inside)
    if len(inside) != 1:
        continue
    kind = FILLS[tuple(fill)]
    prefix = ID_PATTERN.match(inside[0]).group(1)
    items.append({
        "class": f"{kind} {prefix}" if kind == "Booth" else kind,
        "box": [round((rect.x0 - CLIP.x0) * ZOOM), round((rect.y0 - CLIP.y0) * ZOOM),
                round(rect.width * ZOOM), round(rect.height * ZOOM)],
        "id": inside[0],
    })

items.sort(key=lambda item: (item["box"][1], item["box"][0]))
truth = {
    "source": "generated from the PDF vector data: small white or black rectangles with one ID label inside; "
              "not checked by eye; two rectangles holding two labels each and sponsor boxes without a label are left out",
    "image": {"height": round(CLIP.height * ZOOM), "origin": "top-left", "unit": "px", "width": round(CLIP.width * ZOOM)},
    "items": items,
}
with open("data/plan6/truth.json", "w") as f:
    json.dump(truth, f, indent=1)
print(len(items), "booths; skipped ambiguous rectangles:", skipped)
