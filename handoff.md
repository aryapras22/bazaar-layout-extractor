# Handoff: floor plan extractor, swift 4

Folder: `/Users/arya/Projects/ADA/bazaar/floor-plan-extractor/legend-only`. It is not a git repo.

## Goal

Read a floor plan image and its legend image. Find each booth tile by legend colour, read its ID, extract walls, doors, pillars, and objects outside the legend, and write `layout.json`, `report_diff.json`, `overlay.png`, and `render.png`. An optional on-device MLX VLM judge (`--judge mlx`) classifies grouped objects and unresolved tiles once per group.

Swift 4 (`extract_swift4.swift` + `Judge.swift`) and `render_swift4.swift` are the main tools. Swift 1, swift 2, the older Python notebooks, and the SAM3 experiment are archived in `.archived`.

## What is in the folder

- `extract_swift4.swift` and `Judge.swift`, compiled together into `extract_swift4`
- `render_swift4.swift`, compiled into `render_swift4`, plus `render_swift4.ipynb` and the 6-page `layouts_swift4.pdf`
- `extract_swift3.swift` and its compiled binary `extract_swift3` (baseline for `report_diff.json`)
- `layout.png` with `legend.png` (layout 1, 2349 x 2871), `layout_2.png` with `legend_2.png` (layout 2, 1750 x 2106), and `layout_3.png` with `legend_3.png` (layout 3, 3413 x 988)
- `out_swift4`, `out2_swift4`, and `out3_swift4`, each with `layout.json`, `report_diff.json`, `overlay.png`, `render.png`, `crops/`, and `judge_crops/`
- `out_swift3`, `out2_swift3`, and `out3_swift3` (swift 3 baseline outputs)
- `truth.json` (layout 1, 358 items), `truth_2.json` (layout 2, 255 items), and `truth_3.json` (layout 3, 124 items), the hand-checked ground truth
- `Package.swift` with `Sources/FloorPlanCore`, `Sources/fp-fix`, and `Tests/FloorPlanCoreTests`
- `LEARNING/tile-detection-by-solidity.md`, `LEARNING/polygon-masked-ocr-and-monotone-bands.md`, and `LEARNING/hybrid-mlx-vlm-benchmark.md`

## How to run

Compile `extract_swift4` and `render_swift4`:

```
swiftc -O -parse-as-library extract_swift4.swift Judge.swift -o extract_swift4
swiftc -O render_swift4.swift -o render_swift4
```

Run deterministic extraction (about 3 to 5 s per plan):

```
./extract_swift4 layout.png legend.png --out out_swift4 --feature-print
./extract_swift4 layout_2.png legend_2.png --out out2_swift4 --feature-print
./extract_swift4 layout_3.png legend_3.png --out out3_swift4 --feature-print
./render_swift4 out_swift4 out2_swift4 out3_swift4
```

Run with the local MLX VLM judge (`mlx-community/Qwen3.5-9B-MLX-4bit` via conda env `floor-plan-vlm-bench`, about 15 to 30 s per plan):

```
./extract_swift4 layout.png legend.png --out out_swift4 --feature-print --judge mlx
./extract_swift4 layout_2.png legend_2.png --out out2_swift4 --feature-print --judge mlx
./extract_swift4 layout_3.png legend_3.png --out out3_swift4 --feature-print --judge mlx
```

## Scores against the ground truth

Matching rule: a truth booth tile counts as found when an engine box overlaps it with IoU of at least 0.5, and an ID is correct only on an exact string match. Unlabeled `object` items are matched greedily at IoU of at least 0.3.

| Metric | Layout 1 (`truth.json`) | Layout 2 (`truth_2.json`) | Layout 3 (`truth_3.json`) |
|---|---|---|---|
| Booth / stage / blocked tiles found (IoU >= 0.5) | 160 / 160 (100%) | 211 / 211 (100%) | 68 / 68 (100%) |
| Booth IDs exact without repair (`id`) | 153 / 154 (99.4%) | 208 / 209 (99.5%) | 67 / 67 (100%) |
| Booth IDs exact with repair (`suggested_id` or `id`) | 153 / 154 (154 / 154 if C6 accepted for printed D6) | 209 / 209 (100%) | 67 / 67 (100%) |
| Matched `object` items (IoU >= 0.3, swift 4 before Phase 3 -> after Phase 3) | 30 / 141 -> 122 / 141 (86.5%) | 26 / 26 -> 26 / 26 (100%) | 2 / 11 -> 2 / 11 (18.2%) |
| Engine `wall` count (truth walls: 14, 10, 9) | 29 -> 28 | 17 -> 16 | 20 -> 14 |
| Matched `pillar` items (IoU >= 0.3) | 0 / 26 | 0 / 0 | 25 / 31 (80.6%) |

The single remaining `suggested_id` across all 430 numbered booths is `FI` -> `F1` on Layout 2 (`ocr-confusion`), plus the plan's printed `"D6"` on the `C6` slot on Layout 1 (`prefix-conflict`). `F7`, `I3`, and `I9` on Layout 2 and `H71` on Layout 3 are now read directly into `id`.

## How swift 4 works

```
extract_swift4
  → readLegend
    → OCR the legend text, fold Cyrillic lookalikes, find each swatch to the left of its text
  → legendLayer
    → classify (Lab distance under 12 to a legend colour)
    → per class: fillHoles, erode, components, solidity >= 0.85, tilePolygon, readLabel
  → rereadTiles
    → retry labelled-class tiles where id == nil using 2x/3x polygon-masked crops and page-level OCR fallback
  → outsideLayer
    → mask legend tiles and page-level OCR text boxes out of dark ink
    → longRuns (stroke >= 2 for unconfirmed walls, thickness-transition door splits)
    → restNear (rx: 2, ry: 2 dilation to keep 4 chairs with their table without merging adjacent tables)
    → hull + simplify (convex-hull polygons for furniture and object clusters)
  → bridgeWalls
    → merge collinear wall segments across gaps up to 8 * scale
  → regroupObjects
    → group unlabeled objects by shared short-side module and optional VNFeaturePrintObservation distance <= 0.12
  → repairIds
    → monotone-band id-sequence, prefix-conflict, and ocr-confusion suggestions
  → runJudge (--judge off | fm | mlx)
    → evaluate one composite crop per object group (cached across all members) plus remaining flagged tiles
  → write layout.json, report_diff.json, overlay.png
```

## 7-model local MLX VLM benchmark summary

All 7 models were benchmarked in `/Users/arya/miniconda3/envs/floor-plan-vlm-bench` (`mlx-vlm 0.7.10`) on Apple M5 (24 GB unified memory). Full tables and contact sheets are in `LEARNING/hybrid-mlx-vlm-benchmark.md`.

- `mlx-community/Qwen3.5-9B-MLX-4bit` is the best model overall and backs `--judge mlx`: 6.97 GB peak RAM, 22.8 tok/s, 11/11 (100%) on the hardest booth tiles, and 160/201 (79.6%) on non-noise structural/furniture items across the 52 object groups in 57.8 s total (26.8 s on Layout 1, 13.7 s on Layout 2, 17.3 s on Layout 3).
- `mlx-community/gemma-3-27b-it-qat-4bit` tied accuracy (159/201 non-noise items, 11/11 hard tiles) but used 16.94 GB RAM and took 223.6 s (3.9x slower).
- `mlx-community/Qwen3.5-4B-MLX-4bit` is the best lightweight alternative: 4.11 GB peak RAM, 39.3 tok/s, 11/11 hard tiles, and 34/52 (65.4%) per-group accuracy in 45.9 s.
- End-to-end VLM bounding-box detection on dense crops (Phase 1) topped out at 11/20 boxes at IoU >= 0.5 (`gemma-4-12B-it-qat-4bit`, mean IoU 0.478) and cannot replace deterministic `legendLayer` (439/439 tiles at 100%).

## Environments

- macOS 26.4 (25E253), Apple M5, 24 GB unified memory, Swift 6.3
- If compiling inside a restricted sandbox where macro plugins cannot spawn a nested `sandbox-exec`, pass `-disable-sandbox -module-cache-path /tmp/swift-module-cache` to `swiftc`.
- Conda env `floor-plan-vlm-bench` at `/Users/arya/miniconda3/envs/floor-plan-vlm-bench` (Python 3.12, `mlx-vlm==0.7.10`, `huggingface_hub`, `opencv-python`, `pypdfium2`, `Pillow`) runs `--judge mlx`.
- Conda env `floor-plan-extractor-apple` at `/Users/arya/miniconda3/envs/floor-plan-extractor-apple` (`opencv`, `numpy`, `scipy`, `matplotlib`, `jupyter`) runs `render_swift4.ipynb` and `layouts_swift4.pdf` generation.

## Remaining open items for a future session

- Layout 3 has 9 blue-filled table clusters (`RGB ~(100, 150, 210)`) and 6 grey perimeter pillars that are neither dark ink (`gray < 80`) nor a legend swatch, so `outsideLayer` misses those 9 tables and 6 pillars.
- Layout 1 has 23 hollow circular columns (`pillar` in `truth.json`) drawn as thin circle outlines rather than solid dark squares (`fill > 0.7`), so `outsideLayer` currently classifies them as `object` or misses them.
- `JudgeReport` in `report_diff.json` records the MLX group classifications (`table_with_chairs`, `audience_seating`, `stairs`, `door`, `pillar`, `wall`, `noise`), but `layout.json` still keeps the top-level `"class": "object"` schema rather than promoting judge subtypes into `layout.json` item classes or filtering `"noise"` items out of `layout.json`.
