# Handoff: floor plan extractor, swift 5

Folder: `/Users/arya/Projects/ADA/bazaar/floor-plan-extractor/legend-only`. Git repo, branch `master`, remote `origin` is https://github.com/aryapras22/bazaar-layout-extractor. Written 2026-10-30. The previous handoff, with its long changelog of items 1 to 30, is in git history before this commit.

## State of play

- `master` holds the four layers (booth, wall, door, seat), the robustness work and booth round 2 (`layer/booth-2`, merged as `3f5bd53`). 37 extractor tests and 9 older ones pass.
- `origin/master` is at the merge `3f5bd53`; only this handoff commit is local. Pushing needs an explicit ask from the user.
- The clean-plan scores below and the stress rows for plans 2, 3, 5 and 6 (half, jpeg40, blur, faded) were rerun by me on the merged build and match the booth agent's report. The full `robustness.py 1,2,3,5,6` battery was not rerun.
- Local branches not on the remote: `layer/booth`, `layer/wall`, `layer/door`, `layer/seat`, `layer/booth-2` (all merged), `experiment/outline-local-contrast` (parked, not merged), and several `worktree-agent-*` branches made by the agent tool. The booth-2 worktree is still at `.claude/worktrees/agent-a332e465f47c88c4a`. Deleting branches or worktrees needs the user's say.
- Uncommitted and not mine: the `.env` line in `.gitignore`, `notebooks/extract_interactive.ipynb`, `scripts/make_pdf.py`.

## Goal

Read a floor plan image and its legend image. Find booth tiles by legend colour and read their IDs, then find walls (including diagonal ones), doors, pillars and seats. Write `layout.json`, `report_diff.json`, `overlay.png`, `render.png` and one JSON per layer (`booths.json`, `walls.json`, `doors.json`, `seats.json`).

The extractor is a SwiftPM library (`Sources/Extractor`) with a thin executable (`fp-extract`). Some JSON keys keep their swift 3 and 4 names (`swift4_items_per_class`).

## How a run flows

```
fp-extract (Sources/fp-extract) → ExtractTool.run (Tool.swift)
  → readLegend (Legend.swift): swatches, labels, wrapped lines
  → booth layer
    → legendLayer, adaptLegendToPlan, outlinedLayer, rereadTiles (Tiles.swift)
    → region splitting for merged booths, enlarged strips for unread tiles (round 2)
    → repairIds, repairIdsByPrefix (IdRepair.swift), suggestions only
  → scanInk (Scan.swift), shared by the other three layers, in the order of Layers.swift
    → wallLayer, columnLayer (WallLayer.swift, Outside.swift)
    → doorLayer (DoorLayer.swift, DoorArcs.swift)
    → seatLayer (SeatLayer.swift)
  → optional: runJudge (Judge.swift), verifyDoors (DoorVerify.swift), model ID reader (IdReader.swift)
  → layout.json, report_diff.json, per-layer files, overlay.png
```

Wall owns classes `wall` and `pillar`, door owns `door`, seat owns `object` (items carry `kind: "chair"` or `"chair_group"`, `chairs: N`, `seat: true`), booth owns everything else. The wall, door and seat layers need the booth layer's claimed areas, so a booth-only run is no faster.

## What is in the folder

```
data/plan{1,2,3}/      layout.png, legend.png, truth.json, seats.json (detector output checked by eye, not independent)
data/plan4/            more-market: layout.png, legend.png, columns.json (15 round columns); no booth truth
data/plan5/            cosmo: source.pdf, layout.png, legend.png, truth.json generated from the PDF
data/plan6/            women-fest: source.pdf, layout.png, legend.png, truth.json generated from the PDF
extractor/             render_swift4.swift, the renderer, compiled by hand into bin/
scripts/               score.py, robustness.py, scale_stress.py, make_pdf.py, truth generators (make_plan5_truth, make_plan6_truth, make_wall_truth, make_door_truth, make_pdf_plans, make_plan4)
Sources/Extractor/     the stages above, plus Imaging.swift (noise, upscale, content extent), Text.swift (label cleaning, page OCR), Model.swift, Regroup.swift
Sources/FloorPlanCore/, Sources/fp-fix/   older ID-repair library and tool, overlaps IdRepair, not merged
Tests/                 ExtractorTests (37), FloorPlanCoreTests (9)
LEARNING/              notes: tile detection, polygon-masked OCR, reading degraded tiles, slanted walls, door arcs, chair detection, the VLM benchmark
.archived/             swift 1 to 4 sources, old notebooks and outputs, SAM3 experiment (mostly untracked)
```

Truth for plans 5 and 6 comes from the PDF vector data. Run order matters: the booth truth script first (`make_plan5_truth.py` or `make_plan6_truth.py`), then `make_wall_truth.py`, then `make_door_truth.py`, because the later scripts append to `truth.json`. PyMuPDF's `Rect.intersects` is false for zero-height rects, so compare bounds by hand. Plans 5 and 6 truth were not checked by eye. `output/` and `bin/` are generated and gitignored.

## How to run

From the project root. The scorer and robustness script need `cv2`, which the default `python3` lacks; use the conda env `floor-plan-extractor` or `floor-plan-extractor-apple`.

```
swift build -c release --product fp-extract
swift test

PY=/Users/arya/miniconda3/envs/floor-plan-extractor/bin/python
.build/release/fp-extract data/plan1/layout.png data/plan1/legend.png --out output/swift5/plan1 --feature-print
$PY scripts/score.py output/swift5/plan1/layout.json data/plan1/truth.json
$PY scripts/robustness.py 1,2,3,5,6                  # about 15 minutes, writes output/robustness/report.md
$PY scripts/robustness.py 3,5 half,blur              # plans, then transforms
```

`FP_EXTRACT` selects another binary for `robustness.py`. Flags beyond `--out` and `--feature-print`:
- `--layers booth,wall,door,seat` keeps only those layers.
- `--upscale-small` reads plans whose small tiles measure under 30 px at 2x. It is off because it breaks faded and halved plan 6.
- `--judge off|mlx|fm` labels object groups and adds seats. `fm` needs Swift 6.4 and was never benchmarked.
- `--verify-doors` asks Qwen3.5-9B about each door candidate.
- `--model-ids` asks Qwen3.5-9B to read unread tile IDs into `suggested_id`.
- `--no-repair`, `--no-reread`, `--no-bridge`, `--no-regroup` switch single steps off.

The model flags need the conda env `floor-plan-vlm-bench` and the lock directory `/tmp/fp-vlm.lock`, so one model process runs at a time on this 24 GB machine. A missing env is recorded in `report_diff.json` and the run carries on. Vision OCR varies by about one tile or one ID between runs of the same binary on plan 5, so compare by score.

## Scores, clean plans (rerun on the merged build, `3f5bd53`)

Tiles and IDs use IoU of at least 0.5 on box and ID. Objects, pillars and doors use IoU of at least 0.3.

| | Plan 1 | Plan 2 | Plan 3 | Plan 5 | Plan 6 |
|---|---|---|---|---|---|
| Tiles found, precision | 160/160, 92% | 211/211, 100% | 68/68, 92% | 248/265, 78% | 280/281, 88% |
| Tile IDs exact (with suggestions) | 154/154 | 208/209 (209) | 67/67 | 243/265 (244) | 279/281 |
| Objects, single chairs excluded | 137/141 | 26/26 | 8/11 | no truth | no truth |
| Chairs against checked lists | 744/744 | 104/104 | 36/36 | no truth | no truth |
| Doors (swing symbols) | 3/6 | 4/4 | 0/1 | 9/89 | 20/44 |
| Diagonal walls | - | - | - | 2/2 | 5/6 |
| Walls, pixel recall / precision | 89% / 81% | 98% / 86% | not meaningful | no truth | no truth |

Objects, chairs, doors and walls were not rerun for round 2; they are from the merge of the four layers, and round 2 only touched the booth layer.

Reading the table:
- Precision counts every engine tile, including real legend tiles the truth does not list (`ENTRANCE` on plan 1, `Seating` on plan 2, `Tenant space` on plan 3, `FACILITIES` and sponsor boxes on plan 6). Plan 5 precision fell from 81% to 78% in round 2 (317 engine tiles against 306): the extras are small MALAYSIA tiles.
- Plan 3 truth has one `wall`, a stairwell box, so its wall numbers mean nothing.
- Truth doors are swing symbols. Plan 1's truth also holds four non-swing entries, relabelled to class `gate`; gates score separately at 0/4 because no gate detector exists.
- The one plan 2 ID miss is `FI` for printed `F1`, flagged in `suggested_id`.

Plan 4 has no booth truth: 52 goods tiles with 40 valid IDs (50 with `--model-ids`), 15 of 22 food tiles with 9 valid IDs, 12 of 15 columns.

## Robustness (`scripts/robustness.py`)

It degrades each plan (half, double, rot90, skew1, pad2, jpeg40, blur, noise, faded), moves the truth the same way, runs `fp-extract` and scores. Against the first run before any robustness work, the build before round 2 was better in 48 of 173 cells, worse in 2 and within tolerance in the rest.

Round 2 results, before to after, rerun on the merged build:

| Row | Tiles | IDs |
|---|---|---|
| Plan 3 half | 35 to 68/68 | 0 to 67 |
| Plan 5 JPEG 40 | 107 to 208 | 91 to 185 |
| Plan 5 blur | 200 to 244 | 102 to 133 |
| Plan 6 half | 267 to 274 | 266 to 273 |
| Plan 6 faded | 270 to 278 | to 277 |
| Plan 5 half | 89 to 196 | 0 (text is 4 px) |

Rows that held: plan 6 blur 274 tiles, plan 2 blur and faded 211, plan 6 JPEG 40 280 with 278 IDs, plan 3 at 68/68 tiles and 67 IDs on all four degraded rows. The plan 1 stress rows, the plan 5 noise row and the double, rot90, skew, pad and noise rows of the other plans were not rerun after the last booth fix (`29c9726`, which only tightens region splitting). A full `robustness.py 1,2,3,5,6` run is the check still owed.

## Where a model is used

The default pipeline is classical image processing, Apple Vision text recognition and Apple image feature prints. A VLM runs only behind flags, always to read or verify a crop, never to find a box. The benchmark of nine models showed they classify well and localise badly: the best box detection was Qwen3.8-27B at 11/20 with mean IoU 0.598, at 7.5 tok/s and 17.7 GB, against tile counts of 160/160 and 280/281 from colour and ink rules.

- `--judge mlx` (Qwen3.5-9B): object groups and the seat flag, 160/201 items right on non-noise items, 3 false seats on plan 1. It only adds seats.
- `--verify-doors`: drops 15 of 27 false door candidates and 4 of 36 true ones, tuned on the same crops.
- `--model-ids`: plan 4 goods go from 39 to 50 valid IDs in about 30 s. On plan 5 blur it found 13 correct and 10 wrong suggestions on 71 asked in about two minutes, so the booth agent reverted its widened gate.

Benchmark tables are in `LEARNING/hybrid-mlx-vlm-benchmark.md`. The benchmark scripts live outside this folder, so it cannot be rerun from here.

## Decisions and dead ends

- `--upscale-small` stays off. Upscaling cannot bring back dividers a half-size resize already lost (plan 3 half fell from 35 to 25 tiles), and it breaks faded and halved plan 6.
- Text erasing with exact PDF word boxes made scores worse because the erase boxes cut booth outlines. A per-layer text mask that drops detections lying mostly on text is the direction left open.
- `experiment/outline-local-contrast` fixes faded plan 6 under upscaling (113 to 268) but half-size plan 6 still loses. Not merged.
- Region splitting for merged booths requires at least two cells, half of them with different IDs sharing a letter prefix. The prefix test was added after a sponsor box split wrongly on plan 6 JPEG 40.
- A fade fitted on fewer than four moved classes is not applied to black and grey. With two it turned plan 1 JPEG 40's black swatch grey and cost three tiles.
- A whole-row swatch scan up front broke plan 1; the legend retry near the text is used instead.
- Voting across page OCR passes gave no gain over the most confident read.
- ID repair never overwrites `id`; it writes `suggested_id` with a rule name. A prefix needs 70% dominance in its class (`computeClassPrefixes`).
- Page-size thresholds use the content box, not the image, so margins change nothing (`scripts/scale_stress.py` checks this on padded plans).

## Open items

- Plan 4 food booths: FNB10 to FNB20 break into top and bottom strips around large text and are never found.
- Plan 5 blur IDs are capped near 130 by Vision, and H read as K repeats. Plan 5 half has no IDs.
- Plan 6 half still misses S6, S8, W1, W9, W14, M7 and M18. Plan 5 loses 17 booths on the clean plan, mostly a dropped last digit (`P2` for `P26`) that no repair rule can recover without geometry.
- Plan 3 blur walls are 0%. Wall truth for the raster plans does not exist.
- Door layer: gates and X boxes are not detected, plan 1 has 3 of 6, plan 5 has 9 of 89, and without `--verify-doors` 40% to 73% of candidates are false.
- Seat layer: round tables versus round columns, the plan 3 audience block, half-size chairs, and precision on noisy plans. Object precision is 40% to 79%.
- Plan 1 pillars: 5 north-wall squares are missed behind `ENTRANCE` tiles and 4 pillars are false.
- Judge output never reaches `layout.json`. Current recommendation is to keep it report-only.
- `symbol` items in the truth files are never emitted or scored.
- `notebooks/render_swift4.ipynb` holds old outputs. `Sources/FloorPlanCore` and `fp-fix` duplicate part of `IdRepair.swift`.
- `.archived/` (except `swift3/extract_swift3.swift`), `notebooks/` and `output/` are not tracked in git.

## Environments

macOS 27.0.1, Apple M5, 24 GB, Swift 6.4. `Package.swift` requires macOS 27, tools-version 6.0, language mode 5, tests use Swift Testing. Conda env `floor-plan-vlm-bench` (Python 3.12, `mlx-vlm==0.7.10`) runs the model flags. Conda envs `floor-plan-extractor` and `floor-plan-extractor-apple` (`opencv`, `numpy`, `scipy`) run `score.py`, `robustness.py` and the PDF scripts.
