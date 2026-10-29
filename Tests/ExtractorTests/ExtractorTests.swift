import Foundation
import Testing
@testable import Extractor

private func tile(_ cls: String, _ id: String?) -> Item {
    Item(cls: cls, box: [0, 0, 10, 10], area: 100, fillRgb: [0, 0, 0], legendRgb: [0, 0, 0],
         text: id ?? "", id: id, needsReview: false, reason: nil)
}

private func suggestions(_ ids: [String]) -> [String: String] {
    var items = ids.map { tile("INDONESIA", $0) }
    var counts: [String: Int] = [:]
    repairIdsByPrefix(&items, ruleCounts: &counts)
    return Dictionary(uniqueKeysWithValues: items.compactMap { item in item.suggestedId.map { (item.id ?? "", $0) } })
}

private func ring(size: Int, gapAt: Int? = nil) -> [Bool] {
    var mask = [Bool](repeating: false, count: size * size)
    for i in 0..<size {
        for (x, y) in [(i, 0), (i, size - 1), (0, i), (size - 1, i)] { mask[y * size + x] = true }
    }
    if let gapAt { mask[gapAt] = false }
    return mask
}

@Test func labelsAcceptUpToThreeLettersAndFoldCyrillic() {
    #expect(cleanLabel("FNB12") == "FNB12")
    #expect(cleanLabel(" gd 28 ") == "GD28")
    #expect(cleanLabel("\u{041C}30") == "M30")
    #expect(cleanLabel("A1B") == nil)
    #expect(cleanLabel("1234") == nil)
}

@Test func fillHolesFillsOnlyClosedSmallHoles() {
    let closed = fillHoles(ring(size: 7), w: 7, h: 7, maxHole: 30, seamLength: 20)
    #expect(closed[3 * 7 + 3])
    let leaking = fillHoles(ring(size: 7, gapAt: 3), w: 7, h: 7, maxHole: 30, seamLength: 20)
    #expect(!leaking[3 * 7 + 3])
    let tooBig = fillHoles(ring(size: 7), w: 7, h: 7, maxHole: 10, seamLength: 20)
    #expect(!tooBig[3 * 7 + 3])
}

@Test func zeroReadAsLetterOIsRepairedWhenTheShortPrefixIsCommon() {
    let common = (1...8).map { "N0\($0)" }
    let fixed = suggestions(common + ["NO9"])
    #expect(fixed["NO9"] == "N09")
}

@Test func confusablePrefixLetterNeedsAMuchCommonerNeighbour() {
    let many = (1...12).map { "GD\($0)" }
    #expect(suggestions(many + ["CD28"])["CD28"] == "GD28")
    // G is a real prefix here, only a rarer one, so it must not be rewritten to C.
    let mixed = (1...16).map { "C\($0)" } + (1...6).map { "G\($0)" }
    #expect(suggestions(mixed + ["G19"])["G19"] == nil)
}

@Test func duplicateIdSwapsOneDigitOnlyIntoAGap() {
    let series = (1...30).filter { $0 != 27 }.map { "E\(String(format: "%02d", $0))" }
    #expect(suggestions(series + ["E21"])["E21"] == "E27")
    // A truncated one-digit read is not the series width, so it gets no suggestion.
    #expect(suggestions(series + ["E2", "E2"])["E2"] == nil)
}

@Test func classPrefixNeedsAClearMajority() {
    let pure = (1...10).map { tile("Booth A", "A\($0)") }
    #expect(computeClassPrefixes(pure)["Booth A"] == "A")
    let mixed = (1...5).map { tile("INDONESIA", "A\($0)") } + (1...5).map { tile("INDONESIA", "B\($0)") }
    #expect(computeClassPrefixes(mixed)["INDONESIA"] == nil)
}

@Test func legendSwatchNeedsABoundedBlockOfOneColour() {
    let (w, h) = (60, 40)
    var rgba = [UInt8](repeating: 255, count: w * h * 4)
    func paint(_ x: Int, _ y: Int, _ c: (UInt8, UInt8, UInt8)) {
        let i = (y * w + x) * 4
        (rgba[i], rgba[i + 1], rgba[i + 2]) = c
    }
    for y in 10..<22 { for x in 10..<22 { paint(x, y, (220, 40, 40)) } }
    for x in 5..<55 { paint(x, 30, (0, 0, 0)) }
    let px = Pixels(width: w, height: h, rgba: rgba)
    #expect(isSwatch(px, seedX: 15, seedY: 15, textHeight: 12))
    #expect(!isSwatch(px, seedX: 30, seedY: 30, textHeight: 12))
    #expect(!isSwatch(px, seedX: 40, seedY: 15, textHeight: 12))
}

private func gridWithTiles(side: Int, count: Int, page: Int) -> [Int16] {
    var grid = [Int16](repeating: -1, count: page * page)
    for t in 0..<count {
        let x0 = 20 + (t % 10) * (side + 20), y0 = 20 + (t / 10) * (side + 20)
        for y in y0..<(y0 + side) { for x in x0..<(x0 + side) { grid[y * page + x] = 0 } }
    }
    return grid
}

@Test func tileScaleShrinksForSmallTilesAndNeverPassesThePageScale() {
    let small = gridWithTiles(side: 24, count: 20, page: 3000)
    #expect(abs(tileScale(small, w: 3000, h: 3000, page: 3000, area: 9000000) - 24.0 / referenceTileSide) < 0.01)
    let large = gridWithTiles(side: 100, count: 20, page: 2000)
    #expect(tileScale(large, w: 2000, h: 2000, page: 2000, area: 4000000) == 1.0)
    let few = gridWithTiles(side: 24, count: 3, page: 3000)
    #expect(tileScale(few, w: 3000, h: 3000, page: 3000, area: 9000000) == 1.5)
}

@Test func contentExtentIgnoresMarginsAndSpecks() {
    let (w, h) = (100, 80)
    var rgba = [UInt8](repeating: 255, count: w * h * 4)
    func paint(_ x: Int, _ y: Int) {
        let i = (y * w + x) * 4
        (rgba[i], rgba[i + 1], rgba[i + 2]) = (0, 0, 0)
    }
    for y in 40..<50 { for x in 30..<50 { paint(x, y) } }
    paint(95, 5)  // a lone speck must not stretch the box
    let extent = contentExtent(rgba, width: w, height: h)
    #expect(extent.side == 20)
    #expect(extent.area == 200)
    #expect(extent.rect == CGRect(x: 30, y: 40, width: 20, height: 10))
}

private func planWithBlocks(limeSide: Int) -> Pixels {
    let (w, h) = (400, 400)
    var rgba = [UInt8](repeating: 255, count: w * h * 4)
    func fill(_ x0: Int, _ y0: Int, _ side: Int, _ c: (UInt8, UInt8, UInt8)) {
        for y in y0..<(y0 + side) { for x in x0..<(x0 + side) { let i = (y * w + x) * 4; (rgba[i], rgba[i + 1], rgba[i + 2]) = c } }
    }
    fill(20, 20, 200, (120, 184, 80))   // the plan's own green
    fill(250, 250, limeSide, (196, 214, 82))  // the legend lime, e.g. the swatch printed inside the plan
    return Pixels(width: w, height: h, rgba: rgba)
}

@Test func legendColourMovesToADominantPlanColourOnlyWhenItClearlyOutweighsTheMatch() {
    let lime = LegendClass(name: "GOODS", rgb: (196, 214, 82), lab: lab((196, 214, 82)))
    let moved = adaptLegendToPlan([lime], planWithBlocks(limeSide: 15), classes: [0])
    #expect(moved[0].rgb == (120, 184, 80))
    // A class that already matches a block over a quarter of the green one's size keeps its own colour.
    let kept = adaptLegendToPlan([lime], planWithBlocks(limeSide: 110), classes: [0])
    #expect(kept[0].rgb == (196, 214, 82))
}

private func plan(_ blocks: [(side: Int, color: (UInt8, UInt8, UInt8))]) -> Pixels {
    let (w, h) = (500, 300)
    var rgba = [UInt8](repeating: 255, count: w * h * 4)
    for (n, block) in blocks.enumerated() {
        for y in 20..<(20 + block.side) { for x in (20 + 160 * n)..<(20 + 160 * n + block.side) {
            let i = (y * w + x) * 4
            (rgba[i], rgba[i + 1], rgba[i + 2]) = block.color
        } }
    }
    return Pixels(width: w, height: h, rgba: rgba)
}

@Test func fadedPlanKeepsEachClassOnItsOwnColourEvenWhenTwoWantTheSame() {
    // Faded print: orange and yellow both drift toward white and the yellow block is the bigger one.
    let orange = LegendClass(name: "F", rgb: (245, 136, 30), lab: lab((245, 136, 30)))
    let yellow = LegendClass(name: "I", rgb: (253, 185, 19), lab: lab((253, 185, 19)))
    let faded = plan([(side: 100, color: (247, 160, 75)), (side: 130, color: (253, 199, 67))])
    let moved = adaptLegendToPlan([orange, yellow], faded, classes: [0, 1])
    #expect(moved[0].rgb == (247, 160, 75))
    #expect(moved[1].rgb == (253, 199, 67))
}

@Test func classRecentresOnThePlanColourOnlyWhenItIsWellOffTheSwatch() {
    let pink = LegendClass(name: "A", rgb: (243, 132, 163), lab: lab((243, 132, 163)))
    #expect(adaptLegendToPlan([pink], plan([(side: 100, color: (243, 134, 165))]), classes: [0])[0].rgb == (243, 132, 163))
    #expect(adaptLegendToPlan([pink], plan([(side: 100, color: (245, 156, 182))]), classes: [0])[0].rgb == (245, 156, 182))
}

private func squareRegion(_ x0: Int, _ y0: Int, side: Int, w: Int) -> Region {
    let pixels = (y0..<(y0 + side)).flatMap { y in (x0..<(x0 + side)).map { y * w + $0 } }
    return Region(minX: x0, minY: y0, maxX: x0 + side - 1, maxY: y0 + side - 1, pixels: pixels)
}

@Test func tileOutlineMustCoverMostOfTheTileNotAGlyph() {
    let w = 40
    let tile = squareRegion(10, 10, side: 20, w: w)
    func outline(faceSide: Int) -> [[Int]]? {
        let face = squareRegion(11, 11, side: faceSide, w: w)
        var faceOf = [Int32](repeating: -1, count: w * w)
        for i in face.pixels { faceOf[i] = 0 }
        return tilePolygon(tile, rect: CGRect(x: 10, y: 10, width: 20, height: 20), faces: [face], faceOf: faceOf, w: w, epsilon: 1)
    }
    #expect(outline(faceSide: 18) != nil)
    #expect(outline(faceSide: 4) == nil)
}

@Test func everyClassBelongsToTheLayerThatOwnsIt() {
    #expect(Layer.of(tile("Booth A", "A1")) == .booth)
    #expect(Layer.of(tile("SPONSOR BOOTH", nil)) == .booth)
    #expect(Layer.of(tile("wall", nil)) == .wall)
    #expect(Layer.of(tile("pillar", nil)) == .wall)
    #expect(Layer.of(tile("door", nil)) == .door)
    #expect(Layer.of(tile("object", nil)) == .seat)
}

@Test func layersOptionTakesNamesAndRejectsUnknownOnes() {
    #expect(parseOptions(["fp", "a.png", "b.png"])?.layers == Set(Layer.allCases))
    #expect(parseOptions(["fp", "a.png", "b.png", "--layers", "booth,wall"])?.layers == [.booth, .wall])
    #expect(parseOptions(["fp", "a.png", "b.png", "--layers", "tile"]) == nil)
    #expect(parseOptions(["fp", "a.png", "b.png"])?.upscaleSmall == false)
    #expect(parseOptions(["fp", "a.png", "b.png", "--upscale-small"])?.upscaleSmall == true)
}

@Test func upscaleOnlyEnlargesSmallTilesAndNeverBeyondTwice() {
    #expect(upscaleFactor(smallTileSide: 64) == 1)
    #expect(upscaleFactor(smallTileSide: 33) == 1)
    #expect(upscaleFactor(smallTileSide: 26) == 2)
    #expect(upscaleFactor(smallTileSide: 12) == 2)
    #expect(upscaleFactor(smallTileSide: nil) == 1)
}

private func flatPlan(noise: Int) -> Pixels {
    let (w, h) = (64, 64)
    var rgba = [UInt8](repeating: 255, count: w * h * 4)
    var seed: UInt32 = 12345
    for y in 0..<h {
        for x in 0..<w {
            let line = x == 32
            seed = seed &* 1664525 &+ 1013904223
            for c in 0..<3 {
                let jitter = noise == 0 ? 0 : Int((seed >> UInt32(8 * c)) & 0xFF) % (2 * noise + 1) - noise
                rgba[(y * w + x) * 4 + c] = UInt8(max(0, min(255, (line ? 0 : 200) + jitter)))
            }
        }
    }
    return Pixels(width: w, height: h, rgba: rgba)
}

@Test func noiseScoreSeparatesCleanFromNoisyAndTheFilterKeepsThinLines() {
    #expect(noiseScore(flatPlan(noise: 0)) < 0.02)
    #expect(noiseScore(flatPlan(noise: 14)) > 0.07)
    let noisy = flatPlan(noise: 14)
    let smooth = sigmaFiltered(noisy)
    func range(_ px: Pixels) -> Int {
        let values = (5..<20).flatMap { y in (5..<25).map { x in Int(px.rgba[(y * 64 + x) * 4]) } }
        return values.max()! - values.min()!
    }
    #expect(range(smooth) < range(noisy))
    #expect(smooth.rgba[(30 * 64 + 32) * 4] < 40)  // the one-pixel black line is still black
}

@Test func resultsMapBackFromAnUpscaledImage() {
    var item = tile("Booth A", "A1")
    item.box = [100, 61, 40, 20]
    item.area = 800
    item.polygon = [[100, 60], [140, 60], [140, 80]]
    let back = scaledBack(item, by: 2)
    #expect(back.box == [50, 31, 20, 10])
    #expect(back.area == 200)
    #expect(back.polygon == [[50, 30], [70, 30], [70, 40]])
    #expect(scaledBack(item, by: 1).box == item.box)
}

@Test func outlineKeepsLinesBlurHasLightenedButNotAFlatGreyFill() {
    let (w, h) = (60, 40)
    var rgba = [UInt8](repeating: 255, count: w * h * 4)
    func paint(_ x: Int, _ y: Int, _ v: UInt8) { let i = (y * w + x) * 4; (rgba[i], rgba[i + 1], rgba[i + 2]) = (v, v, v) }
    for x in 5..<25 { paint(x, 10, 150) }  // a blurred line
    for y in 20..<35 { for x in 35..<55 { paint(x, y, 150) } }  // a flat mid-grey zone
    let outline = outlinePixels(Pixels(width: w, height: h, rgba: rgba))
    #expect(outline[10 * w + 15])
    #expect(!outline[27 * w + 45])
}

@Test func ukrainianIReadsAsLatinI() {
    #expect(cleanLabel("\u{0406}3") == "I3")
}

@Test func sharpenedImageIsEnlargedAndDeepensAGreyStroke() {
    let (w, h) = (12, 12)
    var rgba = [UInt8](repeating: 255, count: w * h * 4)
    for y in 0..<h { for x in 5..<7 { for c in 0..<3 { rgba[(y * w + x) * 4 + c] = 140 } } }  // a blurred stroke
    let image = makeImage(Pixels(width: w, height: h, rgba: rgba))!
    let sharp = pixels(of: sharpened(image, by: 3)!)
    #expect(sharp.width == 36)
    #expect(sharp.rgb(18, 18).0 < 140)
}
