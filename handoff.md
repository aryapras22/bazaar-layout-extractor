# Handoff: floor plan extractor, swift 4

Folder: `/Users/arya/Projects/ADA/bazaar/floor-plan-extractor/legend-only`. It is a git repo (initialised this session, local only, nothing pushed).

## Goal

Read a floor plan image and its legend image. Find each booth tile by legend colour, read its ID, extract walls, doors, pillars, and objects outside the legend, and write `layout.json`, `report_diff.json`, `overlay.png`, and `render.png`. An optional on-device MLX VLM judge (`--judge mlx`) classifies grouped objects and unresolved tiles once per group. The judge writes only to `report_diff.json`. It does not change `layout.json`.

Swift 4 (`extract_swift4.swift` + `Judge.swift`) and `render_swift4.swift` are the main tools. Swift 1, swift 2, the older Python notebooks, and the SAM3 experiment are archived in `.archived`.

## What is in the folder

- `extract_swift4.swift` and `Judge.swift`, compiled together into `extract_swift4`
- `render_swift4.swift`, compiled into `render_swift4`, plus `render_swift4.ipynb` (predates this session's changes) and `make_pdf.py`, which writes the 6-page `layouts_swift4.pdf` (input then render for each layout)
- `score.py`, the scorer. Run it with the `floor-plan-extractor-apple` env python. It is the source of every number below.
- `extract_swift3.swift` and its binary (old baseline, not used by swift 4)
- `layout.png` + `legend.png` (layout 1, 2349 x 2871), `layout_2.png` + `legend_2.png` (layout 2, 1750 x 2106), `layout_3.png` + `legend_3.png` (layout 3, 3413 x 988)
- `out_swift4`, `out2_swift4`, `out3_swift4`: current outputs, produced with `--feature-print --judge mlx`
- `out_swift3`, `out2_swift3`, `out3_swift3`: swift 3 outputs, untracked
- `truth.json` (358 items), `truth_2.json` (255), `truth_3.json` (124): hand-checked ground truth
- `Package.swift` with `Sources/FloorPlanCore`, `Sources/fp-fix`, `Tests/FloorPlanCoreTests`: a separate SwiftPM package for ID repair, not exercised this session, status unknown
- `LEARNING/`: three notes on tile detection, polygon-masked OCR with monotone bands, and the MLX VLM benchmark

## How to run

```
swiftc -O -parse-as-library extract_swift4.swift Judge.swift -o extract_swift4
swiftc -O -parse-as-library render_swift4.swift -o render_swift4

./extract_swift4 layout.png legend.png --out out_swift4 --feature-print
./extract_swift4 layout_2.png legend_2.png --out out2_swift4 --feature-print
./extract_swift4 layout_3.png legend_3.png --out out3_swift4 --feature-print
./render_swift4 out_swift4 out2_swift4 out3_swift4

/Users/arya/miniconda3/envs/floor-plan-extractor-apple/bin/python make_pdf.py
/Users/arya/miniconda3/envs/floor-plan-extractor-apple/bin/python score.py
```

Add `--judge mlx` for the VLM pass (24 s, 22 s, and 15 s for layouts 1 to 3, conda env `floor-plan-vlm-bench`). If that env path is missing, the judge records `missing-env-floor-plan-vlm-bench` in `report_diff.json` and the run carries on without an error. The `--judge fm` mode only compiles with Swift 6.4 or later.

## Scores (from `score.py`, current outputs)

Tiles and tile IDs use IoU of at least 0.5. Objects, pillars, and doors use greedy matching at IoU of at least 0.3. Walls use pixel coverage within 6 px. Precision is matches divided by engine items of that class.

| | Layout 1 | Layout 2 | Layout 3 |
|---|---|---|---|
| Tiles found | 160/160, precision 100% | 211/211, 100% | 68/68, 100% |
| Tile IDs exact | 154/154 | 208/209 | 67/67 |
| Objects | 134/141, precision 79% | 26/26, 59% | 8/11, 40% |
| Pillars | 18/26, precision 78% | 0/0, 1 false | 30/31, precision 94% |
| Doors | 0/10 | 0/4 | 0/1 |
| Walls, pixel recall / precision | 86% / 80% | 92% / 88% | 10% / 71% |

Before this session's changes: Layout 1 objects 122/141 at 56% precision, pillars 0/26; Layout 3 objects 0/11, pillars 25/31.

Notes on reading the table:
- Tile precision ignores engine tiles in classes the truth does not list: 9 `ENTRANCE` on layout 1, 3 `Seating` on layout 2, 6 `Tenant space` on layout 3. They are real legend tiles.
- The one layout 2 ID miss is `FI` read for printed `F1` (flagged as `suggested_id`). Layout 1 has a `prefix-conflict` suggestion on the plan's printed `D6` in the `C6` slot.
- Layout 3 truth `wall` items are the tenant boundary boxes, not wall lines, so its wall number is not a measure of wall detection.
- `truth.json` lists three pillars at [1383,904], [1383,1511], and [1720,1578] that sit exactly on the three `Blocked` legend tiles. They cannot match as pillars, so layout 1 pillar recall tops out at 23/26 until the truth is corrected.
- Doors: truth doors are door-leaf symbols (for example 62 x 24 px). The engine reports whole wall openings (140 to 395 px wide). They are different objects, so box shape is not the problem and doors need a swing-symbol detector.

## What changed this session

1. Hollow square pillars: fill small closed holes in the ink, open past the wall-line width, keep square cores (`outsideLayer`). Five north-wall squares on layout 1 stay missed because the `ENTRANCE` tile covers their bottom edge.
2. Area floor of 160 px² (at 2000 px max side, scaled by area) on object candidates.
3. OCR boxes under 0.5 confidence no longer erase ink. Vision read layout 3's table icons as "TEIL" at 0.3 and wiped them out. The handoff's earlier explanation (blue fills and grey pillars) was wrong.
4. Legend tiles over 1% of the image no longer mask ink inside them. This recovered the pillars inside tenant tiles (they are black, not grey). Side effect: more wall fragments, layout 2 wall precision fell from 94% to 88%.

## Benchmark summary (full tables in `LEARNING/hybrid-mlx-vlm-benchmark.md`)

Seven models on Apple M5, 24 GB, in `floor-plan-vlm-bench`. Qwen3.5-9B-MLX-4bit backs `--judge mlx`: 6.97 GB peak, 22.8 tok/s, 160/201 (79.6%) on non-noise items, but 30/52 on per-group accuracy. Qwen3.5-4B-MLX-4bit scores higher per group (34/52, 65.4%) because it rejects noise crops, at 4.11 GB. All seven models read the 11 hard booth tiles correctly, so that test does not separate them, and four of the 11 now read correctly without the judge. The benchmark scripts live outside this folder, in `~/.gemini/antigravity-cli/brain/.../scratch/`, so it cannot be rerun from here. VLM bounding-box detection topped out at 11/20 boxes and cannot replace `legendLayer`.

## Environments

macOS 27.0.1, Apple M5, 24 GB, Swift 6.4. `Package.swift` requires macOS 27. Conda env `floor-plan-vlm-bench` (Python 3.12, `mlx-vlm==0.7.10`) runs `--judge mlx`. Conda env `floor-plan-extractor-apple` (`opencv`, `numpy`, `scipy`, `matplotlib`, `jupyter`) runs `score.py` and the render notebook.

## Open items

- Judge output never reaches `layout.json`: `runJudge` takes `items` by value and returns only a report. `agreed_with_rule` is 0 and `compared_with_rule` is 1 on layout 1, so nothing yet measures whether the judge is right. Decision pending after the object noise work above; current recommendation is to keep it report-only.
- Doors need a detector for door-leaf symbols (see above).
- Object precision is still 40% to 79%. Layout 3 misses 3 of 11 objects.
- Layout 1 pillars: 5 north-wall squares missed behind `ENTRANCE` tiles, 4 false pillars at wall corners and the south wall.
- `symbol` items (7, 4, 4 in the truth files) are never emitted and are not scored.
- `render_swift4.ipynb` still holds outputs from before this session; rerun it or drop it in favour of `render_swift4`.
- `Package.swift` and `Tests/` are unverified; run `swift test` before relying on them.
- `.archived/`, the swift 3 outputs, and the two PDFs and notebooks are not tracked in git.
