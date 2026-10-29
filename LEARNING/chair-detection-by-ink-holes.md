Chair detection by closed holes in the ink

What it is: a chair drawn as a small circle is found as a closed hole in the ink mask, not by a Hough circle vote. `chairs(ink:w:h:page:)` in `SeatLayer.swift` flood-fills the clear pixels (4-connected), keeps the fills that never touch the image border, and tests each one for size and shape. A 4-connected fill cannot slip between two ink pixels that touch at a corner, so a ring drawn with a diagonal-stepped line still holds its inside.

Why this and not Hough: a ring test (ring mostly ink, inside clear) is what a Hough accumulator approximates, and it needs a radius range, an edge image and a vote threshold. The hole already is the "inside clear, ring all ink" test, in one pass over the page, with no radius sweep. The cost is that a ring with a real gap is lost: its inside leaks into the page and is no longer a hole. On the three plans no ring leaked on clean input. The drawn chair may touch the table or not, because only the inside of the circle matters.

Walkthrough:
1. Fill every clear region and record its pixel count, bounding box and whether it touches the border.
2. Drop regions that touch the border, are bigger than 1.5% of the page side, or smaller than 3 px.
3. Drop regions whose box is not close to square (long side at most 1.25 times the short side).
4. A disc fills about 78% of its box and leaves the four box corners outside. Keep a region only if its fill is between 0.6 and 0.97 and none of the four corner pixels belongs to it. A square or rounded square fails the corner test or the fill bound, a diamond fails the fill bound.
5. Grow the box outward by the ring thickness, measured as the ink run next to the hole at its thinnest side (a table may share one side).
6. Keep a hole only if at least two others of the same size (within 20%, at least 1.5 px) lie within six diameters. A lone circle can be a column, a dot or a letter.

Grouping: an object blob that contains two or more chair centres is flagged `seat`, with `chairs` set to the count and `kind` set to `chair_group`. Rows of ten chairs in an audience grid arrive as one blob per row; blobs with six or more chairs that touch (within one chair width) merge into one grid. A table has four or fewer chairs here, so tables standing in a row never merge.

Scale: the same chair size sets how far ink is grown to join a table to its chairs (`objectJoinRadius`). Two pixels fits chairs about 12 px across. On a half-size print the gap between neighbouring tables is under 4 px, two pixels fuses four tables into one blob and the object count falls to 1 of 141. The radius is chair side divided by 6, rounded, between 1 and 2, so it shrinks on small prints and never grows. With fewer than 8 chairs it stays at 2.

Black lines under JPEG or noise: the shared ink mask also requires low saturation. JPEG and pixel noise tint the 1 px black outlines until they count as colour, and on plan 3 (a beige page) the outlines of the tables vanish and objects fall to 0 of 11. The seat layer reads dark pixels (under 30% of the page's median grey) as ink too, but only when under a fifth of the dark pixels pass the saturation test. Clean plans pass 32% to 94% of them, JPEG 40 and noise 5% to 16%. A plan-wide switch is needed because adding the dark pixels on clean plans also adds black outlines that border coloured fills, and plan 2's dark red box becomes a false object.

Limits and pitfalls:
- Small holes are poor circles. At half size a chair hole is 3 to 4 px across and is a cross or a square, so chair recall falls (98 of 744 on half-size plan 1). The seat flag then falls back to the judge.
- Square cells of an audience block (plan 3) are not claimed. Their outlines are 1 px grey lines that fail the ink threshold, so most cells are not closed holes.
- The chair truth in `data/planN/seats.json` was built by running this detector and looking at the overlays, so recall against it is not independent.
- Round tables are circles too. They would be kept as chairs only if three or more of the same size sat close together.

Terms: hole is a connected set of clear pixels bounded by ink. 4-connected means pixels join only through edges, not corners. Fill is region pixels divided by bounding-box area.

Further reading: Gonzalez and Woods, Digital Image Processing, chapter on morphological processing (hole filling); Duda and Hart, "Use of the Hough transformation to detect lines and curves in pictures", Communications of the ACM 15(1), 1972.
