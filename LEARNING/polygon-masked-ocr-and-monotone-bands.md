# Recovering missed booth labels with polygon masks and collinear bands

`extract_swift4.swift` recovers booth labels that crop OCR missed in `extract_swift3.swift` through two passes: polygon-masked upscaled re-reading in `rereadTiles` and collinear band ordering in `repairIds`.

## Why initial crop OCR misses sloped and small tiles

Cropping an axis-aligned bounding box around a trapezoid booth includes the corner of the adjacent booth and the diagonal outline between them. On small tiles, a fixed inset also clips outer glyph strokes or leaves too few pixels per character for Vision's text detector. Either artifact causes `RecognizeTextRequest` on the raw box crop to return an empty result.

## Polygon masking and page-level ownership

`rereadTiles` dumps the raw crops of unresolved tiles (`id == nil`) in labelled classes to `crops/` first so each failure can be inspected directly. For those unresolved tiles, it clips the tile crop to its `polygon` path on a white background, adds proportional white padding, upscales by 2x and 3x with high-quality interpolation, and runs `RecognizeTextRequest` again. `cleanLabel` strips leading and trailing non-alphanumeric border marks (such as dimension tick dots read as `"H71•"`) and enforces 1-2 letters followed by 1-3 digits so upside-down text (such as `"BOOTH"` read as `"H1OO8"`) cannot pass as a booth ID. A second pass runs `RecognizeTextRequest` once on the full plan with `minimumTextHeightFraction` scaled from the median tile short side over image height, then assigns each observation to the single labelled tile whose polygon (or box when no polygon exists) contains the observation center.

## Monotone ordering on perimeter-wrapping classes

When a booth class wraps around four walls of a hall, its coordinates are non-monotone across the full class even though numbering increments smoothly along each wall. `assignMonotoneSequence` tests full-class monotonicity along the dominant axis first, and falls back to checking whether all unresolved candidates share a single row or column band within one median tile long side. When the known IDs inside that band are strictly monotone along the band axis, assigning the missing numbers preserves strict monotonicity, and no known ID outside the band falls inside the band's numeric range, the gaps are assigned in axis order; otherwise nothing is proposed.

## Text-masked ink and group-level VLM labelling

Page-level OCR text boxes are masked out of `ink` before `longRuns`, and unconfirmed single-line wall segments require a minimum stroke of 2 pixels so 1-pixel dimension lines with text gaps (such as `"4"` corridor width arrows) do not split into false wall segments. Unclaimed object components use a 2-pixel dilation bridge (`rx: 2, ry: 2`) so 4-chair table clusters stay connected without merging across 5-pixel inter-table gaps, and store simplified convex-hull polygons so `render_swift4` draws octagon table outlines instead of bounding rectangles. When `--judge fm` or `--judge mlx` is enabled, `Judge.swift` caches by `regroupObjects` group ID and evaluates one composite crop (left: tight zoom, right: context with red bounding box) per group against structural categories (`table_with_chairs`, `audience_seating`, `stairs`, `door`, `pillar`, `wall`, `noise`).

## Pitfalls

- Hashing crops for Foundation Models caching must happen before drawing per-item `#n` badges, otherwise identical repeated shapes miss the cache because their badge numbers differ.
- Merging collinear walls across small pillar gaps must only group segments of compatible stroke width after thin runs between thick walls have been converted into `thickness-transition` doors, otherwise thin openings merge into adjacent thick walls.
