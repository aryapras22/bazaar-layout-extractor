# Slanted walls and page tilt

Two techniques in the wall layer: a Hough pass that finds slanted wall strokes, and a shear-based run finder that keeps long lines when the page is rotated a degree or two.

## Slanted walls by Hough transform on axis-free ink

Wall detection used `longRuns`, which walks rows and columns, so a stroke at 30 degrees is invisible to it. A line detector is the standard answer, and the Hough transform is the simplest one to write without OpenCV.

Why not the alternatives: Hough on all the ink returned hundreds of lines (booth grids, text rows, stair hatching). Connected components of thick ink are useless because a diagonal wall touches the axis-aligned wall network and joins its component. Segment detectors (LSD) need a gradient pipeline the project does not have.

How it works:

1. Start from the raw ink with text boxes removed. Booths are not masked, because the booth layer's claimed areas can be wrong; booth outlines are axis-aligned and leave in the next step.
2. Remove everything the axis pass already owns: long horizontal and vertical runs (dilated by 2 px) and solid blocks (opened ink, closed so the glyph gaps inside a black sponsor box fill in, then dilated). What is left is thin, slanted or curved.
3. Every remaining pixel votes for each angle (0.5 degree steps, skipping 10 degrees around each axis) at the distance `x cos t + y sin t` from the origin. A straight stroke piles its votes into one (angle, distance) cell.
4. Take the strongest cell, collect the pixels within 2.5 px of that line, sort them along it, cut at gaps, keep runs that are long and dense, and delete their pixels from the vote table. Repeat. Deleting the pixels is what lets a line that crosses another still be found.
5. Walk each end outward while ink continues within 1 px. The detection ink had the axis walls removed, so a stroke lost the stretch where it crosses one.
6. Keep a stroke only if an end lies within 5 px of an axis-aligned wall, no other stroke crosses it (extended by half its length, because crossing strokes eat each other's middle), and no ink sits on both sides of it close together (a cross drawn in a box). Merge strokes that lie on one line, or on two lines under 8 px apart (a wall drawn as a double line).

Trade-offs: the thresholds come from five plans. Slanted walls under 10 degrees off an axis are not found. A slanted wall that touches nothing is dropped, which loses a free-standing partition and keeps stairs, arrows and door arcs out. The plan 6 right-edge truth segment that is 17 px long is under the length floor.

Pitfalls: a nearly horizontal line at 5 degrees still matches at 10 degrees over 58 px stretches, which is why runs need a minimum length and density as well as a vote count. Door-swing arcs lie beside real diagonals; testing for crossing lines only in the middle half of a stroke keeps them from vetoing it. Summing three neighbouring distance cells keeps a wide stroke as one peak.

## Page tilt by shear

A page rotated 1 degree turns every horizontal wall into a line that steps one row every 57 px. `longRuns` needs unbroken pixels in one row, so every wall falls below the minimum run. Rotating the image would need interpolation and mapping every result box back.

Instead the tilt is estimated, and runs follow it:

1. For each slope from -3 to +3 degrees in 0.1 steps, shear the ink pixels (subtract `x * slope` from `y`) and count how many land in each row. Sum the squared counts. Straight lines pile into few rows, so the sum peaks at the right slope. This is the projection-profile deskew method.
2. Use a nonzero slope only if its sum is at least 10% above the unsheared sum. All six clean plans keep slope 0 and their output is unchanged.
3. `tiltedRuns` walks each sheared line, accepts a pixel within 1 row of the ideal line, and marks the real pixels of long runs. Vertical lines use their own slope, since lines can tilt by slightly different amounts.

Limits: only slopes up to about 3 degrees are tried. The wall boxes of a tilted page are bounding boxes of tilted strips, so pixel recall against truth boxes moved the same way tops out near 70%, however good the detection is.

## Colour noise on near-black lines

Saturation is chroma divided by brightness. A black line pixel with blue 7 and red and green 0 has saturation 255. Pixel noise left after smoothing and JPEG blocks do this to many line pixels, so `inkMask` dropped the lines. The cure is gated: when dark pixels that fail the saturation test but have chroma under 24 outnumber the dark grey ones two to one, chroma under 30 decides. Clean plans measure 0.03 to 0.72; noisy and JPEG plans 5 or more. An ungated rule changed walls on every clean plan.

## Further reading

- Duda and Hart, "Use of the Hough transformation to detect lines and curves in pictures", Communications of the ACM 15(1), 1972.
- OpenCV documentation, "Hough Line Transform" and `HoughLinesP`.
- Hull, "Document image skew detection: survey and annotated bibliography", 1998, for projection-profile deskew.
