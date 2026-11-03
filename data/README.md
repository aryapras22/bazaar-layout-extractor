# Ground truth files

Each plan folder (`plan1`, `plan2`, `plan3`, `plan5`, `plan6`) holds the inputs and the truth for one floor plan. Plan 4 has no truth.

```
layout.png      the floor plan image
legend.png      its legend
source.pdf      the vector source (plans 5 and 6 only)
truth.json      the plan traced in metres, for the crowd simulation and the 3D viewer
frame.json      pixel scale and origin of truth.json on layout.png
truth_px.json   the older pixel truth: boxes in layout.png pixels, one item per detected thing
seats.json      checked chair boxes in pixels (plans 1 to 3), the input for the chair entries of truth.json
```

`truth.json` is written by the builders in `scripts/make_metre_truth_planN.py`. Do not edit it by hand: change the builder and rerun it.

```bash
pip install pymupdf opencv-python-headless scipy pillow numpy
for p in 1 2 3 5 6; do python3 scripts/make_metre_truth_plan$p.py; done
python3 scripts/check_metre_truth.py
```

## Coordinates

Metres, rounded to 0.01. The top-left corner of the hall is (1, 1), x grows right and y grows down. `meta.world` is the bounding box of hall and lobby plus 1 m. Every shape is an axis-aligned rectangle, except `hall` and `lobby`, which are polygons.

A rectangle is `{x0, x1, y0, y1}` with `x1 > x0` and `y1 > y0`. A centre-size rectangle is `{cx, cy, w, h}`, where `w` is the x extent and `h` the y extent.

## Keys

`truth.json` holds exactly these keys, in this order.

```
meta        name, sheet, world {w, h}, note. The note holds the scale, the counts and every judgement call for that plan.
hall        polygon of the walkable floor, clockwise, at the inner face of the outer walls
lobby       polygon of the foyer outside the door wall
wall        one thin rectangle, the straight outer wall that holds the doors
doors       {id, role, x0, x1, y0, y1}; role is entrance, exit or both; ids Door A, Door B in reading order
gates       [{id, sx, sy}] where visitors enter, a point inside the lobby
exitPt      {id, sx, sy} where visitors leave, a point inside the lobby
outerDoors  vertical lines {x, y0, y1} between the lobby and the outside; empty when not drawn
booths      {id, type, cx, cy, w, h}; type is goods, fnb or fit; id is the printed label, or U1, U2 for a booth with none
tables      tables and chairs, see below
stage       {x0, x1, y0, y1, face}; face is the side the audience stands on (x0, x1, y0 or y1)
kids        one rectangle: the audience block in front of the stage, or a 2 x 2 m corner box when none is drawn
pantia      always []
lobbyBlock  always {x0: 0, x1: 0, y0: 0, y1: 0}
columns     round pillars {x, y, d}
pilasters   {kind, x0, x1, y0, y1}; kind is wall, rail or block (a square pillar)
fixtures    solid objects {label, kind, x0, x1, y0, y1}; kind is fixture or stage (steps, extensions)
arrows      always []
closed      strips visitors may not enter; empty on every plan
```

### Tables and chairs

`tables` holds every table followed by its chairs. Entries keep `cx, cy, w, h` and add fields.

```
{"kind": "table", "table": 1, "cx": 15.35, "cy": 14.26, "w": 1.38, "h": 1.38, "rect": [1.28, 0.67], "angle": 135.0}
{"kind": "chair", "table": 1, "cx": 15.91, "cy": 14.53, "w": 0.33, "h": 0.33}
{"kind": "chair", "table": null, "cx": 18.54, "cy": 17.87, "w": 0.39, "h": 0.42}
```

- A table has `w` and `h` for its axis-aligned box, and `rect` and `angle` for its true size (long side, short side, in metres) and tilt in degrees. Tables are numbered 1 to n in reading order.
- A chair names its table in `table`. Chairs that belong to no table, such as audience rows, have `"table": null`.
- Table outlines are fitted to the drawn symbol in the image (`scripts/seating.py`). Chair boxes come from the checked `seats.json`.

### frame.json

```
{"px_per_m": 33.6, "origin_px": [59, 80], "image": {"width": 2349, "height": 2871}}
```

`pixel = (metres - 1) * px_per_m + origin_px`. The builders write it. `scripts/truth_loader.py` uses it to turn `truth.json` back into pixel boxes.

## The plans

| Plan | Booths | Tables, chairs | Stage | Scale |
|---|---|---|---|---|
| 1 | 154 goods | 136 tables, 744 chairs (200 in audience rows) | printed, 6 x 12 m | 33.6 px/m from the stage |
| 2 | 209 goods | 26 tables, 104 chairs | the large unlabeled red box, a guess | 25.6 px/m, assumed |
| 3 | 67 goods | 9 tables, 91 chairs (55 audience cells) | printed, 3 x 8.25 m | 33.5 px/m from the stage and booths |
| 5 | 306 goods | none drawn | the unfilled rounded box in Hall B, a guess | 9.1 px/m, assumed |
| 6 | 272 goods, 16 fnb, 1 fit | 20 tables, 40 benches as chairs | printed, 6 x 10 m | 20.67 px/m from the printed sizes |

Plans 2 and 5 print no sizes. Plan 2 assumes A booths are 2.5 m, F booths 2 m and the I blocks 5 m. Plan 5 assumes 3 m booths. Each assumption is one constant in its builder (`SCALE`, `SCALE_PT`). If the real size differs, change it and rerun.

Things to know when reading the files:

- The legends have no food class, so every booth is `goods`. Plan 6 is the exception: the FNB zone (S1 to S15) and COFFEE SHOP are `fnb`, and FITTING ROOM is `fit`.
- Plan 3 draws no outer wall, door wall or lobby. The red GATE bar is taken as the door, the hall ends at the gate line, and the strip east of it is the lobby.
- Plan 1 booths J1 to J4 and K1 to K10 stand in the lobby, outside the hall polygon. They are kept because they are drawn.
- Plan 5 labels L41, L44, C26, C27, B20 and B22 are outlined text, not in the PDF text layer, and were read by eye. One cell right of D22 prints no label and is `U1`.
- Plan 5 hall is traced from the wall lines as Hall B, the pre-function strip, the connecting corridor and Hall A.
- Things the plans draw but the truth leaves out are named in each `meta.note`.

## Checking and drawing

```bash
python3 scripts/check_metre_truth.py            # keys, extents, overlaps, table links, walkable route from the gate to every booth
python3 scripts/render_metre_truth.py data/plan1/truth.json out.png 40
```

The notebook `notebooks/render_truth.ipynb` draws every plan next to `layout.png`, and as an overlay on it, at 2x resolution (plans 5 and 6 are re-rendered from `source.pdf`). It also writes `output/truth_comparison.pdf`.

## Scoring the extractor

`scripts/score.py`, `scripts/robustness.py` and `scripts/scale_stress.py` read `truth.json` through `scripts/truth_loader.py`, which converts it to pixel items with `frame.json`.

- Booths become tiles with their ID, doors the openings in the door wall, tables entries chairs and tables, block pilasters and columns pillars, and the door wall, wall pilasters and hall edges walls.
- Tables are scored on box IoU 0.5, then centre, size and angle against `rect` and `angle`. Each matched chair is scored on whether it names the right table (both none counts as right).
- Diagonal walls, gates, object groups and swing-symbol boxes are not in `truth.json`, so they are no longer scored.
- `scripts/seat_layer_mirror.py` is a Python copy of the seat layer (chairs, tables, links). It runs without macOS and scores itself, so a seat-layer change can be tried here first.
- A file with an `items` list (`truth_px.json`, or the moved copies `robustness.py` writes) loads as it is.

`truth_px.json` for plans 5 and 6 comes from `scripts/make_plan5_truth.py`, `make_plan6_truth.py`, `make_wall_truth.py` and `make_door_truth.py`, run in that order.
