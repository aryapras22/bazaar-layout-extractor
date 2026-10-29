"""Write output/swift5/layouts.pdf: for each plan, the input image then its render.png. Run from the project root."""
import matplotlib

matplotlib.use("Agg")
import matplotlib.image as mpimg
import matplotlib.pyplot as plt
from matplotlib.backends.backend_pdf import PdfPages

WIDTH_IN = 11
DPI = 320
PLANS = [(f"plan{n}", f"data/plan{n}/layout.png") for n in (1, 2, 3)]

with PdfPages("output/swift5/layouts.pdf") as pdf:
    for out_dir, plan in PLANS:
        for title, path in [("input", plan), ("render", f"output/swift5/{out_dir}/render.png")]:
            image = mpimg.imread(path)
            height, width = image.shape[:2]
            fig = plt.figure(figsize=(WIDTH_IN, WIDTH_IN * height / width + 0.5))
            plt.imshow(image, interpolation="none")
            plt.title(f"{out_dir}: {title}")
            plt.axis("off")
            pdf.savefig(fig, bbox_inches="tight", dpi=DPI)
            plt.close(fig)
