"""Write layouts_swift4.pdf: for each output folder, the input plan then render.png."""
import matplotlib

matplotlib.use("Agg")
import matplotlib.image as mpimg
import matplotlib.pyplot as plt
from matplotlib.backends.backend_pdf import PdfPages

PLANS = [("out_swift4", "layout.png"), ("out2_swift4", "layout_2.png"), ("out3_swift4", "layout_3.png")]

with PdfPages("layouts_swift4.pdf") as pdf:
    for out_dir, plan in PLANS:
        for title, path in [("input", plan), ("render", f"{out_dir}/render.png")]:
            fig = plt.figure(figsize=(11, 7))
            plt.imshow(mpimg.imread(path))
            plt.title(f"{out_dir}: {title}")
            plt.axis("off")
            pdf.savefig(fig, bbox_inches="tight")
            plt.close(fig)
