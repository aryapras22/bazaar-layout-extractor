# Finding tiles that have text and diagonal edges

`extract_swift3.swift` finds booth tiles by legend colour, then measures each candidate shape. Two measurements decide whether a shape is a tile: how it handles the label text, and how it checks that the shape is compact.

## What it does

A class mask marks every pixel within a colour distance of the legend swatch. A tile label is drawn on top of the tile, so the mask has holes where the letters are. The tool fills every enclosed hole smaller than a set size (3000 px at 2000 px image scale), erodes the mask by a few pixels so thin dark lines between tiles stay as gaps, and takes connected components.

Each component is then tested with solidity, which is its pixel area divided by the area of its convex hull. A rectangle scores about 1. A right triangle scores about 1 as well, because the hull of a triangle is the triangle. A ragged blob scores lower. The cut is 0.85.

## Why this and not box fill

The earlier test was box fill, meaning component area divided by bounding box area, with a cut at 0.6. That test failed in two ways on the second map. Large text takes up to 80 percent of a small tile, and erosion widens each hole, so the filled share drops below 0.6 or the tile splits into strips above and below the text. A diagonal tile is half empty in its bounding box by construction, so it can never pass.

The cost is that a ragged but compact shape also passes, and that a hole above the size limit stays open. The size limit exists because a wall frame around the hall encloses everything, and filling it would turn the whole hall into one tile.

## Steps

1. Build the class mask from the colour distance.
2. Fill enclosed holes up to the size limit by flood filling the background and keeping the pieces that never reach the image border.
3. Erode so tiles that touch stay separate.
4. Label connected components and drop those under the minimum area.
5. Compute the convex hull of the component and keep it when area over hull area is at least 0.85.

## Outline polygons for sloped booths

A box cannot describe a trapezoid. The tool also finds the dark outlines (pixels with luminance under 60, grown by one pixel to close small gaps) and labels the connected areas between them as faces. Each tile takes the face that holds most of its colour pixels, builds the convex hull of that face, and simplifies the hull with Douglas-Peucker at 2 px so a slanted edge becomes two corner points. The result is written as `polygon` next to `box`. The polygon lies inside the outline, and a tile whose outline is broken keeps only its box.

## Terms

- Convex hull: the smallest convex polygon that contains the shape.
- Solidity: area divided by convex hull area.
- Hole: a background region fully surrounded by the mask.

## Pitfalls

- Hole filling needs a size limit, or an enclosing wall fills in. The limit also has to stay under the inside of a tile that a dark outline rings, otherwise a black class turns every outlined tile into a black tile. A long thin hole is left open because it is a seam between two same-colour tiles.
- A closed hollow shape such as a door swing becomes a solid blob after filling, so each tile must also hold at least 40 percent of its class colour.
- Pixel centres give a hull slightly smaller than the pixel count. The code uses pixel corners so a rectangle scores exactly 1.
- Solidity says nothing about the label. Short OCR results such as "FI" for F1 still fail the ID parser.

## Further reading

- [Convex hull, Wikipedia on Andrew's monotone chain](https://en.wikipedia.org/wiki/Convex_hull_algorithms)
- [Solidity as a region property, scikit-image regionprops](https://scikit-image.org/docs/stable/api/skimage.measure.html#skimage.measure.regionprops)
