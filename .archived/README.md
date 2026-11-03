# Archived generations

Old versions of the extractor, kept for reference. Nothing here is built, run or maintained. The live code is `Sources/Extractor`.

| Folder | What it was |
|---|---|
| `swift3` | `extract_swift3.swift`: the first single-file extractor, legend colours and crop OCR. |
| `swift4` | `extract_swift4.swift` and `Judge.swift`: one 2,500-line file with the polygon-masked reread, ID repair, regrouping and the judge. Also its renderer (`render_swift4.swift`, `render_swift4.ipynb`) and the hybrid MLX VLM benchmark note written against it. |
| `swift5` | The first split into layers (booth, wall, door, seat) with `output/swift5/planN` as the output folder. Its render notebook (`render_swift5.ipynb`) and the PDF script (`make_pdf.py`) read that folder. The code itself became `Sources/Extractor` and writes `output/extractor/planN` now. |

The notebooks and `make_pdf.py` still point at `output/swift4` and `output/swift5`, and at `/Users/arya/...`. Change those paths to use them.
