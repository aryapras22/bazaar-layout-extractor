# Bazaar layout extractor

Reads a floor plan image of an indoor bazaar hall and its legend, and writes what is on it: booth tiles with their IDs, walls, doors, pillars, tables and chairs. The truth for scoring is `data/planN/truth.json` (see `data/README.md`).

```bash
swift build -c release                      # macOS 27, Apple Vision
.build/release/fp-extract data/plan1/layout.png data/plan1/legend.png      # writes output/extractor/plan1
python3 scripts/score.py                    # every plan against its truth
python3 scripts/score.py --layer seat       # one pipeline at a time: booth, wall, door or seat
swift test
```

## The pipeline

`ExtractTool.run` (`Sources/Extractor/Tool.swift`) is a list of stages, each a method of `PlanRun` (`Pipeline.swift`).

| Stage | Does | Code |
|---|---|---|
| load | read plan and legend, remove noise, enlarge small prints | `PlanRun.load`, `Legend.swift`, `Imaging.swift` |
| booths | tiles from the legend colours and from outlines, then claim their pixels | `findBooths`, `Tiles.swift` |
| outside | the ink that is not a booth, text or label, read by three layers | `findOutside`, `Layers.swift` |
| ids | reread blank tiles, bridge walls, regroup objects, repair IDs from the numbering | `readIds`, `IdRepair.swift`, `Regroup.swift`, `IdReader.swift` |
| review | judge, door check and VLM fix: flag or drop items | `review`, `Judge.swift`, `DoorVerify.swift`, `VlmFix.swift` |
| write | `layout.json`, one file per layer, `report_diff.json`, `overlay.png` | `write`, `Model.swift` |

## The four layers

Each layer has its own file, its own output (`booths.json`, `walls.json`, `doors.json`, `seats.json`), its own lines in `score.py --layer`, and its own note in `LEARNING/`. They improve one at a time.

| Layer | Finds | Code | Score lines | Note |
|---|---|---|---|---|
| booth | tiles and their IDs | `Tiles.swift`, `IdRepair.swift` | tiles, tile ids | `tile-detection-by-solidity`, `reading-degraded-tiles`, `polygon-masked-ocr-and-monotone-bands` |
| wall | walls, slanted walls, columns | `WallLayer.swift`, `Outside.swift` | wall, pillar | `slanted-walls-and-page-tilt` |
| door | swing symbols | `DoorLayer.swift`, `DoorArcs.swift`, `DoorVerify.swift` | door | `door-swing-arc-detection` |
| seat | chairs, tables, chair-to-table links | `SeatLayer.swift` | chair, table, links | `chair-detection-by-ink-holes` |

`scripts/seat_layer_mirror.py` is a Python copy of the seat layer that runs without macOS, for trying a change before porting it.

## Where each layer stands

These are the last recorded runs, made before the metre truth, and the seat scores come from the Python mirror. Nothing was re-run on a Mac against the new truth, so run `score.py` first and replace this table with what it prints.

| Layer | Last known (old truth) | Open |
|---|---|---|
| booth | tiles found 160/160, 211/211, 68/68, 248/265, 280/281 on plans 1, 2, 3, 5, 6; IDs exact on all but plan 5 (243/265) | plan 5 blurred and half-printed IDs; the new truth has 41 more booths on plan 5 and 8 more on plan 6 |
| wall | pixel recall 89% and 98%, precision 81% and 86% on plans 1 and 2; slanted walls 2/2 and 5/6 | plans 3, 5, 6 never scored on straight walls; the new truth adds hall edges |
| door | swing symbols 3/6, 4/4, 0/1, 9/89, 20/44 | the layer finds every swing symbol, the new truth keeps only the main openings, so the score needs a new definition |
| seat | all 171 tables and every chair link on plans 1 to 3 (mirror) | plan 6 rectangular benches, plan 3 square audience cells, chairs on small prints |

## Folders

```
Sources/Extractor    the pipeline (library)        Sources/fp-extract   the command
Sources/FloorPlanCore, fp-fix                      repair of a finished layout
Tests                swift test                    data/planN           inputs and truth
scripts              scoring, truth builders       LEARNING             one note per technique
notebooks            truth render, VLM runs        .archived            swift3, swift4, swift5, not maintained
```
