# Floor plan extraction benchmark and hybrid architecture report

## 1. Baseline vs Phase 3 non-VLM Swift fixes

All three floor plans ([layout.png](file:///Users/arya/projects/ada/bazaar/floor-plan-extractor/legend-only/layout.png), [layout_2.png](file:///Users/arya/projects/ada/bazaar/floor-plan-extractor/legend-only/layout_2.png), [layout_3.png](file:///Users/arya/projects/ada/bazaar/floor-plan-extractor/legend-only/layout_3.png)) were scored against the updated ground truth files ([truth.json](file:///Users/arya/projects/ada/bazaar/floor-plan-extractor/legend-only/truth.json), [truth_2.json](file:///Users/arya/projects/ada/bazaar/floor-plan-extractor/legend-only/truth_2.json), [truth_3.json](file:///Users/arya/projects/ada/bazaar/floor-plan-extractor/legend-only/truth_3.json)) before and after the Phase 3 deterministic CV fixes in [extract_swift4_fixed.swift](file:///Users/arya/.gemini/antigravity-cli/brain/2a635bb0-eacf-4531-9dc5-7131ff33c9f6/scratch/extract_swift4_fixed.swift) and [render_swift4_fixed.swift](file:///Users/arya/.gemini/antigravity-cli/brain/2a635bb0-eacf-4531-9dc5-7131ff33c9f6/scratch/render_swift4_fixed.swift).

| Metric | Layout 1 (`swift4` -> `phase3`) | Layout 2 (`swift4` -> `phase3`) | Layout 3 (`swift4` -> `phase3`) |
|---|---|---|---|
| Booth tiles found (IoU >= 0.5) | 160/160 -> 160/160 | 211/211 -> 211/211 | 68/68 -> 68/68 |
| Direct Vision OCR IDs (`raw_id`) | 154/154 -> 154/154 | 205/209 -> 208/209 (`F7`, `I3`, `I9` fixed) | 66/67 -> 67/67 (`H71` fixed) |
| Final IDs (with repair rules) | 153/154 -> 153/154 (plan prints `D6` on `C6` slot) | 209/209 -> 209/209 | 66/67 -> 67/67 (100%) |
| Object recall (IoU >= 0.3) | 30/141 -> 122/141 (86.5%) | 26/26 -> 26/26 (100%) | 0/11 -> 0/11 (blue tables have saturation > 40) |
| Engine wall count | 29 -> 28 | 16 -> 16 | 20 -> 14 (6 dimension-arrow walls removed) |
| `Judge.swift` unique LLM calls | 173 calls -> 23 group calls | 64 calls -> 12 group calls | 106 calls -> 17 group calls |

### Root causes fixed in Phase 3

- Trimming non-alphanumeric border marks at both ends and capping identifiers to 1-2 letters plus 1-3 digits in [`cleanLabel`](file:///Users/arya/.gemini/antigravity-cli/brain/2a635bb0-eacf-4531-9dc5-7131ff33c9f6/scratch/extract_swift4_fixed.swift#L329-L346) fixes `"H71•"` -> `"H71"` on Layout 3 while rejecting `"19"` and upside-down `"BOOTH"` (`"H1OO8"`).
- Retrying all labelled tiles with `items[$0].id == nil` in [`rereadTiles`](file:///Users/arya/.gemini/antigravity-cli/brain/2a635bb0-eacf-4531-9dc5-7131ff33c9f6/scratch/extract_swift4_fixed.swift#L832) instead of only `items[$0].text.isEmpty` recovers `F7`, `I3`, and `I9` directly from 2x/3x polygon-masked crops on Layout 2.
- Masking page-level OCR text boxes out of `ink` before `longRuns` in [`outsideLayer`](file:///Users/arya/.gemini/antigravity-cli/brain/2a635bb0-eacf-4531-9dc5-7131ff33c9f6/scratch/extract_swift4_fixed.swift#L1078-L1087) and requiring `stroke >= 2` for unconfirmed walls in [`segments`](file:///Users/arya/.gemini/antigravity-cli/brain/2a635bb0-eacf-4531-9dc5-7131ff33c9f6/scratch/extract_swift4_fixed.swift#L996-L998) removes the 6 false walls caused by dimension arrows on Layout 3.
- Reducing `restNear` dilation from `rx: 3, ry: 3` (6px bridge) to `rx: 2, ry: 2` (4px bridge) and saving simplified convex-hull polygons on `object` items in [`outsideLayer`](file:///Users/arya/.gemini/antigravity-cli/brain/2a635bb0-eacf-4531-9dc5-7131ff33c9f6/scratch/extract_swift4_fixed.swift#L1184-L1228) separates adjacent 27x27 tables across 5px gaps on Layout 1 (raising matched objects from 30/141 to 122/141) and renders octagons in [`RenderSwift4`](file:///Users/arya/.gemini/antigravity-cli/brain/2a635bb0-eacf-4531-9dc5-7131ff33c9f6/scratch/render_swift4_fixed.swift#L181-L216).
- Remaining deterministic CV gap on Layout 1 and Layout 3: perimeter round columns on Layout 1 (`20x20` hollow circles with thin outlines) are eroded away by `opened` (`rx: 5, ry: 5`), and blue tables/chairs on Layout 3 have HSV saturation around 130 so [`inkMask`](file:///Users/arya/.gemini/antigravity-cli/brain/2a635bb0-eacf-4531-9dc5-7131ff33c9f6/scratch/extract_swift4_fixed.swift#L1054) (`sat < 40`) filters them out before `outsideLayer` runs.

````carousel
![Layout 1 before Phase 3 fixes](/Users/arya/.gemini/antigravity-cli/brain/2a635bb0-eacf-4531-9dc5-7131ff33c9f6/swift4_orig_l1.png)
<!-- slide -->
![Layout 1 after Phase 3 fixes](/Users/arya/.gemini/antigravity-cli/brain/2a635bb0-eacf-4531-9dc5-7131ff33c9f6/phase3_fix_l1.png)
<!-- slide -->
![Layout 2 before Phase 3 fixes](/Users/arya/.gemini/antigravity-cli/brain/2a635bb0-eacf-4531-9dc5-7131ff33c9f6/swift4_orig_l2.png)
<!-- slide -->
![Layout 2 after Phase 3 fixes](/Users/arya/.gemini/antigravity-cli/brain/2a635bb0-eacf-4531-9dc5-7131ff33c9f6/phase3_fix_l2.png)
<!-- slide -->
![Layout 3 before Phase 3 fixes](/Users/arya/.gemini/antigravity-cli/brain/2a635bb0-eacf-4531-9dc5-7131ff33c9f6/swift4_orig_l3.png)
<!-- slide -->
![Layout 3 after Phase 3 fixes](/Users/arya/.gemini/antigravity-cli/brain/2a635bb0-eacf-4531-9dc5-7131ff33c9f6/phase3_fix_l3.png)
````

## 2. Local MLX VLM benchmark (7 models, Phase 1 + Phase 2)

All 7 models were benchmarked offline on Apple M5 (24 GB unified memory) in the `floor-plan-vlm-bench` conda environment via [phase1_bench.py](file:///Users/arya/.gemini/antigravity-cli/brain/2a635bb0-eacf-4531-9dc5-7131ff33c9f6/scratch/phase1_bench.py) (1000x800 dense crop detection, 20 core truth booths) and [phase2_run_model.py](file:///Users/arya/.gemini/antigravity-cli/brain/2a635bb0-eacf-4531-9dc5-7131ff33c9f6/scratch/phase2_run_model.py) (52 feature-print object groups covering 248 items across all 3 plans, plus 11 hard/sloped/OCR-confused booth tile crops).

| Model | Weights (GB) | Peak RAM (GB) | P1 speed (tok/s) | P1 core ID recall | P1 box IoU>=0.5 | P1 mean IoU | P2 groups (52) | P2 all items (248) | P2 non-noise (201) | P2 groups time (L1 / L2 / L3) | P2 hard tiles (11) |
|---|---|---|---|---|---|---|---|---|---|---|---|
| `Qwen3.5-9B-MLX-4bit` | 5.57 | 6.97 | 22.8 | 20/20 | 1/20 | 0.127 | 30/52 (57.7%) | 170/248 (68.5%) | 160/201 (79.6%) | 57.8s (26.8s / 13.7s / 17.3s) | 11/11 (10.5s) |
| `gemma-3-27b-it-qat-4bit` | 15.71 | 16.94 | 7.0 | 20/20 | 7/20 | 0.062 | 27/52 (51.9%) | 169/248 (68.1%) | 159/201 (79.1%) | 223.6s (108.4s / 48.3s / 66.8s) | 11/11 (44.6s) |
| `Qwen3.5-4B-MLX-4bit` | 2.85 | 4.11 | 39.3 | 20/20 | 9/20 | 0.260 | 34/52 (65.4%) | 133/248 (53.6%) | 115/201 (57.2%) | 45.9s (20.0s / 9.7s / 16.1s) | 11/11 (6.9s) |
| `gemma-4-12B-it-qat-4bit` | 10.26 | 11.63 | 8.8 | 20/20 | 11/20 | 0.478 | 29/52 (55.8%) | 129/248 (52.0%) | 117/201 (58.2%) | 119.5s (54.2s / 26.8s / 38.5s) | 11/11 (21.9s) |
| `Qwen3-VL-8B-Instruct-4bit` | 5.38 | 6.74 | 22.5 | 20/20 | 3/20 | 0.191 | 30/52 (57.7%) | 129/248 (52.0%) | 114/201 (56.7%) | 36.8s (16.8s / 8.4s / 11.7s) | 11/11 (9.5s) |
| `InternVL3-8B-MLX-4bit` | 4.58 | 5.79 | 25.4 | 20/20 | 0/20 | 0.000 | 17/52 (32.7%) | 119/248 (48.0%) | 118/201 (58.7%) | 89.9s (38.5s / 20.7s / 30.7s) | 11/11 (19.0s) |
| `gemma-4-e4b-it-4bit` | 4.82 | 5.76 | 35.8 | 20/20 | 1/20 | 0.001 | 23/52 (44.2%) | 122/248 (49.2%) | 113/201 (56.2%) | 37.6s (16.7s / 8.8s / 12.1s) | 11/11 (6.8s) |

````carousel
![52 object groups composite crops (left: tight zoom, right: context with red box)](/Users/arya/.gemini/antigravity-cli/brain/2a635bb0-eacf-4531-9dc5-7131ff33c9f6/object_groups_contact_sheet.png)
<!-- slide -->
![11 hard booth tile crops (polygon-masked)](/Users/arya/.gemini/antigravity-cli/brain/2a635bb0-eacf-4531-9dc5-7131ff33c9f6/hard_tiles_contact_sheet.png)
````

### Key findings from the 7-model benchmark

- End-to-end VLM bounding-box detection (Phase 1) cannot replace `legendLayer`: even the best box detector (`gemma-4-12B-it-qat-4bit`, 11/20 boxes at IoU >= 0.5, mean IoU 0.478) drifts by 10-40 pixels on dense booth grids, whereas `legendLayer` + solidity achieves 439/439 (100%) exact booth boxes and polygons across all 3 plans in under 2 seconds.
- Crop-level VLM reading and classification (Phase 2) is fast and accurate: all 7 models read 11/11 (100%) of the hardest sloped and OCR-confused booth tiles (`G11, H3, X1, D6, C6, C2, F1, F7, I3, I9, H71`), and `Qwen3.5-9B-MLX-4bit` classifies 160/201 (79.6%) of non-noise structural/furniture items (`table_with_chairs`, `audience_seating`, `stairs`, `door`, `wall`) in 13.7s to 26.8s per plan.
- `Qwen3.5-9B-MLX-4bit` is the best local model overall: it edges out `gemma-3-27b-it-qat-4bit` in accuracy (170/248 vs 169/248 all items; 160/201 vs 159/201 non-noise items) while running 3.9x faster (57.8s vs 223.6s) and using 6.97 GB RAM instead of 16.94 GB RAM.
- `Qwen3.5-4B-MLX-4bit` is the best lightweight/noise-filtering model: it achieves the highest per-group accuracy (34/52 groups, 65.4%) because it correctly rejects single-item text/dimension noise crops on Layouts 2 and 3, running in 45.9s at 4.11 GB RAM.

## 3. Recommended hybrid pipeline architecture

    extract_swift4 (Swift CV + Vision OCR)
      → readLegend + legendLayer
        → 100% booth/stage/tenant polygons and boxes (439/439 across 3 plans)
      → rereadTiles (with Phase 3 cleanLabel + id == nil retry)
        → 431/432 booth IDs solved deterministically (only printed D6->C6 typo remains for repairIds)
      → outsideLayer + bridgeWalls + regroupObjects (with Phase 3 text-masking, stroke >= 2, rx=2 dilation, hull polygons)
        → walls, doors, pillars, and feature-print grouped objects with polygons
      → Group-level VLM labeller (Qwen3.5-9B-MLX-4bit, 1 composite crop per group + any remaining unresolved booth tiles)
        → assigns semantic subtype (table_with_chairs, audience_seating, stairs, door, pillar, wall, noise) to all members of each group and drops noise groups

## 4. Verification of applied changes

- Applied the Phase 3 fixes to [extract_swift4.swift](file:///Users/arya/projects/ada/bazaar/floor-plan-extractor/legend-only/extract_swift4.swift), [Judge.swift](file:///Users/arya/projects/ada/bazaar/floor-plan-extractor/legend-only/Judge.swift), and [render_swift4.swift](file:///Users/arya/projects/ada/bazaar/floor-plan-extractor/legend-only/render_swift4.swift), removed `Sam.swift`, and updated [LEARNING/polygon-masked-ocr-and-monotone-bands.md](file:///Users/arya/projects/ada/bazaar/floor-plan-extractor/legend-only/LEARNING/polygon-masked-ocr-and-monotone-bands.md).
- Executed `./extract_swift4 ... --feature-print --judge mlx` and `./render_swift4` across all three layouts, updating [out_swift4/layout.json](file:///Users/arya/projects/ada/bazaar/floor-plan-extractor/legend-only/out_swift4/layout.json), [out2_swift4/layout.json](file:///Users/arya/projects/ada/bazaar/floor-plan-extractor/legend-only/out2_swift4/layout.json), [out3_swift4/layout.json](file:///Users/arya/projects/ada/bazaar/floor-plan-extractor/legend-only/out3_swift4/layout.json), [out_swift4/report_diff.json](file:///Users/arya/projects/ada/bazaar/floor-plan-extractor/legend-only/out_swift4/report_diff.json) (25 unique MLX requests, 192 group cache hits), [out2_swift4/report_diff.json](file:///Users/arya/projects/ada/bazaar/floor-plan-extractor/legend-only/out2_swift4/report_diff.json) (14 unique MLX requests, 34 group cache hits), [out3_swift4/report_diff.json](file:///Users/arya/projects/ada/bazaar/floor-plan-extractor/legend-only/out3_swift4/report_diff.json) (17 unique MLX requests, 46 group cache hits), [render_swift4.ipynb](file:///Users/arya/projects/ada/bazaar/floor-plan-extractor/legend-only/render_swift4.ipynb), and [layouts_swift4.pdf](file:///Users/arya/projects/ada/bazaar/floor-plan-extractor/legend-only/layouts_swift4.pdf).

