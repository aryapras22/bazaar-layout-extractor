# Door swing detection by circle voting

## What it is

A floor plan draws a door as a straight leaf plus the arc the leaf sweeps. The arc is part of a circle whose centre is the hinge and whose radius is the leaf length. `DoorArcs.swift` finds such arcs with a circle Hough transform and then checks each candidate against the picture. `DoorLayer.swift` keeps the arcs that stand on a wall and joins neighbouring arcs into one symbol.

## Why not the alternatives

Whole wall openings, the old door output, matched none of the 15 truth doors on plans 1 to 3: the drawn door sits inside the gap and its arcs are ink, so the gap test never sees an opening. Template matching needs one known symbol per plan, and the symbols differ between plans (bow tie, single leaf, two leaves). A circle vote needs only the radius range, which scales with the page.

The cost is false arcs wherever strokes happen to follow a circle for a while: chair rings, box corners where two thick lines meet, digits such as 2 and 3. Most of the code is rejection.

## How it works

1. Thin strokes are the ink minus text, solid blobs and thick shapes. Each thin pixel gets a stroke direction from the principal axis of the ink in a 9 x 9 window. Pixels on junctions have no clear direction and do not vote.
2. For each radius r, each pixel votes for the two points at distance r along its normal. A quarter circle puts about a quarter of its circumference of votes on its hinge. Local maxima of a 5 x 5 sum are candidates.
3. A candidate is checked by walking the whole circle. The ink must cover a run of 70 to 195 degrees, the rest of the circle must be nearly empty, a full ring is recorded as a circle and removes shifted arcs that share a stretch of it.
4. Along the run, the stroke must stay on the circle (mean radial offset within about 1 px or 6% of r) and keep a steady width. At most 30% of the run may break this, so the pinch of a bow tie, where two arcs touch, still passes.
5. One end of the arc must have a leaf: ink all along the radius to that end, stopping at the arc end. A line that runs on past the arc end is a wall or a table edge. The other end may run into a wall.
6. The swept sector between hinge and arc must be at most 35% ink.
7. The arc must lie within 0.6 r of a long axis-parallel run, so it stands on a wall. This is what removes the chair and table arcs in plan 2.
8. The radius must be at least 4.5 times the stroke width. Thick strokes on small circles fit almost any curve.
9. Small arcs next to a swing at least a third larger are dropped as detail of it, then arcs whose boxes touch are merged.

Hough peaks are a pixel or two off, which a thin stroke on a small circle shows as drift. Each accepted arc is refined by trying its neighbouring centres and radii.

## Terms

- Hinge: the point a door leaf turns about, the circle centre.
- Bow tie: a double door in a wall drawn as two mirrored half discs.
- Hough transform: finding shapes by letting each pixel vote for the shape parameters that pass through it.

## Pitfalls

- A single arc stroke of 1 px on a 20 px circle (plan 6) and a 5 px stroke on a 36 px circle (plan 1) need the same code to work. Every tolerance is in units of r or of the measured stroke width, not pixels.
- The leaf test has to allow the far end to run into a wall. Requiring both ends to stop dropped every wall-side arc on plan 6.
- Truth boxes for plan 1 and 2 are drawn by hand: bow ties are a thin band across the jambs on horizontal walls but a large box on vertical ones, so one box rule cannot match both. The detector reports the symbol box.

## Model check

`--verify-doors` shows each candidate to a local VLM and drops the ones it calls not a door. It removed 15 of 27 false candidates and 4 of 36 real ones on plans 1 to 6, from one prompt tried twice. A first prompt without the bow tie hint rejected every bow tie.

## Reading

- Duda and Hart, "Use of the Hough transformation to detect lines and curves in pictures", Communications of the ACM 15(1), 1972.
- Yuen et al., "Comparative study of Hough transform methods for circle finding", Image and Vision Computing 8(1), 1990.
