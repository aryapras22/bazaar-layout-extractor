# Handoff: floor plan extractor, swift 5

Folder: `/Users/arya/Projects/ADA/bazaar/floor-plan-extractor/legend-only`. It is a git repo (initialised this session, local only, nothing pushed).

## Goal

Read a floor plan image and its legend image. Find each booth tile by legend colour, read its ID, extract walls, doors, pillars, and objects outside the legend, and write `layout.json`, `report_diff.json`, `overlay.png`, and `render.png`. An optional on-device MLX VLM judge (`--judge mlx`) classifies grouped objects and unresolved tiles once per group. The judge writes only to `report_diff.json`. It does not change `layout.json`.

Swift 5 is the same extractor as swift 4 split into a SwiftPM library (`Sources/Extractor`) with a thin executable (`fp-extract`) and tests. On all six plans its `layout.json` and `report_diff.json` are byte-identical to the last swift 4 build. `extractor/render_swift4.swift` is still the renderer. The single-file swift 4 sources and older tools are archived in `.archived`. Some JSON keys keep their swift 3 and swift 4 names (`swift4_items_per_class`) so outputs stay identical.

## What is in the folder

```
data/plan{1,2,3}/      layout.png, legend.png, truth.json (inputs and hand-checked ground truth)
data/plan4/            more-market: source.png (rotated scan), layout.png, legend.png; no truth yet (scripts/make_plan4.py)
data/plan5/            cosmo: source.pdf (vector), layout.png, legend.png, truth.json generated from the PDF (scripts/make_pdf_plans.py, scripts/make_plan5_truth.py)
data/plan6/            women-fest: source.pdf, layout.png, legend.png, truth.json generated from the PDF (scripts/make_plan6_truth.py)
extractor/             render_swift4.swift (renderer, compiled by hand into bin/)
scripts/               score.py (scorer), make_pdf.py (writes output/swift5/layouts.pdf), plan and truth generators
notebooks/             render_swift4.ipynb (predates this session's changes)
output/swift5/plan*/   layout.json, report_diff.json, overlay.png, render.png, crops/, judge_crops/ (generated, gitignored)
bin/                   compiled render_swift4 (gitignored); fp-extract is built into .build/release/
Package.swift         SwiftPM package, macOS 27
Sources/Extractor/     the extractor by stage: Imaging, Text, Model, Legend, Tiles (booth layer), Scan, WallLayer, DoorLayer, SeatLayer, Layers (the layer list and composer), Outside (wall helpers), Regroup, IdRepair, Judge, Tool
Sources/fp-extract/    four-line executable around ExtractTool.run
Sources/FloorPlanCore/, Sources/fp-fix/   older ID-repair library and tool; duplicates part of IdRepair, not merged yet
Tests/                 ExtractorTests (13) and FloorPlanCoreTests (9); all pass
LEARNING/              notes on tile detection, polygon-masked OCR with monotone bands, and the MLX VLM benchmark
.archived/             swift 1 to 4 sources, old notebooks and outputs, SAM3 experiment (mostly untracked)
```

Plan 1 is 2349 x 2871 (355 truth items), plan 2 is 1750 x 2106 (255), plan 3 is 3413 x 988 (124), plan 6 is 2304 x 2520 (281). `scripts/score.py` is the source of every number below. Plans 4 to 6 were not used to tune anything, and swift 4 does badly on them: it finds few tiles and reads no IDs, because their tiles do not match the legend colours (plan 4), the legend lists zones not booths (plans 5 and 6), or the booths are white boxes (plan 6). Plan 6's truth is generated from its PDF vector data. Plan 5 (cosmo) draws most booths another way and still needs a truth approach. `cluster.ipynb`, `map.json`, and `map.svg` in the root belong to a separate clustering experiment, not to swift 4.

## How to run

Run everything from the project root.

```
swift build -c release --product fp-extract
swiftc -O -parse-as-library extractor/render_swift4.swift -o bin/render_swift4

for n in 1 2 3 4 5 6; do
  .build/release/fp-extract data/plan$n/layout.png data/plan$n/legend.png --out output/swift5/plan$n --feature-print
done
bin/render_swift4

/Users/arya/miniconda3/envs/floor-plan-extractor-apple/bin/python scripts/make_pdf.py
/Users/arya/miniconda3/envs/floor-plan-extractor-apple/bin/python scripts/score.py
swift test
# optional: only some layers, e.g. --layers booth,wall (default is all four)
/Users/arya/miniconda3/envs/floor-plan-extractor-apple/bin/python scripts/scale_stress.py 1,5,6 2,3
```

`bin/render_swift4` with no arguments renders the three default output folders (plans 1 to 3).

Add `--judge mlx` for the VLM pass (25 s, 22 s, and 16 s for plans 1 to 3, conda env `floor-plan-vlm-bench`). If that env path is missing, the judge records `missing-env-floor-plan-vlm-bench` in `report_diff.json` and the run carries on without an error. The `--judge fm` mode only compiles with Swift 6.4 or later.

## Scores (from `scripts/score.py`, current outputs)

Tiles and tile IDs use IoU of at least 0.5. Objects, pillars, and doors use greedy matching at IoU of at least 0.3. Walls use pixel coverage within 6 px. Precision is matches divided by engine items of that class.

| | Plan 1 | Plan 2 | Plan 3 | Plan 5 (not tuned on) | Plan 6 (not tuned on) |
|---|---|---|---|---|---|
| Tiles found, precision | 160/160, 92% | 211/211, 100% | 68/68, 92% | 244/265, 81% | 280/281, 88% |
| Tile IDs exact, with `suggested_id` | 154/154, 154 | 208/209, 209 | 67/67, 67 | 224/265, 232 | 279/281, 279 |
| Objects | 136/141, precision 80% | 26/26, 59% | 8/11, 40% | no truth | no truth |
| Pillars | 18/23, precision 78% | 0/0, 1 false | 30/31, precision 94% | no truth | no truth |
| Doors | 0/10 | 0/4 | 0/1 | no truth | no truth |
| Walls, pixel recall / precision | 85% / 80% | 92% / 84% | not meaningful, see notes | no truth | no truth |

Before this session's changes: plan 1 objects 122/141 at 56% precision, pillars 0/23; plan 3 objects 0/11, pillars 25/31.

Notes on reading the table:
- Tiles match on box and ID only. Precision counts every engine tile, including real legend tiles the truth does not list: 9 `ENTRANCE` on plan 1, 3 `Seating` on plan 2, 6 `Tenant space` on plan 3. Class names equal the truth on every matched tile of plans 1 to 3 and on 270 of 281 on plan 6.
- Plan 5 truth is generated from the PDF by painting the coloured blocks, drawing every stroked line over them and taking each enclosed cell with one ID label (`scripts/make_plan5_truth.py`): 265 booths, not checked by eye. It leaves out cells with two labels, labels outside coloured blocks, and the small black-and-white stalls (`T`, `PERKOSMI`). PyMuPDF's `Rect.intersects` is false for a straight line, so clip tests on divider lines must compare bounds by hand.
- Plan 6 truth is generated from the PDF vector data by `scripts/make_plan6_truth.py`: 281 booths, not checked by eye. It leaves out two rectangles that hold two labels each and the sponsor boxes with no label. The plan prints `B38` and `B39` twice and the truth keeps both.
- The one plan 2 ID miss is `FI` read for printed `F1` (flagged as `suggested_id`). Plan 1 has a `prefix-conflict` suggestion on the plan's printed `D6` in the `C6` slot.
- Plan 3 truth has 8 tenant boundary regions, now classed `boundary` and not scored, and one `wall` that is the stairwell box. The plan 3 wall number is therefore meaningless until walls get real truth.
- The truth cleanup removed three plan 1 pillars that duplicated the `Blocked` tiles, so plan 1 pillar truth is 23.
- Doors: truth doors are door-leaf symbols (for example 62 x 24 px). The engine reports whole wall openings (140 to 395 px wide). They are different objects, so box shape is not the problem and doors need a swing-symbol detector.

## What changed this session

23. Noise: `noiseScore` (share of sampled pixels more than 24 from their 3x3 median, summed over channels) separates added pixel noise (0.09 to 0.16) from clean plans (0.01 to 0.04). Over 0.07 for a plan, or 0.04 for a legend (its white ground clips the noise), the image is smoothed with `sigmaFiltered`, a 3x3 average over neighbours within 30 per channel, which keeps edges and 1 pixel lines that a median filter would erase. Noisy variants: plan 1 0/160 to 160/160 tiles, plans 2 and 3 crash to 211/211 and 68/68, plan 5 0/265 to 243/265 (222 exact IDs). Pillars, walls and objects on noisy plans 1 and 3 are still mostly lost, because the ink passes are sensitive to the remaining noise; a second smoothing pass helped plan 1 walls (22% to 56%) but cost IDs, so it was not kept. All six clean plans are byte-identical.
24. `--upscale-small`, off by default: when small tiles (area-weighted 25th percentile of the legend-coloured regions) measure under 30 px, read the plan at 2x and scale every result back. Plan 5 gains 17 exact IDs (224 to 241), half-size plan 2 regains all 211 tiles, 26/26 objects (from 1) and 176/209 IDs (from 149), and rotated plan 5 recovers (101 to 247 tiles). It breaks plan 6 when that is faded (270 to 113) or halved (272 to 239) because the fixed outline cut (`darkPixels` below 60) loses lines that resampling lightens, and plan 3 objects collapse at 3x so the factor is capped at 2. Branch `experiment/outline-local-contrast` adds a local-contrast outline rule (a pixel much darker than its 11x11 neighbourhood counts as outline) that brings faded plan 6 under upscaling to 268 but still loses half-size plan 6 (242 against 267 unscaled) and costs 5 booths there even with upscaling off. Other tried and dropped: edge-slope and gray-percentile statistics cannot detect blur.

22. Layer scaffold, no behaviour change: the 290-line `outsideLayer` is split into a shared `scanInk` and four stages with their bodies unchanged: `wallLayer` (wall strokes) and `columnLayer` (solid and hollow squares) as the wall layer, `doorLayer` (gaps in wall bands) and `seatLayer` (what is left, as `object`). `layout.json` and `report_diff.json` are byte-identical on all six plans. Layers: booth (everything that is not one of the others, including tiles and sponsor boxes), wall (class `wall` and `pillar`), door, seat (class `object`). Each run also writes `booths.json`, `walls.json`, `doors.json` and `seats.json` next to `layout.json`, with the same item format plus a `layer` name, and `--layers booth,wall,door,seat` keeps only the named layers. A booth-only run is no faster: its time is booth ID reading, not the ink analysis. The wall, door and seat layers still need the booth layer's claimed areas, so they run it first. Decisions taken: walls own columns, seats own round tables with one shared circle detector still to build, one file per layer plus the merged file, and a text mask in each layer later.

19. `seat` field: objects carry an optional `seat` (true or false) taken from the judge's label (table with chairs and audience seating are seats; stairs, door, pillar, wall and noise are not). It is written only when the judge ran, so judge-off output is byte-identical on all six plans. Against the truth labels it is right on every matched object (136/136, 26/26, 8/8), but nearly all matched truth objects are seats, so that test has almost no negatives.
20. Diagonal wall truth (`scripts/make_wall_truth.py`, run after the booth truth scripts): the slanted wall strokes in the plan 5 and 6 PDFs, 2 and 6 segments, class `diagonal wall`. The scorer draws segments with thickness and reports "diagonal wall found". Swift 5 finds 0 of 2 and 0 of 6, because walls come only from horizontal and vertical runs (`longRuns`). Axis-aligned wall truth from the PDFs is not generated: zone dividers and stage outlines are stroked like walls.
21. Text erasing, tried and not shipped: painting every non-ID word out of plans 5 and 6 with the exact PDF word boxes made results worse (plan 5 tiles 244 to 236, plan 6 tiles 280 to 261 and objects 96 to 110), because the erase boxes cut the booth outlines and divider lines beside the text. Text leaks into about 10% of objects and 5% of walls today. A text mask that makes each layer drop detections lying mostly on text is the better direction.

18. Dark tiles (`tilePolygon`): the outline of a tile is the face (region between dark lines) holding most of its pixels, but a black tile is itself dark, so its only faces are the white text glyphs and the polygon became one glyph, which blanked the OCR crop. The face must now cover at least half the tile or the tile gets no polygon and a rectangular crop. Plan 6's sponsor booths recover: exact IDs 270 to 279 of 281. Other plans are unchanged.

17. Legend retry on near-silent classes: a class with one or two tiles is now retried like one with none, and moves to the most common similar-hue plan colour only if that colour has at least four times as many pixels as the class already matches. An uncropped page prints the legend inside the plan, so the goods swatch matched its own colour and the class never adapted. Plan 4's rotated scan, rotated upright by hand, run whole with its title block and legend box and upscaled 3x: 52 goods tiles and 29 valid IDs (same as the cropped plan), 14 of 22 food tiles with 7 valid IDs (cropped: 15 and 9). At its native 1x size the tiles are found (52 and 15) but no ID is read, because the text is too small for Vision. Plans 1 to 3, 5 and 6 are unchanged in score. The pipeline does not rotate pages by itself.

16. Page measure: every page-size threshold now uses the bounding box of the content (everything that differs from the most common colour) instead of the image, so margins around a plan change nothing (`contentExtent`, `Pixels.page`, `Pixels.area`, `Pixels.contentRect`). The two page-level Vision text passes read only that box (`recognizePageText`): on a 3x padded page Vision returned tall "text" boxes of digits with confidence 1.0 over rows of chairs, and the extractor erased the tables under them. The "large tile" test and the region cap in `tileScale` use the content area too. Result of `scripts/scale_stress.py` on plans 1, 2, 3, 5 and 6 padded 2x and 3x: tiles, IDs, objects, pillars and wall recall are identical to the unpadded plans, apart from wall recall on plan 3 (36.8% against 38.8%). Before this, plan 1 padded 3x kept 2 of 141 objects and 0 of 23 pillars at 2x, and plan 2 padded 2x kept none of its 26 objects. Unpadded plan 1 objects rise from 134 to 136 of 141.

15. Tile scale (`tileScale` in `Tiles.swift`): tile thresholds followed the page size, so a plan whose booths are small for its page lost them. Padding plans with white margins showed it: at 3x padding plan 1 fell to 27% of its booths, plan 5 to 3% and plan 6 to 6%. The scale is now the smaller of the page scale and the area-weighted 25th percentile of legend-coloured region sizes divided by 25 px, so it shrinks for small tiles and never grows. The minimums (erosion radius, `minArea`, seam length, the `outlinedLayer` minimum side) follow it; the upper bounds (largest hole, largest booth side) stay on the page scale, because larger booths exist on the same plan; tiles admitted only because the minimum shrank are kept only in labelled classes. Padded plans now score about the same as unpadded (plan 1 x3: 156/160 booths, plan 5 x3: 242/265, plan 6 x3: 278/281). On the unpadded plans plan 5 gains 2 booths and 1 ID and plan 6 loses `M3` and `M15`, both Vision reading a crop one pixel different; plans 1, 2 and 3 do not change. `scripts/scale_stress.py` reruns the padding test.

14. Swift 5: the 2,433-line `extract_swift4.swift` is split by line range, with no code edits except the entry point, into `Sources/Extractor` (ten files, internal access), run through a public `ExtractTool.run(arguments:)`. Outputs for all six plans are byte-identical to swift 4. Seven new tests cover label cleaning, hole filling, the three ID repairs, class prefix dominance and the legend swatch test. The default output folder is `output/swift5/plan1`.

11. Plan-wide ID repair (`repairIdsByPrefix`), as suggestions only (`suggested_id`, `id` is never overwritten): a two-letter prefix whose last letter looks like a digit and that is less common than its shortened form becomes the zero-padded ID (`NO4` to `N04`, 9 on plan 5); a prefix under a third as common as a one-letter-different neighbour (C and G, B and E) takes the neighbour (`CD28` to `GD28`); a duplicated ID of full series width tries single-digit swaps (1 and 7, 3 and 8 and so on) and is suggested only if exactly one lands on a missing number. Plan 5 gains 8 correct suggestions and 1 wrong (`FO1` for `F07`); plan 4's goods and food booths with a valid ID go from 26 and 7 to 29 and 9. Plans 1 to 3 and 6 get no new suggestions.
12. `computeClassPrefixes` now needs the leading prefix to cover at least 70% of a class's IDs. Before, a class holding many prefixes (plan 5's countries) got one arbitrary prefix and `id-pattern` flagged 199 tiles for review.
13. The Cyrillic lookalike table gains `М`, `Р` and `Т`.

10. Small tiles (`legendLayer`): the class mask is eroded by about 3 px before the `minArea` test, so a 24 x 27 px booth (648 px restored) fell to 378 px and was dropped. The size test now uses the restored box. Tiles that pass only that way are kept only when their class turns out to be labelled (at least half its tiles read an ID), because the unlabelled `Entrance` class gained eight thin fragments on plan 1 otherwise. Plan 5 went from 101 to 242 of 265 booths and from 94 to 222 exact IDs; plans 1 to 3 and 6 are unchanged. Rendering the plan at a larger zoom does not help, since booth size and every threshold scale together.

9. Legend colour adaptation (`adaptLegendToPlan`): when a legend class finds no tiles, `legendLayer` runs again with that class moved to the most common plan colour of similar hue (within 45 delta E and 40 degrees) that no other class already explains. The most common colour wins, not the nearest, because anti-aliased edge colours sit nearer the swatch than the flat fill does. Plan 4's goods booths went from 0 to 52 tiles, matching the legend's total of 52, with 26 valid IDs (`GD1` to `GD52` are printed on the plan), 5 misread (`CD28` for `GD28`) and 21 unread. Plans 1 to 3 and 6 are unchanged.

7. Legend parsing (`readLegend`): an entry now needs a real swatch, a bounded block of one colour left of its text, measured against the legend's own background colour. Titles and bare lines no longer become classes, wrapped lines join the entry above, and a leading ":" is stripped. Plan 5's legend sits on a pale cyan ground, so every class was being given the background colour; plan 5 went from 4 tiles to 134 (106 IDs read, no truth to score against). Plan 1 loses the bogus `Class`, `Wall`, `Seating` and `Audience area` classes, which moves its tile precision from 95% to 93% and plan 2's from 99% to 100%.
8. `cleanLabel` accepts up to three letters before the digits, so `FNB12` reads. Plan 4's food booths now give 10 IDs, a few with OCR slips (`FN91`, `FNE2`).

5. Light booths: `outlinedLayer` finds closed light regions of booth size between dark outlines and keeps those where OCR reads an ID (for example `W12`). Plan 6 went from 11 to 281 of 281 tiles and from 0 to 271 of 281 exact IDs, with plans 1 to 3 unchanged. It adds about 45 ms per booth (plan 6 takes about 20 s, was 3 s).
6. The ID retry pass (`rereadTiles`) now also covers unlabelled tiles between 0.5 and 2.5 times the median size of tiles that have IDs. It recovered one plan 6 ID (`M15`).

1. Hollow square pillars: fill small closed holes in the ink, open past the wall-line width, keep square cores (`outsideLayer`). Five north-wall squares on layout 1 stay missed because the `ENTRANCE` tile covers their bottom edge.
2. Area floor of 160 px² (at 2000 px max side, scaled by area) on object candidates.
3. OCR boxes under 0.5 confidence no longer erase ink. Vision read layout 3's table icons as "TEIL" at 0.3 and wiped them out. The handoff's earlier explanation (blue fills and grey pillars) was wrong.
4. Legend tiles over 1% of the image no longer mask ink inside them. This recovered the pillars inside tenant tiles (they are black, not grey). Side effect: more wall fragments, layout 2 wall precision fell from 94% to 88%.

## Benchmark summary (full tables in `LEARNING/hybrid-mlx-vlm-benchmark.md`)

Nine models on Apple M5, 24 GB, in `floor-plan-vlm-bench`. Qwen3.5-9B-MLX-4bit backs `--judge mlx`: 6.97 GB peak, 22.8 tok/s, 160/201 (79.6%) on non-noise items, but 30/52 on per-group accuracy. Qwen3.5-4B-MLX-4bit scores higher per group (34/52, 65.4%) because it rejects noise crops, at 4.11 GB. All nine models read the 11 hard booth tiles correctly, so that test does not separate them, and four of the 11 now read correctly without the judge. The two models added later do not displace the 9B: `gemma-4-26b-a4b-it-4bit` gets 33/52 groups but only 145/201 non-noise items in 111s at 16.1 GB, and `Qwen3.8-27B-4bit` gets 146/201 in 142s at 17.3 GB. Qwen3.8-27B ties the best box detection at 11/20 (mean IoU 0.598) but at 7.5 tok/s and 17.7 GB. The benchmark scripts live outside this folder, in `~/.gemini/antigravity-cli/brain/.../scratch/`, so it cannot be rerun from here; phase 1 there now reads `data/plan1/` and must be run from the project root. VLM bounding-box detection tops out at 11/20 boxes and cannot replace `legendLayer`.

## Robustness (scripts/robustness.py)

`scripts/robustness.py 1,2,3,5,6` degrades each plan (half and double size, 90 degree rotation, 1 degree skew, margins, JPEG quality 40, blur, pixel noise, faded colours), moves the truth the same way, runs `fp-extract` and prints one table to `output/robustness/report.md`. Set `FP_EXTRACT` to test another binary. Baseline failures before the noise fix, original in parentheses:

| Transform | What breaks |
|---|---|
| Pixel noise | plan 1 0/160 tiles (160), plans 2 and 3 crash, plan 5 0/265 (244): now fixed |
| Half resolution | objects 1/141, 1/26, 3/11 (136, 26, 8); plan 3 tiles 35/68 and no IDs; plan 5 tiles 89/265 and no IDs |
| Blur (sigma 1.2) | plan 2 tiles 123/211, plan 3 walls 0%, plan 5 no IDs, plan 6 tiles 11/281 (280) |
| JPEG quality 40 | plan 3 objects 0/11, pillars 6/31, walls 0%; plan 5 tiles 78/265 |
| Faded colours | plan 2 tiles 123/211, plan 6 tiles 270/281 |
| 1 degree skew | wall coverage 85% to 65% (plan 1), 92% to 81% (plan 2), 37% to 0% (plan 3); plan 3 objects 1/11 |
| 90 degree rotation | plan 5 tiles 101/265 and no IDs |
| Double size, margins | no loss |

## Environments

macOS 27.0.1, Apple M5, 24 GB, Swift 6.4. `Package.swift` requires macOS 27. Conda env `floor-plan-vlm-bench` (Python 3.12, `mlx-vlm==0.7.10`) runs `--judge mlx`. Conda env `floor-plan-extractor-apple` (`opencv`, `numpy`, `scipy`, `matplotlib`, `jupyter`) runs `score.py` and the render notebook.

## Open items

- Judge output never reaches `layout.json`: `runJudge` takes `items` by value and returns only a report. `agreed_with_rule` is 0 and `compared_with_rule` is 1 on layout 1, so nothing yet measures whether the judge is right. Decision pending after the object noise work above; current recommendation is to keep it report-only.
- Plan 6 extra tiles (37) are mostly real legend tiles the truth does not list (22 `FACILITIES`, 6 sponsor boxes, 4 `GRID NETWORK`), plus `M21` and `B75`, which are real booths the truth skipped as ambiguous.
- Plan 4 (more-market): 52 goods tiles but only 29 valid IDs (including suggestions), and 15 of 22 food booths with 9 valid IDs. Unread IDs are the main gap.
- Plan 5 (cosmo): 242 of 265 booths found, 223 exact IDs and 231 with `suggested_id`. The 23 missed booths and 34 booths with a wrong or missing ID remain; the biggest group is a dropped last digit (`P2` for `P26`, `J3` for `J39`), which no repair rule can recover without geometry. Booths are about 24 px, coloured blocks cut into stalls by thin divider lines, and the legend is printed inside the plan.
- Walls: no diagonal wall is found (0 of 8 on plans 5 and 6) and no circle is detected, so round columns and round tables are missed.
- Next planned work, pending your decisions: a layered pipeline (booth, wall, door, seat), each layer with its own output file, truth and score rows, and `layout.json` kept as the merged file.
- Doors need a detector for door-leaf symbols (see above).
- Object precision is still 40% to 79%. Layout 3 misses 3 of 11 objects.
- Layout 1 pillars: 5 north-wall squares missed behind `ENTRANCE` tiles, 4 false pillars at wall corners and the south wall.
- `symbol` items (7, 4, 4 in the truth files) are never emitted and are not scored.
- `notebooks/render_swift4.ipynb` still holds outputs from before this session; rerun it or drop it in favour of `bin/render_swift4`.
- `.archived/` (except `swift3/extract_swift3.swift`), `notebooks/`, and `output/` are not tracked in git.
