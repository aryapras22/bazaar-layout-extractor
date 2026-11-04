# Plan: improve the output on plans 1 and 2

Plans 1 and 2 first because they have the cleanest truth: every table and chair is checked, the stage and walls are traced, and booths, tables and chairs already score near the ceiling in the last recorded run. What is left is mostly the other layers and the step from pixels to the metre schema.

## 0. Baseline (one session on the Mac)

Nothing has run since the truth changed, so every number below is old. Run this first and paste the output into the table in section 5.

```bash
swift build -c release && swift test
for p in 1 2; do .build/release/fp-extract data/plan$p/layout.png data/plan$p/legend.png; done
python3 scripts/score.py output/extractor/plan1/layout.json data/plan1/truth.json output/extractor/plan2/layout.json data/plan2/truth.json
python3 scripts/robustness.py 1,2
```

Then do the same with `--verify-doors` and `--judge mlx`, to see what the review stage adds.

## 1. Last known state

| | Plan 1 | Plan 2 | Source |
|---|---|---|---|
| Tiles found, precision | 160/160, 92% | 211/211, 100% | handoff, old truth |
| Tile IDs exact | 154/154 | 208/209 (`FI` for `F1`) | handoff |
| Objects | 137/141 | 26/26 | handoff |
| Chairs | 744/744 | 104/104 | handoff |
| Tables, chair links | all 136, all 744 | all 26, all 104 | seat mirror, not yet on a Mac |
| Swing symbols | 3/6 | 4/4 | handoff |
| Walls, pixel recall / precision | 89% / 81% | 98% / 86% | handoff |
| Pillars | 5 north-wall squares missed, 4 false | none in truth | handoff |

## 2. Make the score mean something

Do these before tuning, or a gain cannot be told from a change of the ruler.

1. Doors. The truth now holds the openings of the door wall (2 per plan). The layer reports every swing symbol. Score door recall against the 2 openings, and report extra symbols as a separate count, not as false doors. Decide whether the extractor should output openings (see section 4).
2. Precision. List the engine tiles that match nothing, by class. On plan 1 they are legend items the truth keeps as fixtures (`ENTRANCE`, `DOORPRIZE BOOTH`, `BLOCKED`, decor), on plan 2 `Seating`. Either score them as fixtures or drop them from the tile count, so precision reads 100% when the booths are right.
3. Walls. The truth now has hall edges at 0.3 m. Check the wall score against the old 89% and 98% on the same pixels before reading any change.

## 3. Work items, in order

Each item changes one layer, is read with `score.py --layer <name>`, and ends with the numbers on both plans.

| # | Layer | Problem | Idea | Measure |
|---|---|---|---|---|
| 1 | booth | plan 2 reads `F1` as `FI` | letter and digit repair by class prefix: after a numbered prefix, `I` and `l` are `1`. `IdRepair` already has the neighbour numbering; add a glyph rule. | tile ids 209/209 on plan 2, no loss on plan 1 |
| 2 | booth | plan 1 extra tiles (8% of the count) | tag legend items that are not booths (`ENTRANCE`, decor) with their own class instead of a booth class | precision |
| 3 | wall | plan 1 precision 81%: dimension lines, stage and seating-enclosure edges read as walls | require a wall to join another wall or the hall edge; drop short runs inside the audience block | wall precision, recall held at 89% or more |
| 4 | wall | pillars: 5 north-wall squares hidden behind `ENTRANCE` tiles, 4 false | search for squares in the claimed band along a wall; reject squares that are a letter box or a booth corner | pillar 27/27 on plan 1 |
| 5 | door | swing symbols are found, the main openings are not | take the openings from the wall layer: a gap in the long wall with a swing symbol or a jamb on each side. Output `door` boxes for the gap, keep swing symbols as evidence | 2/2 on both plans, 0 extra |
| 6 | seat | tables and links look done in the mirror | port check on a Mac; then stage box (empty large box, plan 2 is a guess) and audience grids | tables 136 and 26, stage found on plan 1 |
| 7 | seat | objects 137/141 on plan 1 | read the 4 misses on the overlay | objects 141/141 |
| 8 | ids | plan 2 and plan 1 stress rows not rerun after the last booth fix | run `robustness.py 1,2` and keep the table | no row worse than the handoff |

Order by cost: 1 and 2 are small, 3 and 4 are medium, 5 is the largest and also the one the new truth needs most.

## 4. New step: from pixels to the metre schema

The extractor outputs boxes in pixels. The truth is metres with a hall polygon, door roles, a stage and a scale. A small exporter turns one into the other, and is where the remaining plan 1 and 2 truth fields get their first machine value.

| Field | Plan 1 source | Plan 2 source |
|---|---|---|
| scale | stage label `6x12m` (33.6 px/m), or a printed booth size | none printed: needs a booth size from the user (the truth assumes A booths 2.5 m) |
| hall | bounding box of the wall layer, inner face | same |
| wall, doors | door wall = the long wall with gaps (item 5) | same |
| booths, tables, chairs, pillars | the layers, converted | same |
| stage, kids | stage item, seat grids | large unlabeled box, a guess |
| gates, exit point, roles | in front of each door, entrance and exit from the IN and OUT labels | same |

Write it as a sixth stage in `PlanRun` (`export`, off by default) and score it with the same checker as the truth (`scripts/check_metre_truth.py` on the output), so a route from the gate to every booth is a pass or fail.

## 5. Exit criteria

| | Baseline at 810379a (plan 1, plan 2) | Target |
|---|---|---|
| booth ids | 154/154 exact, 154/154 with suggested_id; 208/209 exact, 209/209 with suggested_id | 154/154, 209/209 exact |
| tile precision | 95.2% (fixtures 6/6 left out); 100% | 100% on both, extras counted as fixtures |
| walls, metre truth | recall 77.3%, precision 64.3%; recall 96.7%, precision 74.4% | recall 90 or more on the door wall and hall edges |
| walls, truth_px | recall 89.1%, precision 81.0%; recall 97.7%, precision 85.5% | precision 90 or more, recall 89 or more |
| pillars (plan 1) | 22/27, 23 engine | 27/27, no false pillar |
| doors | 2/2 with 9 swing symbols not in truth; 2/2 with 2 | 2/2 on both |
| objects, tables, chairs | fixtures 6/6; tables 136/136 and 26/26; chairs 736/744 and 104/104; links 736/736 and 104/104 | all links right |
| metre export | none | passes `check_metre_truth.py`, within 0.3 m of the truth on booths |

## 6. Guardrails

- Plans 3, 5 and 6 are not tuned on. After each item, run them and write down the change. A gain on plans 1 and 2 that costs a booth there is not kept.
- One item per commit, with its before and after score lines in the message.
- Thresholds stay in code with a comment saying which plan set them.
- Plan 2's scale and stage are assumptions in the truth. Ask for the real booth size before the metre export is judged on plan 2.
