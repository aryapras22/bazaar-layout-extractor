"""Render data/plan5 and plan6 from source.pdf into layout.png and legend.png, generate layout.pdf and legend.pdf for every plan, and combine the 6 layouts into output/layouts.pdf.

Rects are in PDF points. Run from the project root:
conda run -n floor-plan-extractor-apple python scripts/make_pdf_plans.py
"""
from pathlib import Path
import pymupdf

PLANS = {
    "plan5": {"zoom": 5.0, "layout": (105, 70, 300, 495), "legend": (212, 352, 268, 432)},
    "plan6": {"zoom": 4.0, "layout": (20, 60, 596, 690), "legend": (590, 62, 706, 205)},
}

for name, spec in PLANS.items():
    source_pdf = Path(f"data/{name}/source.pdf")
    if source_pdf.exists():
        page = pymupdf.open(str(source_pdf))[0]
        for part in ("layout", "legend"):
            pix = page.get_pixmap(matrix=pymupdf.Matrix(spec["zoom"], spec["zoom"]), clip=pymupdf.Rect(*spec[part]))
            pix.save(f"data/{name}/{part}.png")
            print(name, part, pix.width, "x", pix.height)

for plan_dir in sorted(Path("data").glob("plan*")):
    for part in ("layout", "legend"):
        png_path = plan_dir / f"{part}.png"
        if not png_path.exists():
            continue
        pdf_path = plan_dir / f"{part}.pdf"
        img = pymupdf.Pixmap(str(png_path))
        doc = pymupdf.open()
        page = doc.new_page(width=img.width, height=img.height)
        page.insert_image(pymupdf.Rect(0, 0, img.width, img.height), filename=str(png_path))
        doc.save(str(pdf_path), deflate=True, garbage=4)
        print(f"wrote {pdf_path} ({img.width}x{img.height})")

layouts_doc = pymupdf.open()
for n in range(1, 7):
    pdf_path = Path(f"data/plan{n}/layout.pdf")
    if pdf_path.exists():
        with pymupdf.open(str(pdf_path)) as doc:
            layouts_doc.insert_pdf(doc)
out_path = Path("output/layouts.pdf")
out_path.parent.mkdir(parents=True, exist_ok=True)
layouts_doc.save(str(out_path), deflate=True, garbage=4)
print(f"wrote {out_path} ({len(layouts_doc)} pages)")

