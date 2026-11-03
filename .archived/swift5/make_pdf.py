"""Write output/swift5/layouts.pdf and side_by_side.pdf for all plans. Run from the project root."""
from pathlib import Path
from PIL import Image

ROOT = Path("/Users/arya/projects/ada/bazaar/floor-plan-extractor/legend-only")
out_dir = ROOT / "output/swift5"

# 1. side_by_side.pdf: 1 page per plan with side-by-side input + output
sbs_pages = []
for n in range(1, 7):
    p = out_dir / f"plan{n}/side_by_side.png"
    if p.exists():
        sbs_pages.append(Image.open(p).convert("RGB"))

if sbs_pages:
    sbs_pdf = out_dir / "side_by_side.pdf"
    sbs_pages[0].save(sbs_pdf, save_all=True, append_images=sbs_pages[1:], resolution=150)
    print(f"Saved {sbs_pdf} ({len(sbs_pages)} pages)")

# 2. layouts.pdf: for each plan, input image then render image
layout_pages = []
for n in range(1, 7):
    inp_p = ROOT / f"data/plan{n}/layout.png"
    rend_p = out_dir / f"plan{n}/render.png"
    if inp_p.exists() and rend_p.exists():
        layout_pages.append(Image.open(inp_p).convert("RGB"))
        layout_pages.append(Image.open(rend_p).convert("RGB"))

if layout_pages:
    layouts_pdf = out_dir / "layouts.pdf"
    layout_pages[0].save(layouts_pdf, save_all=True, append_images=layout_pages[1:], resolution=150)
    print(f"Saved {layouts_pdf} ({len(layout_pages)} pages)")
