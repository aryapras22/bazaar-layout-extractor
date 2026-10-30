# Reading tiles from blurred, faded and small plans

Techniques in the booth layer, each aimed at a failure the stress test showed. None needs a blur detector, a fade detector or a size switch for the whole plan.

## Local-contrast outlines

A fixed cut (gray under 60) finds outlines on a crisp plan. Blur or fading lightens a 1 px line to mid grey and the cut loses it, so closed light booths disappear. The rule used now also counts a pixel as outline when it is at least 70 grey levels darker than the mean of its 11 x 11 neighbourhood. The mean comes from an integral image, so each window costs four lookups. The rule is used only for the light-booth pass: on plan 5's 24 px stalls it also marks glyph pixels and moved the text mask enough to cost two IDs.

## Re-centring a legend colour on the plan's own colour

A legend swatch and the plan's fill for the same class differ a little, and a fixed gate (delta E 12) around the swatch then covers only one side of a tile that is shaded around its mean. Fading shifts every colour the same way, so some tiles leave the gate and a class loses half its booths. Two steps: a class whose colour is far from every plan colour moves to the most common nearby plan colour (when two classes want the same colour, the nearer swatch gets it), and a class whose swatch is more than half the gate away from the most common plan colour within twice the gate moves onto that colour. The second step skips near-white, near-black and grey swatches, which would otherwise land on the background or on text.

## Voting over sharpened crops

Vision returns nothing for a blurred 7 px label and is erratic on small crops: the same tile read right at an inset of 3 px and wrong at 4 px. When the plain read gives no label, the tile is cropped at five insets and two enlargements, each crop is sharpened (unsharp mask, amount 3, sigma 1.2 source pixels, box blur passes standing in for a Gaussian), and every readable label casts a vote. The most common wins. Larger factors than 3 read worse, because sharpening a 4x blur amplifies its ringing. On plan 5 at blur sigma 1.2 this takes 0 IDs to 101.

Two smaller facts from the same work: tiles under 60 px read better when enlarged 3x before the first read (plan 5 exact IDs 224 to 244), and a label printed on two lines ("GD" over "38") arrives as two observations, so their texts joined top to bottom are one more candidate.

## Model read with a numbering gate

For tiles the recogniser cannot read at all, `--model-ids` crops the tile, enlarges it 4x on white and asks Qwen3.5-9B for the ID. The model only answers for a tile already found, since it reads crops well and finds boxes badly. The answer is a suggestion, kept only when its number fills a gap in the class's numbering and no other tile claims it. The letters come from the class (the model said CO26 for GD26). On plan 4 the goods tiles with a valid ID go from 39 to 50 of 52.

## Round 2

Merged regions: half size drops every second 1 px divider and blur fades dividers inside a block of stalls, so several booths read as one. The region is cut into a grid by the plan's booth size (median short side, with a page-relative floor), and the cut stands when at least two cells and half of them read different IDs that share one letter prefix. A double-width booth has one label, and a sponsor box whose white name reads as scraps fails the prefix test.

Prefix letters: at 6 px an S reads as 8, 5 or $, so S2 arrives as 82. The nearest tile that read cleanly supplies the letter, if the first character is a lookalike of it.

Legend swatch: JPEG ringing puts the first guess on the swatch border. A second pass tries seeds within two text heights and skips swatches already claimed (wrapped lines) and white or near-black blocks (a framed ENTRANCE, a bold W).

Fade: faded black is lost because the colour search skips black and grey. A line a*c + b fitted on at least four moved classes gives the faded black. Text fragments then match that class, so a small tile must be as wide as the plan's booth.

Enlarged strips: when a fifth of the tiles stay unread, the page is also read in 400 px strips at 3x sharpened and 2x plain (plan 5 blur: about 30 IDs).

## Pitfalls

- Fading and blur are measured on the same plan; a fix that helps one (outline rule on plan 5) can cost the other.
- Whole-plan upscaling changes every threshold at once. Enlarging only the crop that Vision sees gets most of the benefit with none of that.
- A model answer that fits no gap is discarded, and that is the point: without the gate the model's fluent wrong answers would become IDs.

## Further reading

- Apple Vision, `RecognizeTextRequest`: https://developer.apple.com/documentation/vision/recognizetextrequest
- Summed-area tables: Crow, "Summed-area tables for texture mapping", SIGGRAPH 1984.
- CIE76 colour difference: https://www.cie.co.at/
