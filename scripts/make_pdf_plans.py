"""Render data/plan5 (cosmo) and data/plan6 (women-fest) from their source.pdf into layout.png and legend.png.

Rects are in PDF points. The legend of each plan is printed inside or beside the plan, so the layout
crop is the plan area only and the legend is cut separately. Run from the project root.
"""
import pymupdf

PLANS = {
    "plan5": {"zoom": 5.0, "layout": (105, 70, 300, 495), "legend": (212, 352, 268, 432)},
    "plan6": {"zoom": 4.0, "layout": (20, 60, 596, 690), "legend": (590, 62, 706, 205)},
}

for name, spec in PLANS.items():
    page = pymupdf.open(f"data/{name}/source.pdf")[0]
    for part in ("layout", "legend"):
        pix = page.get_pixmap(matrix=pymupdf.Matrix(spec["zoom"], spec["zoom"]), clip=pymupdf.Rect(*spec[part]))
        pix.save(f"data/{name}/{part}.png")
        print(name, part, pix.width, "x", pix.height)
